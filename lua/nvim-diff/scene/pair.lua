--- A side-by-side pair: two read-only panes showing the old and new side of one diff,
--- decorated by `render/sidebyside.lua` and kept aligned by `scene/scrollsync.lua`.
---
--- This is the object later steps build on: context folding rebuilds folds in `wins` under
--- `sync:pause`, comment threads call `set_block`, the layout toggle closes the pair and
--- opens a unified pane in its place, the file panel opens it in windows it owns.
---
---     local pair = require("nvim-diff.scene.pair").open({
---       diff = require("nvim-diff.diff.line").diff(old_lines, new_lines),
---       old = { lines = old_lines, label = "a/lua/foo.lua" },
---       new = { lines = new_lines, label = "b/lua/foo.lua" },
---     })

local buffer = require("nvim-diff.scene.buffer")
local event = require("nvim-diff.core.event")
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

---@class NvimDiff.Pair
---@field diff NvimDiff.Diff
---@field map NvimDiff.RowMap
---@field bufs { old: integer, new: integer }
---@field wins { old: integer, new: integer }
---@field sync NvimDiff.ScrollSync
---@field closed boolean
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
  local map = rowmap.new(diff)
  local self = setmetatable({
    diff = diff,
    map = map,
    bufs = {},
    wins = {},
    blocks = {},
    block_order = {},
    closed = false,
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

--- Rebuild the map from the current blocks, repaint every virtual row, realign.
function Pair:repaint_virt()
  local list = {}
  for _, id in ipairs(self.block_order) do
    list[#list + 1] = self.blocks[id]
  end
  self.map = rowmap.new(self.diff, list)
  self.filler_width = sidebyside.filler_width()
  for _, side in ipairs(SIDES) do
    sidebyside.paint_virt(self.bufs[side], self.map, side)
  end
  self.sync:refresh()
end

--- Insert (or replace) rows after display row `block.row` in both panes: `block.old` in
--- the old pane, `block.new` in the new pane, the shorter side padded with blank rows.
---@param id any Caller's key, e.g. a thread id.
---@param block NvimDiff.Block
function Pair:set_block(id, block)
  if not self.blocks[id] then
    self.block_order[#self.block_order + 1] = id
  end
  self.blocks[id] = block
  self:repaint_virt()
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
    if api.nvim_buf_is_valid(self.bufs[side]) then
      pcall(api.nvim_buf_delete, self.bufs[side], { force = true })
    end
  end
end

return M
