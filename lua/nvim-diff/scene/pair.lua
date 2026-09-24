--- A side-by-side pair: two read-only panes showing the old and new side of one diff,
--- decorated by `render/sidebyside.lua` and kept aligned by `scene/scrollsync.lua`.
---
--- This is the object later steps build on: context folding keeps one fold list for both
--- panes and rebuilds their folds under `sync:pause`, comment threads call `set_block`,
--- the layout toggle closes the pair and opens a unified pane in its place, the file panel
--- opens it in windows it owns.
---
---     local pair = require("nvim-diff.scene.pair").open({
---       diff = require("nvim-diff.diff.line").diff(old_lines, new_lines),
---       old = { lines = old_lines, label = "a/lua/foo.lua" },
---       new = { lines = new_lines, label = "b/lua/foo.lua" },
---     })

local buffer = require("nvim-diff.scene.buffer")
local event = require("nvim-diff.core.event")
local fold = require("nvim-diff.render.fold")
local folds_scene = require("nvim-diff.scene.folds")
local hl = require("nvim-diff.ui.hl")
local rowmap = require("nvim-diff.render.rowmap")
local scrollsync = require("nvim-diff.scene.scrollsync")
local sidebyside = require("nvim-diff.render.sidebyside")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

local SIDES = { "old", "new" }

---@class NvimDiff.PairSide
---@field lines string[]
---@field label string Shown in the header: `── <label> ──`.
---@field header? string Full header text, replacing the one built from `label`.
---@field name? string Buffer name.
---@field lang? string Treesitter language.

---@class NvimDiff.PairSpec
---@field diff NvimDiff.Diff
---@field old NvimDiff.PairSide
---@field new NvimDiff.PairSide
--- Windows to show the panes in. They become panes: `winfixbuf`, the pane options, and
--- they are closed with the pair. Omitted: a new tabpage with two vertical splits.
---@field wins? { old: integer, new: integer }
--- Context folding: `false` to show every line; otherwise `context` rows kept next to each
--- hunk (default 3, at least 1) and `step` rows revealed per expand (default 10).
---@field fold? false|{ context?: integer, step?: integer }

---@class NvimDiff.Pair
---@field diff NvimDiff.Diff
---@field map NvimDiff.RowMap
---@field bufs { old: integer, new: integer }
---@field wins { old: integer, new: integer }
---@field sync NvimDiff.ScrollSync
---@field closed boolean
---@field lines { old: string[], new: string[] }
--- Closed folds, as display-row ranges shared by both panes.
---@field folds NvimDiff.Fold[]
---@field fold_base NvimDiff.Fold[] The folds the pair opened with; collapsing restores them.
---@field fold_step integer
---@field scopes { old?: integer[], new?: integer[] } Scope-line index per side, built lazily.
---@field private blocks table<any, NvimDiff.Block>
---@field private block_order any[] Ids in insertion order, so equal rows keep it.
---@field private augroup integer
---@field private filler_width integer
local Pair = {}
Pair.__index = Pair

--- Open a new tabpage and return its two windows, left and right.
---@return integer left
---@return integer right
local function tab_windows()
  vim.cmd("tabnew")
  local left = api.nvim_get_current_win()
  local placeholder = api.nvim_get_current_buf()
  local right = api.nvim_open_win(placeholder, false, { split = "right", win = left })
  return left, right
end

---@param spec NvimDiff.PairSpec
---@return NvimDiff.Pair
function M.open(spec)
  hl.setup()
  local diff = spec.diff
  local fold_opts = spec.fold == nil and {} or spec.fold
  local base = fold_opts and fold.compute(diff, fold_opts) or {}
  local map = rowmap.new(diff, nil, base)
  local self = setmetatable({
    diff = diff,
    map = map,
    bufs = {},
    wins = {},
    blocks = {},
    block_order = {},
    closed = false,
    lines = { old = spec.old.lines, new = spec.new.lines },
    folds = base,
    fold_base = base,
    fold_step = fold_opts and fold_opts.step or fold.STEP,
    scopes = {},
  }, Pair)

  for _, side in ipairs(SIDES) do
    local s = spec[side]
    self.bufs[side] = buffer.create({
      lines = s.lines,
      header = s.header or sidebyside.header(s.label),
      trailer = map.trailer,
      name = s.name,
      lang = s.lang,
    })
  end
  assert(
    api.nvim_buf_line_count(self.bufs.old) == diff.old_count + 1 + (map.trailer and 1 or 0)
      and api.nvim_buf_line_count(self.bufs.new) == diff.new_count + 1 + (map.trailer and 1 or 0),
    "nvim-diff: pane lines do not match the diff"
  )

  local placeholder
  if spec.wins then
    self.wins.old, self.wins.new = spec.wins.old, spec.wins.new
  else
    self.wins.old, self.wins.new = tab_windows()
    placeholder = api.nvim_win_get_buf(self.wins.old)
  end

  local width = sidebyside.number_width(diff)
  for _, side in ipairs(SIDES) do
    window.pane(self.wins[side], self.bufs[side], {
      statuscolumn = sidebyside.statuscolumn(diff[side .. "_count"], width),
    })
    folds_scene.setup_window(self.wins[side])
    folds_scene.apply(self, side)
    api.nvim_win_set_cursor(self.wins[side], { 1, 0 })
  end
  if placeholder and api.nvim_buf_is_valid(placeholder) and api.nvim_buf_get_name(placeholder) == "" then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end

  self.filler_width = sidebyside.filler_width()
  sidebyside.render(self.bufs, map)

  self.sync = scrollsync.attach({ self:sync_pane("old"), self:sync_pane("new") })

  self.augroup = api.nvim_create_augroup("nvim-diff.pair." .. self.bufs.old, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = { tostring(self.wins.old), tostring(self.wins.new) },
    callback = function()
      -- Closing windows from inside WinClosed is not allowed; half a pair is useless.
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  folds_scene.attach(self, self.augroup)
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if sidebyside.filler_width() > self.filler_width then
        self:repaint_virt()
      end
    end,
  })

  for _, side in ipairs(SIDES) do
    event.emit_in({ win = self.wins[side], buf = self.bufs[side] }, event.events.DIFF_BUF_READY, self.bufs[side], {
      side = side,
      pair = self,
    })
  end
  return self
end

--- The corrector's view of one pane; reads `self.map` on every call, so a new map (a block
--- added) takes effect without re-attaching.
---@param side NvimDiff.Side
---@return NvimDiff.SyncPane
function Pair:sync_pane(side)
  return {
    win = self.wins[side],
    top_view = function(topline, topfill)
      return self.map:top_view(side, topline, topfill)
    end,
    view_top = function(v)
      return self.map:view_top(side, v)
    end,
    line_view = function(lnum)
      return self.map:line_view(side, lnum)
    end,
    max_top = function()
      return self.map:max_top()
    end,
  }
end

--- Which side `win` shows, if it is one of the panes.
---@param win integer
---@return NvimDiff.Side?
function Pair:side_of(win)
  for _, side in ipairs(SIDES) do
    if self.wins[side] == win then
      return side
    end
  end
  return nil
end

--- Buffer line of the file's line `lnum`.
---@param lnum integer
---@return integer
function Pair.buf_line(_, lnum)
  return rowmap.buf_line(lnum)
end

--- The file's line under `side`'s cursor; nil on the header or the trailer.
---@param side NvimDiff.Side
---@return integer?
function Pair:cursor_line(side)
  return self.map:file_line(side, api.nvim_win_get_cursor(self.wins[side])[1])
end

--- Put `side`'s cursor on the file's line `lnum` and bring the other pane along.
---@param side NvimDiff.Side
---@param lnum integer
function Pair:jump(side, lnum)
  local win = self.wins[side]
  local bl = math.max(1, math.min(rowmap.buf_line(lnum), api.nvim_buf_line_count(self.bufs[side])))
  api.nvim_win_set_cursor(win, { bl, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  self.sync:sync(win)
end

--- The blocks in insertion order.
---@return NvimDiff.Block[]
function Pair:block_list()
  local list = {}
  for _, id in ipairs(self.block_order) do
    list[#list + 1] = self.blocks[id]
  end
  return list
end

--- Rebuild the map from the current blocks and folds and repaint every virtual row.
function Pair:rebuild_virt()
  self.map = rowmap.new(self.diff, self:block_list(), self.folds)
  self.filler_width = sidebyside.filler_width()
  for _, side in ipairs(SIDES) do
    sidebyside.paint_virt(self.bufs[side], self.map, side)
  end
end

--- Rebuild the map from the current blocks and folds, repaint every virtual row, realign.
function Pair:repaint_virt()
  self:rebuild_virt()
  self.sync:refresh()
end

-- Folding --------------------------------------------------------------------------------

--- Display row of the file's line `lnum` on `side`.
---@param side NvimDiff.Side
---@param lnum integer
---@return integer?
function Pair:row_of(side, lnum)
  return self.diff:row_of(side, lnum)
end

--- The closed fold holding the file's line `lnum` of `side`, and its index in `folds`.
---@param side NvimDiff.Side
---@param lnum integer
---@return NvimDiff.Fold?
---@return integer?
function Pair:fold_at(side, lnum)
  local d = self:row_of(side, lnum)
  local i = d and fold.find(self.folds, d)
  if not i then
    return nil, nil
  end
  return self.folds[i], i
end

--- Replace the fold list and rebuild both panes' folds, keeping `leader`'s view (default:
--- the current pane) and putting its cursor on `cursor` (a file line of the leader's side)
--- when given. Rows that blocks hang off are always kept visible.
---@param list NvimDiff.Fold[]
---@param leader? integer
---@param cursor? integer
function Pair:set_folds(list, leader, cursor)
  for _, b in ipairs(self:block_list()) do
    list = fold.reveal(list, b.row)
  end
  self.folds = list
  leader = leader or self.sync:leader()
  local lside = leader and self:side_of(leader)
  self.sync:pause(function()
    local view = lside and api.nvim_win_call(leader, vim.fn.winsaveview)
    self:rebuild_virt()
    for _, side in ipairs(SIDES) do
      local win = self.wins[side]
      local other = side ~= lside and api.nvim_win_call(win, vim.fn.winsaveview)
      folds_scene.apply(self, side)
      if other then
        api.nvim_win_call(win, function()
          vim.fn.winrestview(other)
        end)
      end
    end
    if view then
      if cursor then
        view.lnum = rowmap.buf_line(cursor)
        view.col, view.curswant = 0, 0
      end
      api.nvim_win_call(leader, function()
        vim.fn.winrestview(view)
        -- Scroll now if the cursor left the view, so the other pane follows the real top.
        vim.fn.winline()
      end)
    end
  end)
  if leader then
    self.sync:sync(leader)
  end
end

--- Reveal rows of the fold holding the file's line `lnum` of `side`: `n` of them (default:
--- all), from the end `dir` says (default `fold.default_dir`). The cursor of `side`'s pane
--- lands on what is left of the fold, so repeating the expand keeps revealing, or on the
--- first revealed line once the fold is gone. False when `lnum` is not folded.
---@param side NvimDiff.Side
---@param lnum integer
---@param n? integer
---@param dir? NvimDiff.FoldDir
---@return boolean
function Pair:expand(side, lnum, n, dir)
  local f, i = self:fold_at(side, lnum)
  if not f or not i then
    return false
  end
  local list = fold.expand(self.folds, i, n, dir)
  local rest = fold.find(list, f.first) or fold.find(list, f.last)
  local target = rest and list[rest] or f
  local cursor = fold.side_lines(self.diff, target, side)
  self:set_folds(list, self.wins[side], cursor or lnum)
  return true
end

--- Reveal every fold.
function Pair:expand_all()
  self:set_folds({})
end

--- Fold back up the context the file's line `lnum` of `side` came out of: the fold the
--- pair opened with over that line, put back whole. The cursor lands on it. False when
--- the line was never folded.
---@param side NvimDiff.Side
---@param lnum integer
---@return boolean
function Pair:collapse(side, lnum)
  local d = self:row_of(side, lnum)
  local i = d and fold.find(self.fold_base, d)
  if not i then
    return false
  end
  local f = self.fold_base[i]
  local list = fold.restore(self.folds, self.fold_base, { [f.id] = true })
  local cursor = fold.side_lines(self.diff, f, side)
  self:set_folds(list, self.wins[side], cursor or lnum)
  return true
end

--- Put every fold the pair opened with back.
function Pair:collapse_all()
  self:set_folds(vim.deepcopy(self.fold_base))
end

--- Insert (or replace) rows after display row `block.row` in both panes: `block.old` in
--- the old pane, `block.new` in the new pane, the shorter side padded with blank rows. A
--- fold over that row is split around it, since a block must hang off a visible line.
---@param id any Caller's key, e.g. a thread id.
---@param block NvimDiff.Block
function Pair:set_block(id, block)
  if not self.blocks[id] then
    self.block_order[#self.block_order + 1] = id
  end
  self.blocks[id] = block
  if fold.find(self.folds, block.row) then
    self:set_folds(self.folds)
  else
    self:repaint_virt()
  end
end

--- Remove a block. No-op for an unknown id.
---@param id any
function Pair:remove_block(id)
  if not self.blocks[id] then
    return
  end
  self.blocks[id] = nil
  for i, x in ipairs(self.block_order) do
    if x == id then
      table.remove(self.block_order, i)
      break
    end
  end
  self:repaint_virt()
end

--- Tear the pair down: stop syncing, close both panes, wipe both buffers. Idempotent.
--- `opts.keep` leaves that window open (the layout toggle reuses it), on an empty scratch
--- buffer if it still shows a pane.
---@param opts? NvimDiff.SceneCloseOpts
function Pair:close(opts)
  if self.closed then
    return
  end
  self.closed = true
  local keep = opts and opts.keep
  self.sync:detach()
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, side in ipairs(SIDES) do
    local win = self.wins[side]
    if api.nvim_win_is_valid(win) then
      api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
      if win == keep then
        if api.nvim_win_get_buf(win) == self.bufs[side] then
          api.nvim_win_set_buf(win, window.scratch())
        end
      elseif not pcall(api.nvim_win_close, win, true) then
        -- The last window cannot close; leave it on an empty buffer instead.
        api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
      end
    end
  end
  for _, side in ipairs(SIDES) do
    folds_scene.forget(self.bufs[side])
    if api.nvim_buf_is_valid(self.bufs[side]) then
      pcall(api.nvim_buf_delete, self.bufs[side], { force = true })
    end
  end
end

return M
