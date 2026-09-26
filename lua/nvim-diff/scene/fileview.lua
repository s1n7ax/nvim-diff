--- One file's diff on screen, in either layout, with the key that flips between them.
---
--- Holds what both layouts are built from — the spec and the inserted blocks — and the
--- scene currently showing it: a `scene/pair.lua` (side-by-side, the default) or a
--- `scene/unified.lua`. Toggling tears the scene down and builds the other one in the same
--- place: the window the cursor is in is reused, the other pane's window is closed (to
--- unified) or split off to the left (to side-by-side). Blocks are replayed into the new
--- scene, and the cursor stays on the same file line at the same screen row.
---
--- Context folds survive the toggle: both layouts fold the same display-row list, so the
--- new scene opens with the old scene's current folds (what was expanded stays expanded)
--- and the same base to collapse back to.
---
--- A second key flips the diff mode: structural (treesitter, `diff/structural.lua`; the
--- default when `diff.structural` is on) or raw line diff. Both are diffs of the same lines
--- with the same rows, so the flip repaints the scene in place rather than rebuilding it.
--- The structural diff is computed on first need, and when it cannot be (no parser, a
--- syntax error, the two sides in different languages, over `thresholds.structural_lines`)
--- the view shows the line diff and says why when asked to flip.
---
---     local view = require("nvim-diff.scene.fileview").open({
---       diff = d,
---       old = { lines = old_lines, label = "a/foo.lua" },
---       new = { lines = new_lines, label = "b/foo.lua" },
---     })
---     view:toggle()

local config = require("nvim-diff.config")
local fold = require("nvim-diff.render.fold")
local help = require("nvim-diff.ui.help")
local log = require("nvim-diff.core.log")
local pair = require("nvim-diff.scene.pair")
local structural = require("nvim-diff.diff.structural")
local unified = require("nvim-diff.scene.unified")
local unified_rows = require("nvim-diff.render.unified")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

---@alias NvimDiff.Layout "side_by_side"|"unified"

--- Which diff a view shows: syntax-aware, or the raw line diff.
---@alias NvimDiff.DiffMode "structural"|"line"

---@class NvimDiff.FileViewSpec
---@field diff NvimDiff.Diff The line diff of `old.lines` and `new.lines`.
---@field old NvimDiff.PairSide
---@field new NvimDiff.PairSide
---@field layout? NvimDiff.Layout Default: `config.layout`.
--- Default: `"structural"` when `diff.structural` is on. A structural diff that cannot be
--- computed opens as `"line"`.
---@field mode? NvimDiff.DiffMode
--- Windows to open in: `{ old, new }` for side-by-side, `{ win }` for unified. Omitted: a
--- new tabpage.
---@field wins? { old?: integer, new?: integer, win?: integer }
--- Called with the view once its first scene is up, and again after every flip, when the
--- new scene's buffers and windows are in place. Buffers are new on every flip, so an owner
--- that maps its own keys in them (the file panel's next/previous file) does it here.
---@field on_scene? fun(view: NvimDiff.FileView)
--- Context folding, as `NvimDiff.PairSpec.fold`, for both layouts.
---@field fold? false|{ context?: integer, step?: integer }
--- Side-by-side only, as `NvimDiff.PairSpec.winbar` and `.signs`; unified keeps its header
--- line and has no sign column.
---@field winbar? boolean
---@field signs? boolean

---@class NvimDiff.FileView
---@field layout NvimDiff.Layout
---@field mode NvimDiff.DiffMode
--- The line diff, and the structural one once computed (`false`: it cannot be).
---@field diffs { line: NvimDiff.Diff, structural?: NvimDiff.Diff|false }
---@field structural_reason? string Why there is no structural diff.
---@field scene NvimDiff.Pair|NvimDiff.Unified
---@field private spec NvimDiff.FileViewSpec
---@field private blocks table<any, NvimDiff.Block>
---@field private block_order any[]
--- The side the cursor was on in side-by-side, so returning to it from an unchanged line
--- (which unified shows once, as neither side in particular) lands in the same pane.
---@field private side NvimDiff.Side
--- More scene callbacks besides the spec's `on_scene`, added with `watch_scene`.
---@field private watchers table<integer, fun(view: NvimDiff.FileView)>
---@field private next_watcher integer
local View = {}
View.__index = View

--- Where the cursor is, as a file position and a screen row.
---@class NvimDiff.FileViewCursor
---@field side NvimDiff.Side
---@field lnum? integer Nil on the header or the trailer.
---@field winline integer

---@param spec NvimDiff.FileViewSpec
---@return NvimDiff.FileView
function M.open(spec)
  local layout = spec.layout or config.get().layout
  local mode = spec.mode or (config.get().diff.structural and "structural" or "line")
  local self = setmetatable({
    spec = spec,
    layout = layout,
    diffs = { line = spec.diff },
    blocks = {},
    block_order = {},
    side = "new",
    watchers = {},
    next_watcher = 0,
  }, View)
  self.mode = mode == "structural" and self:structural_diff() and "structural" or "line"
  local wins = spec.wins or {}
  if layout == "unified" then
    self:open_unified(wins.win)
  else
    self:open_pair(wins.old and wins.new and { old = wins.old, new = wins.new } or nil)
  end
  self:notify()
  return self
end

--- The structural diff, computed on first call; nil when it cannot be, with the reason
--- in `structural_reason`.
---@return NvimDiff.Diff?
function View:structural_diff()
  if self.diffs.structural == nil then
    local s = self.spec
    local lang = s.new.lang or s.old.lang
    local why
    local d
    if not lang then
      why = "no treesitter parser for this file"
    elseif s.old.lang and s.new.lang and s.old.lang ~= s.new.lang then
      why = ("the sides are different languages (%s, %s)"):format(s.old.lang, s.new.lang)
    else
      local c = config.get()
      d, why = structural.diff(s.diff, s.old.lines, s.new.lines, lang, {
        algorithm = c.diff.algorithm,
        max_lines = c.thresholds.structural_lines,
        normalize_comments = c.diff.normalize_comment_whitespace,
      })
    end
    self.diffs.structural = d or false
    self.structural_reason = why
  end
  return self.diffs.structural or nil
end

--- The diff showing.
---@return NvimDiff.Diff
function View:diff()
  return self.diffs[self.mode] or self.diffs.line
end

--- The file lines of one side, as diffed. Not a copy: do not change them.
---@param side NvimDiff.Side
---@return string[]
function View:lines(side)
  return self.spec[side].lines
end

--- Tell the owner a scene is up, then every watcher, in the order they were added.
function View:notify()
  if self.spec.on_scene then
    self.spec.on_scene(self)
  end
  for i = 1, self.next_watcher do
    local fn = self.watchers[i]
    if fn then
      fn(self)
    end
  end
end

--- Call `fn` whenever `on_scene` would be (after every flip and mode change), for a second
--- party that decorates the view's buffers — comment threads map their keys in each new
--- scene's buffers this way. Not called for the scene already up.
---@param fn fun(view: NvimDiff.FileView)
---@return fun() unwatch Idempotent.
function View:watch_scene(fn)
  self.next_watcher = self.next_watcher + 1
  local id = self.next_watcher
  self.watchers[id] = fn
  return function()
    self.watchers[id] = nil
  end
end

--- The scene's buffers: `{ old, new }` side-by-side, `{ buf }` unified.
---@return integer[]
function View:bufs()
  if self.layout == "unified" then
    return { self.scene.buf }
  end
  return { self.scene.bufs.old, self.scene.bufs.new }
end

--- The scene's windows, left to right.
---@return integer[]
function View:wins()
  if self.layout == "unified" then
    return { self.scene.win }
  end
  return { self.scene.wins.old, self.scene.wins.new }
end

---@param win? integer
---@param folds? NvimDiff.Fold[] Folds to carry over from the scene being replaced.
function View:open_unified(win, folds)
  local s = self.spec
  self.scene = unified.open({ diff = self:diff(), old = s.old, new = s.new, win = win, fold = s.fold, folds = folds })
  self:after_open({ self.scene.buf })
end

---@param wins? { old: integer, new: integer }
---@param folds? NvimDiff.Fold[] Folds to carry over from the scene being replaced.
function View:open_pair(wins, folds)
  local s = self.spec
  self.scene = pair.open({
    diff = self:diff(),
    old = s.old,
    new = s.new,
    wins = wins,
    fold = s.fold,
    folds = folds,
    winbar = s.winbar,
    signs = s.signs,
  })
  self:after_open({ self.scene.bufs.old, self.scene.bufs.new })
end

--- Replay the blocks and map the keys in a freshly opened scene.
---@param bufs integer[]
function View:after_open(bufs)
  for _, id in ipairs(self.block_order) do
    self.scene:set_block(id, self.blocks[id])
  end
  local keys = config.get().layout_keymaps
  for _, buf in ipairs(bufs) do
    help.attach(buf)
    if type(keys.toggle) == "string" then
      vim.keymap.set("n", keys.toggle, function()
        self:toggle()
      end, { buffer = buf, nowait = true, desc = "nvim-diff: toggle side-by-side / unified" })
    end
    if type(keys.toggle_structural) == "string" then
      vim.keymap.set("n", keys.toggle_structural, function()
        self:toggle_mode()
      end, { buffer = buf, nowait = true, desc = "nvim-diff: toggle structural / line diff" })
    end
  end
end

--- Whether the view's scene is gone (the user closed its window).
---@return boolean
function View:is_closed()
  return self.scene.closed
end

--- The cursor of the current scene, read from the current window when it is one of the
--- scene's, else from the new pane (or the only one). On a closed fold the file line is
--- the fold's first line on the side, wherever inside it the cursor sits, so the fold's
--- band is found again in the other layout.
---
--- The screen row comes from each layout's row maths, not `winline()`: measured, that is
--- off by the virtual rows above a closed fold at the top of the view, or right above one.
---@return NvimDiff.FileViewCursor
function View:cursor()
  local cur = api.nvim_get_current_win()
  if self.layout == "unified" then
    local u = self.scene --[[@as NvimDiff.Unified]]
    local winline = u:winline()
    local bl = api.nvim_win_get_cursor(u.win)[1]
    local f = u:fold_on_line(bl)
    if f then
      -- The band is neither side in particular: keep the remembered side if it has lines.
      local side = self.side
      local first = fold.side_lines(u.diff, f, side)
      if not first then
        side = side == "old" and "new" or "old"
        first = fold.side_lines(u.diff, f, side)
      end
      return { side = side, lnum = first, winline = winline }
    end
    local side, lnum = u:cursor_pos()
    local l = u.layout.lines[bl - 1]
    if l and l.kind == "context" then
      side, lnum = self.side, l[self.side]
    end
    return { side = side or self.side, lnum = lnum, winline = winline }
  end
  local p = self.scene --[[@as NvimDiff.Pair]]
  local side = p:side_of(cur) or "new"
  local win = p.wins[side]
  local lnum = p:cursor_line(side)
  local closed = api.nvim_win_call(win, function()
    return vim.fn.foldclosed(".")
  end)
  if closed > 0 then
    lnum = p.map:file_line(side, closed)
  elseif not lnum and api.nvim_win_get_cursor(win)[1] == p.map:trailer_line(side) then
    lnum = p.diff[side .. "_count"] -- the trailer: the side's last line
  end
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local at, top = p.map:line_view(side, view.lnum), p.map:top_view(side, view.topline, view.topfill)
  local winline = at and top and at - top + 1 or api.nvim_win_call(win, vim.fn.winline)
  return { side = side, lnum = lnum, winline = winline }
end

--- The file line buffer line `bl` of scene window `win` shows, and its side. In
--- side-by-side the side is the pane's; in unified a deleted line is `old` and every other
--- line `new` (as GitHub's unified view anchors a comment on an unchanged line). Nil for a
--- window that is not the scene's, the header, and the trailer.
---@param win integer
---@param bl integer
---@return NvimDiff.Side?
---@return integer?
function View:line_at(win, bl)
  if self.layout == "unified" then
    local u = self.scene --[[@as NvimDiff.Unified]]
    if u.win ~= win then
      return nil, nil
    end
    local side, lnum = unified_rows.line_at(u.layout, bl)
    if not lnum then
      return nil, nil
    end
    return side, lnum
  end
  local p = self.scene --[[@as NvimDiff.Pair]]
  local side = p:side_of(win)
  local lnum = side and p.map:file_line(side, bl)
  if not lnum then
    return nil, nil
  end
  return side, lnum
end

--- Put a pair pane's cursor on buffer line `bl`, scrolled so it sits on screen row
--- `winline` as far as the file allows, and bring the other pane along.
---@param p NvimDiff.Pair
---@param side NvimDiff.Side
---@param bl integer
---@param winline integer
local function place_pair(p, side, bl, winline)
  local win = p.wins[side]
  local v = math.max(0, math.min((p.map:line_view(side, bl) or 0) - (winline - 1), p:max_top()))
  local tl, tf = p.map:view_top(side, v)
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = tl or 1, topfill = tf or 0, lnum = bl, col = 0, curswant = 0 })
  end)
  p.sync:sync(win)
end

--- Put `side`'s cursor on file line `lnum`, in whichever layout is showing, and bring the
--- other pane along (side-by-side) or just centre it (unified).
---@param side NvimDiff.Side
---@param lnum integer
function View:jump(side, lnum)
  self.scene:jump(side, lnum)
end

--- Flip to the other layout.
function View:toggle()
  self:set_layout(self.layout == "unified" and "side_by_side" or "unified")
end

--- Show the file in `layout`; a no-op when it already is, or when the view is closed.
---@param layout NvimDiff.Layout
function View:set_layout(layout)
  if layout == self.layout or self:is_closed() then
    return
  end
  local at = self:cursor()
  local old_scene = self.scene
  if layout == "unified" then
    self.side = at.side
    local p = old_scene --[[@as NvimDiff.Pair]]
    local win = p.wins[at.side]
    self:open_unified(win, p.folds)
    p:close({ keep = win })
    self.layout = "unified"
    local u = self.scene --[[@as NvimDiff.Unified]]
    api.nvim_set_current_win(u.win)
    u:place(at.lnum and u:buf_line(at.side, at.lnum) or 1, at.winline)
  else
    local u = old_scene --[[@as NvimDiff.Unified]]
    local win = u.win
    local left = api.nvim_open_win(window.scratch(), false, { split = "left", win = win })
    self:open_pair({ old = left, new = win }, u.folds)
    u:close({ keep = win })
    self.layout = "side_by_side"
    local p = self.scene --[[@as NvimDiff.Pair]]
    local pwin = p.wins[at.side]
    api.nvim_set_current_win(pwin)
    local bl = 1
    if at.lnum and p.diff[at.side .. "_count"] > 0 then
      bl = p:buf_line(at.lnum)
    end
    place_pair(p, at.side, bl, at.winline)
  end
  self:notify()
end

--- Flip between the structural and the line diff.
---@return boolean ok False when the structural diff cannot be shown (see `set_mode`).
function View:toggle_mode()
  return (self:set_mode(self.mode == "structural" and "line" or "structural"))
end

--- Show the `mode` diff, repainting the scene in place: same buffers, windows and cursor,
--- context folds as they were, the new diff's reformats folded. A no-op when it already
--- shows or the view is closed. Asking for structural where it cannot be computed warns
--- with the reason and keeps the line diff.
---@param mode NvimDiff.DiffMode
---@return boolean ok
---@return string? reason Why not, when not ok.
function View:set_mode(mode)
  if self:is_closed() then
    return false, "closed"
  end
  if mode == self.mode then
    return true
  end
  local d = self.diffs.line
  if mode == "structural" then
    d = self:structural_diff()
  end
  if not d then
    log.warn("structural diff unavailable: %s", self.structural_reason)
    return false, self.structural_reason
  end
  self.mode = mode
  self.scene:set_diff(d)
  self:notify()
  return true
end

--- Insert (or replace) rows after display row `block.row`, in whichever layout is showing,
--- and keep them across toggles. See `Pair:set_block` and `Unified:set_block`.
---@param id any
---@param block NvimDiff.Block
function View:set_block(id, block)
  if not self.blocks[id] then
    self.block_order[#self.block_order + 1] = id
  end
  self.blocks[id] = block
  self.scene:set_block(id, block)
end

--- Remove a block. No-op for an unknown id.
---@param id any
function View:remove_block(id)
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
  self.scene:remove_block(id)
end

--- Close whichever scene is showing. Idempotent.
function View:close()
  self.scene:close()
end

return M
