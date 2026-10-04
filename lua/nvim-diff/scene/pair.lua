--- A side-by-side pair: two read-only panes showing the old and new side of one diff,
--- decorated by `render/sidebyside.lua` and kept aligned by `scene/scrollsync.lua`.
---
--- This is the object later steps build on: context folding keeps one fold list for both
--- panes and rebuilds their folds under `sync:pause`, comment threads call `set_block`,
--- the layout toggle closes the pair and opens a unified pane in its place, the file panel
--- opens it in windows it owns.
---
--- Virtual lines another plugin draws in a pane (a diagnostic's `virtual_lines`, a code lens
--- in the real file's pane) are counted in the whole buffer on open, then in the rows each
--- redraw of a pane draws (`scene/foreign.lua`), and padded on the other side through the
--- row map; nothing is repainted while the counts stay the same.
---
---     local pair = require("nvim-diff.scene.pair").open({
---       diff = require("nvim-diff.diff.line").diff(old_lines, new_lines),
---       old = { lines = old_lines, label = "a/lua/foo.lua" },
---       new = { lines = new_lines, label = "b/lua/foo.lua" },
---     })

local buffer = require("nvim-diff.scene.buffer")
local event = require("nvim-diff.core.event")
local filebuf = require("nvim-diff.scene.filebuf")
local fold = require("nvim-diff.render.fold")
local foreign = require("nvim-diff.scene.foreign")
local folds_scene = require("nvim-diff.scene.folds")
local hl = require("nvim-diff.ui.hl")
local park = require("nvim-diff.scene.park")
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
--- The side is a blob at a commit: its buffer may be kept for reuse after the scene
--- closes (`scene/buffer.lua`, `buffers.lru_size`).
---@field keep? boolean
--- `false`: the buffer never ends with the trailer line (`render/rowmap.lua`), as a real
--- file cannot; the pane then cannot scroll into filler below its last line, and is
--- parked there instead (`scene/park.lua`).
---@field trailer? boolean
--- Absolute path of the file on disk to show instead of a scratch copy of `lines`, with
--- filetype and language servers (`scene/filebuf.lua`). Needs `winbar` and `trailer =
--- false`. The scratch pane stands in when the file's buffer does not hold `lines`.
---@field file? string
--- With `file`: the folder its language servers belong in (a PR review's slot); one rooted
--- elsewhere gets a warning.
---@field root? string
--- With `file`: called when the file changed on disk while the pane showed it. The pane
--- keeps the diffed lines; the owner opens the file again, which then shows a copy.
---@field on_changed? fun()
--- With `file`, when the pane shows it: the pane window is not fixed to its buffer
--- ('winfixbuf' off), so a jump to another file there (an LSP jump, a quickfix entry,
--- `:edit`) does not fail. The other buffer is taken back out at once — the pane's
--- buffer, view and folds put back — and `on_jump` is told where the jump went.
---@field on_jump? fun(jump: NvimDiff.PaneJump)

--- Where a jump out of a real file's pane went (`PairSide.on_jump`).
---@class NvimDiff.PaneJump
---@field buf integer The buffer it showed in the pane.
---@field lnum integer The cursor there.
---@field col integer 0-based byte column.
--- The jump loaded `buf`: it was read from disk in the pane window, so nobody else had it.
---@field read boolean

---@class NvimDiff.PairSpec
---@field diff NvimDiff.Diff
---@field old NvimDiff.PairSide
---@field new NvimDiff.PairSide
--- Show each side's header as the pane's `winbar` instead of buffer line 1: the layout a
--- pane showing the real file needs (a PR review's). Rows above a side's first line then
--- show with `topfill`, so the panes open at it, and `gg`/`<C-Home>` go back to it.
---@field winbar? boolean
--- A sign column (`signcolumn=yes:1`) on both panes, the same width so rows stay aligned.
---@field signs? boolean
--- Windows to show the panes in. They become panes: `winfixbuf` (but see
--- `PairSide.on_jump`), the pane options, and they are closed with the pair. Omitted: a
--- new tabpage with two vertical splits.
---@field wins? { old: integer, new: integer }
--- Context folding: `false` to show every line; otherwise `context` rows kept next to each
--- hunk (default 3, at least 1) and `step` rows revealed per expand (default 10).
---@field fold? false|{ context?: integer, step?: integer }
--- The folds to open with instead of the computed ones, e.g. another scene's current folds
--- (the layout toggle carries them over). Ignored when `fold` is false.
---@field folds? NvimDiff.Fold[]

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
---@field fold_opts false|NvimDiff.FoldOpts The spec's `fold`: false when folding is off.
---@field layout NvimDiff.RowMapLayout Every map of the pair is built with it.
---@field cols NvimDiff.PaneColumns What the panes' `statuscolumn` shows.
--- The sides showing the real file (`PairSide.file`), and their hold on its buffer.
---@field claims { old?: NvimDiff.FileClaim, new?: NvimDiff.FileClaim }
--- Why a side given a `file` shows a scratch copy of it instead (`filebuf.claim`'s reason).
---@field refused { old?: string, new?: string }
--- The namespaces each pane is painted into: the shared ones, or a real file's own.
---@field ns { old: NvimDiff.PaneNs, new: NvimDiff.PaneNs }
--- Virtual lines other plugins draw in each pane (`scene/foreign.lua`), as last counted
--- (the part off screen may be stale): the map pads the other pane to match.
---@field foreign { old: NvimDiff.ForeignLines, new: NvimDiff.ForeignLines }
--- Each pane's virtual rows as painted, by mark (`scene/park.lua`).
---@field private marks { old: table<integer, NvimDiff.VirtRows>, new: table<integer, NvimDiff.VirtRows> }
--- Each pane's park, while the scroll corrector has it stopped and painted to show a view row
--- no top of its can (`scene/park.lua`).
---@field private parks { old?: NvimDiff.Park, new?: NvimDiff.Park }
--- Buffer rows of each pane redrawn since the last count, `{ first, last }`.
---@field private foreign_due { old?: integer[], new?: integer[] }
---@field private foreign_scheduled boolean A count is scheduled.
---@field private watchers { old: NvimDiff.ForeignWatcher, new: NvimDiff.ForeignWatcher }
---@field private blocks table<any, NvimDiff.Block>
---@field private block_order any[] Ids in insertion order, so equal rows keep it.
---@field private augroup integer
---@field private filler_width integer
--- Rows kept at each end of a tall mark when painted (`sidebyside.virt_keep`).
---@field private virt_keep integer
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
  local folds = fold_opts and spec.folds and vim.deepcopy(spec.folds) or base
  local layout = {
    header = not spec.winbar,
    trailer = { old = spec.old.trailer ~= false, new = spec.new.trailer ~= false },
  }
  local map = rowmap.new(diff, nil, folds, layout)
  local self = setmetatable({
    diff = diff,
    map = map,
    bufs = {},
    wins = {},
    blocks = {},
    block_order = {},
    closed = false,
    lines = { old = spec.old.lines, new = spec.new.lines },
    folds = folds,
    fold_base = base,
    fold_step = fold_opts and fold_opts.step or fold.STEP,
    fold_opts = fold_opts,
    layout = layout,
    cols = { header = map.header, signs = spec.signs or false, park = true },
    claims = {},
    refused = {},
    ns = { old = sidebyside.SHARED_NS, new = sidebyside.SHARED_NS },
    marks = {},
    parks = {},
  }, Pair)

  local headers = {}
  for _, side in ipairs(SIDES) do
    local s = spec[side]
    headers[side] = s.header or sidebyside.header(s.label)
    local claim
    if s.file and not map.header and not map.trailer[side] then
      claim, self.refused[side] = filebuf.claim({
        path = s.file,
        lines = s.lines,
        lang = s.lang,
        root = s.root,
        on_changed = s.on_changed,
      })
    end
    self.claims[side] = claim
    self.bufs[side] = claim and claim.buf
      or buffer.create({
        lines = s.lines,
        header = map.header and headers[side] or nil,
        trailer = map.trailer[side],
        name = s.name,
        lang = s.lang,
        keep = s.keep,
      })
    assert(
      api.nvim_buf_line_count(self.bufs[side]) == diff[side .. "_count"] + map:head() + (map.trailer[side] and 1 or 0),
      "nvim-diff: pane lines do not match the diff"
    )
  end

  local placeholder
  if spec.wins then
    self.wins.old, self.wins.new = spec.wins.old, spec.wins.new
  else
    self.wins.old, self.wins.new = tab_windows()
    placeholder = api.nvim_win_get_buf(self.wins.old)
  end

  local width = sidebyside.number_width(diff)
  for _, side in ipairs(SIDES) do
    local user = window.pane(self.wins[side], self.bufs[side], {
      statuscolumn = sidebyside.statuscolumn(diff[side .. "_count"], width, self.cols),
      winbar = not map.header and sidebyside.winbar(headers[side]) or nil,
      signcolumn = self.cols.signs and "yes:1" or nil,
    })
    folds_scene.setup_window(self.wins[side])
    if self.claims[side] and spec[side].on_jump then
      -- Before `attach`: the claim guards the pane options as they are then.
      api.nvim_set_option_value("winfixbuf", false, { win = self.wins[side], scope = "local" })
    end
    if self.claims[side] then
      -- After every pane option is set: the claim guards them as they are now.
      self.ns[side] = self.claims[side]:attach(self.wins[side], {
        user = user,
        on_guard = function(refold)
          self:options_restored(refold)
        end,
      })
    end
    folds_scene.apply(self, side)
    api.nvim_win_set_cursor(self.wins[side], { 1, 0 })
  end
  if placeholder and api.nvim_buf_is_valid(placeholder) and api.nvim_buf_get_name(placeholder) == "" then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end

  -- A real file may come with virtual lines already: diagnostics of a running server, a
  -- code lens from the last time it was shown.
  self.foreign = self:count_foreign()
  self.map = rowmap.new(diff, nil, folds, layout, self.foreign)
  self.filler_width = sidebyside.filler_width()
  self.virt_keep = sidebyside.virt_keep()
  self:painted(sidebyside.render(self.bufs, self.map, self.cols, self.ns))

  self.sync = scrollsync.attach({ self:sync_pane("old"), self:sync_pane("new") })
  self.foreign_due = {}
  self.foreign_scheduled = false
  self.watchers = {}
  for _, side in ipairs(SIDES) do
    self.watchers[side] = function(top, bot)
      self:foreign_redrawn(side, top, bot)
    end
    foreign.watch(self.wins[side], self.watchers[side])
  end
  if not map.header then
    self:map_top_keys()
    self:top(self.sync:leader())
  end

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
  folds_scene.attach(self, { self.bufs.old, self.bufs.new }, self.augroup)
  for _, side in ipairs(SIDES) do
    if self.claims[side] and spec[side].on_jump then
      self:catch_jumps(side, spec[side].on_jump)
    end
  end
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if sidebyside.filler_width() > self.filler_width or sidebyside.virt_keep() > self.virt_keep then
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

--- A real file's pane got its window options back over another plugin's
--- (`scene/filebuf.lua` guards them): rebuild both panes' folds when fold options were
--- among them, else realign.
---@param refold boolean
function Pair:options_restored(refold)
  if self.closed then
    return
  end
  if refold then
    self:set_folds(self.folds)
  else
    self.sync:refresh()
  end
end

--- The corrector's view of one pane; reads `self.map` on every call, so a new map (a block
--- added) takes effect without re-attaching.
---@param side NvimDiff.Side
---@return NvimDiff.SyncPane
function Pair:sync_pane(side)
  return {
    win = self.wins[side],
    top_view = function(topline, topfill)
      -- Another buffer, for as long as a jump out of the pane takes (`catch_jumps`): its
      -- top is no view row, and the other pane stays where it is.
      if api.nvim_win_get_buf(self.wins[side]) ~= self.bufs[side] then
        return nil
      end
      return self.map:top_view(side, topline, topfill)
    end,
    view_top = function(v)
      return self.map:view_top(side, v)
    end,
    line_view = function(lnum)
      return self.map:line_view(side, lnum)
    end,
    max_top = function()
      return self.map:max_top(side)
    end,
    park = function(v, height)
      return self:park(side, v, height)
    end,
    unpark = function()
      self:unpark(side)
    end,
  }
end

--- What parking `side`'s pane needs (`scene/park.lua`).
---@param side NvimDiff.Side
---@return NvimDiff.ParkPane?
function Pair:park_pane(side)
  local fp = self:foreign_pane(side)
  if not fp then
    return nil
  end
  return {
    buf = self.bufs[side],
    win = self.wins[side],
    ns = self.ns[side].virt,
    map = self.map,
    side = side,
    cols = self.cols,
    marks = self.marks[side],
    foreign = fp,
  }
end

--- Paint `side`'s pane so a window `height` rows tall shows view row `v` first, which no top
--- of the pane shows as it is (`scene/park.lua`). Returns the top to put it at and the line
--- its cursor stays on; nil when it cannot be parked.
---@param side NvimDiff.Side
---@param v integer
---@param height integer
---@return integer? topline
---@return integer? topfill
---@return integer? lnum
function Pair:park(side, v, height)
  local pane = self:park_pane(side)
  if not pane then
    return nil
  end
  local p, tl, tf = park.park(pane, v, height, self.parks[side])
  self.parks[side] = p
  return tl, tf, p and p.line
end

--- Paint `side`'s pane as it is again, after `park`.
---@param side NvimDiff.Side
function Pair:unpark(side)
  local p = self.parks[side]
  self.parks[side] = nil
  local pane = p and self:park_pane(side)
  if pane and p then
    park.unpark(pane, p)
  else
    park.clear(self.wins[side])
  end
end

--- Record what a paint of the panes' virtual rows put there: a park painted over is gone.
---@param rows { old?: NvimDiff.VirtRows[], new?: NvimDiff.VirtRows[] }
function Pair:painted(rows)
  for _, side in ipairs(SIDES) do
    if rows[side] then
      self.marks[side] = park.index(rows[side])
      self.parks[side] = nil
    end
  end
end

--- Put `win`'s pane at view row 0, cursor on its first line, and bring the other pane
--- along: what `gg` does in a pane with a header line. Without one, the rows above the
--- first line show only with `topfill`, which `gg`, `:1` and `zz` reset. A pane with more
--- rows above its first line than the window holds is parked to show them.
---@param win integer
function Pair:top(win)
  if self:side_of(win) then
    self.sync:show(0, win)
  end
end

--- Map `gg` and `<C-Home>` in both panes to `top`, which also shows the rows above the
--- first line. With a count they go to that line, as usual.
function Pair:map_top_keys()
  for _, side in ipairs(SIDES) do
    for _, lhs in ipairs({ "gg", "<C-Home>" }) do
      vim.keymap.set("n", lhs, function()
        if vim.v.count > 0 then
          vim.cmd.normal({ vim.v.count .. "gg", bang = true })
          return
        end
        vim.cmd.normal({ "m'", bang = true })
        self:top(api.nvim_get_current_win())
      end, { buffer = self.bufs[side], desc = "nvim-diff (top of the file)" })
    end
  end
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

--- Buffer line of the file's line `lnum` (either side).
---@param lnum integer
---@return integer
function Pair:buf_line(lnum)
  return self.map:buf_line(lnum)
end

--- The file's line under `side`'s cursor; nil on the header or the trailer.
---@param side NvimDiff.Side
---@return integer?
function Pair:cursor_line(side)
  return self.map:file_line(side, api.nvim_win_get_cursor(self.wins[side])[1])
end

--- Put `side`'s cursor on the file's line `lnum` (at byte `col`, default 0) and bring the
--- other pane along.
---@param side NvimDiff.Side
---@param lnum integer
---@param col? integer
function Pair:jump(side, lnum, col)
  local win = self.wins[side]
  local bl = math.max(1, math.min(self:buf_line(lnum), api.nvim_buf_line_count(self.bufs[side])))
  api.nvim_win_set_cursor(win, { bl, col or 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  self.sync:sync(win)
end

-- Jumps out of a real file's pane --------------------------------------------------------

--- Take another buffer shown in `side`'s pane window (`PairSide.on_jump`) back out, and
--- tell `on_jump` where it went. Not at once: when the buffer comes in (`BufWinEnter`) the
--- jump has not put the cursor on its target yet. Once it is over — at the next cursor
--- move, before the screen is redrawn, or the next tick, whichever comes first — the pane
--- gets its buffer back: Neovim restores its window options and folds, which it keeps per
--- buffer and window, and the view is the one the pane left with.
---@param side NvimDiff.Side
---@param on_jump fun(jump: NvimDiff.PaneJump)
function Pair:catch_jumps(side, on_jump)
  local win, buf = self.wins[side], self.bufs[side]
  local view
  -- Buffers read from disk in the pane window: only a jump puts one there.
  local read = {}
  local pending = false

  local function back()
    if not pending then
      return
    end
    pending = false
    if self.closed or not api.nvim_win_is_valid(win) then
      return
    end
    local now = api.nvim_win_get_buf(win)
    if now == buf then
      return
    end
    local cursor = api.nvim_win_get_cursor(win)
    local jump = { buf = now, lnum = cursor[1], col = cursor[2], read = read[now] == true }
    read = {}
    -- Hidden, as with `:hide`: with 'nohidden' the jump's buffer would be unloaded on its
    -- way out, its language server detached (which redraws the screen, the pane showing it).
    local hidden = vim.o.hidden
    vim.o.hidden = true
    local ok, err = pcall(api.nvim_win_set_buf, win, buf)
    vim.o.hidden = hidden
    if not ok then
      error(err, 0)
    end
    if view then
      api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
    self.sync:sync(win)
    on_jump(jump)
  end

  api.nvim_create_autocmd("BufLeave", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      if api.nvim_get_current_win() == win then
        view = vim.fn.winsaveview()
      end
    end,
  })
  api.nvim_create_autocmd("BufReadPost", {
    group = self.augroup,
    callback = function(args)
      if args.buf ~= buf and api.nvim_get_current_win() == win then
        read[args.buf] = true
      end
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = self.augroup,
    callback = function(args)
      -- `nvim_win_set_buf` on the pane makes it current while its autocmds run.
      if pending or args.buf == buf or api.nvim_get_current_win() ~= win then
        return
      end
      pending = true
      api.nvim_create_autocmd("CursorMoved", { group = self.augroup, once = true, callback = back })
      vim.schedule(back)
    end,
  })
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

--- Rebuild the map from the current blocks, folds and foreign virtual lines, and repaint
--- every virtual row — of `sides` only, when given.
---@param sides? { old?: boolean, new?: boolean }
function Pair:rebuild_virt(sides)
  self.map = rowmap.new(self.diff, self:block_list(), self.folds, self.layout, self.foreign)
  if not sides then
    self.filler_width = sidebyside.filler_width()
    self.virt_keep = sidebyside.virt_keep()
  end
  local rows = {}
  for _, side in ipairs(SIDES) do
    if not sides or sides[side] then
      rows[side] = sidebyside.paint_virt(self.bufs[side], self.map, side, self.cols, self.ns[side].virt)
    end
  end
  self:painted(rows)
end

--- Rebuild the map from the current blocks and folds, repaint every virtual row, realign.
function Pair:repaint_virt()
  self:rebuild_virt()
  self.sync:refresh()
end

-- Foreign virtual lines ------------------------------------------------------------------

--- What counting `side`'s foreign virtual lines needs; nil when its window no longer shows
--- its buffer.
---@param side NvimDiff.Side
---@return NvimDiff.ForeignPane?
function Pair:foreign_pane(side)
  local win, buf, ns = self.wins[side], self.bufs[side], self.ns[side]
  if not (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf) then
    return nil
  end
  return {
    buf = buf,
    win = win,
    own = { [ns.line] = true, [ns.virt] = true },
    head = self.map:head(),
    count = self.diff[side .. "_count"],
  }
end

--- The virtual lines other plugins draw in each pane now, in the whole buffer.
---@return { old: NvimDiff.ForeignLines, new: NvimDiff.ForeignLines }
function Pair:count_foreign()
  local out = {}
  for _, side in ipairs(SIDES) do
    local pane = self:foreign_pane(side)
    out[side] = pane and foreign.scan(pane) or { below = {}, above = {} }
  end
  return out
end

--- `side`'s pane is being redrawn, buffer rows `top..bot`: virtual lines may have come or
--- gone there. Count them once the redraw is over, when every decoration provider has
--- placed its marks (a code lens is placed in one); several redraws before that add up.
---@param side NvimDiff.Side
---@param top integer
---@param bot integer
function Pair:foreign_redrawn(side, top, bot)
  if self.closed then
    return
  end
  local due = self.foreign_due[side]
  self.foreign_due[side] = due and { math.min(due[1], top), math.max(due[2], bot) } or { top, bot }
  if self.foreign_scheduled then
    return
  end
  self.foreign_scheduled = true
  vim.schedule(function()
    self.foreign_scheduled = false
    if not self.closed then
      self:update_foreign()
    end
  end)
end

--- Count the foreign virtual lines of the rows redrawn since the last count again and, when
--- they changed, pad and realign. The row above the first is counted too: what hangs under
--- it shows above the top line (`topfill`). Only the side opposite a change is repainted,
--- unless both sides have foreign lines: a side's own marks change only where the other
--- side pads it.
function Pair:update_foreign()
  local due = self.foreign_due
  self.foreign_due = {}
  local now = { old = self.foreign.old, new = self.foreign.new }
  local paint
  for _, side in ipairs(SIDES) do
    local pane, rows = self:foreign_pane(side), due[side]
    local spliced
    if pane and rows then
      local first, last = rows[1] - 1, rows[2] + 1
      local lo, hi = foreign.lines_of(pane, first, last)
      spliced = foreign.splice(now[side], foreign.scan(pane, first, last), lo, hi)
    end
    if spliced then
      now[side] = spliced
      local other = side == "old" and "new" or "old"
      paint = paint or {}
      paint[other] = true
      if foreign.any(now[other]) then
        paint[side] = true
      end
    end
  end
  if not paint then
    return
  end
  self.foreign = now
  self:rebuild_virt(paint)
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

--- The side and file line under the cursor of the current window, when it is a pane.
---@return NvimDiff.Side?
---@return integer?
function Pair:fold_cursor()
  local side = self:side_of(api.nvim_get_current_win())
  if not side then
    return nil, nil
  end
  return side, self:cursor_line(side)
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

--- The display row a block after `row` hangs off, which no fold may hide: `row` itself, or,
--- for a block above the first row of panes with no header line, the first row — its rows
--- are `virt_lines_above` that row, which a closed fold would hide.
---@param row integer
---@return integer
function Pair:hang_row(row)
  if row == 0 and self.layout.header == false then
    return 1
  end
  return row
end

--- `list` with every row a block hangs off revealed.
---@param list NvimDiff.Fold[]
---@return NvimDiff.Fold[]
function Pair:reveal_blocks(list)
  for _, b in ipairs(self:block_list()) do
    list = fold.reveal(list, self:hang_row(b.row))
  end
  return list
end

--- Replace the fold list and rebuild both panes' folds, keeping `leader`'s view (default:
--- the current pane) and putting its cursor on `cursor` (a file line of the leader's side)
--- when given. Rows that blocks hang off are always kept visible.
---@param list NvimDiff.Fold[]
---@param leader? integer
---@param cursor? integer
function Pair:set_folds(list, leader, cursor)
  list = self:reveal_blocks(list)
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
        other.skipcol = 0
        api.nvim_win_call(win, function()
          vim.fn.winrestview(other)
        end)
      end
    end
    if view then
      if cursor then
        view.lnum = self:buf_line(cursor)
        view.col, view.curswant = 0, 0
      end
      view.skipcol = 0
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

--- Show another diff of the same two files — the structural and the line diff of one file
--- pair have the same rows, so the panes, their text and the view stay; the highlights are
--- repainted and the folds rebuilt with `fold.carry` (expanded context stays expanded, the
--- new diff's reformats start folded).
---@param diff NvimDiff.Diff Same `rows`, `old_count` and `new_count` as the current one.
function Pair:set_diff(diff)
  assert(
    diff.rows == self.diff.rows and diff.old_count == self.diff.old_count and diff.new_count == self.diff.new_count,
    "nvim-diff: set_diff needs a diff of the same files"
  )
  self.diff = diff
  local base = self.fold_opts and fold.compute(diff, self.fold_opts) or {}
  local list = self:reveal_blocks(self.fold_opts and fold.carry(self.folds, base) or {})
  self.fold_base = base
  self.folds = list
  self.map = rowmap.new(diff, self:block_list(), list, self.layout, self.foreign)
  self:painted(sidebyside.render(self.bufs, self.map, self.cols, self.ns))
  self:set_folds(list)
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
  if fold.find(self.folds, self:hang_row(block.row)) then
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

--- Tear the pair down: stop syncing, close both panes, release both buffers (wiped, or
--- kept for reuse — `scene/buffer.lua`; a real file's handed back — `scene/filebuf.lua`).
--- Idempotent.
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
  for _, side in ipairs(SIDES) do
    foreign.unwatch(self.wins[side], self.watchers[side])
  end
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, side in ipairs(SIDES) do
    local win = self.wins[side]
    park.clear(win)
    if api.nvim_win_is_valid(win) then
      api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
      if self.claims[side] and api.nvim_win_get_buf(win) == self.bufs[side] then
        -- Before the real file's buffer leaves the window, which it remembers.
        self.claims[side]:reset_window(win)
      end
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
    if self.claims[side] then
      self.claims[side]:release()
    else
      buffer.release(self.bufs[side])
    end
  end
end

return M
