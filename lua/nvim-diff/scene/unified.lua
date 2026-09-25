--- A unified pane: one read-only window showing both sides of one diff, decorated by
--- `render/unified.lua`. The single-pane counterpart of `scene/pair.lua`, with the same
--- spec and the same block API, so a caller (the layout toggle, comment threads) can drive
--- either without caring which one is open. There is no scroll corrector: one pane has
--- nothing to stay aligned with.
---
--- Context folding is the pair's: the same fold list (display-row ranges from
--- `render/fold.lua`), the same fold methods and the same fold keys (`scene/folds.lua`).
--- Each fold is one range of buffer lines here (`render/unified.lua` `fold_lines`), so a
--- reformatted hunk — old lines and new lines — collapses to one band.
---
---     local u = require("nvim-diff.scene.unified").open({
---       diff = require("nvim-diff.diff.line").diff(old_lines, new_lines),
---       old = { lines = old_lines, label = "a/lua/foo.lua" },
---       new = { lines = new_lines, label = "b/lua/foo.lua" },
---     })

local buffer = require("nvim-diff.scene.buffer")
local event = require("nvim-diff.core.event")
local fold = require("nvim-diff.render.fold")
local folds_scene = require("nvim-diff.scene.folds")
local hl = require("nvim-diff.ui.hl")
local sidebyside = require("nvim-diff.render.sidebyside")
local unified = require("nvim-diff.render.unified")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

---@class NvimDiff.UnifiedSpec
---@field diff NvimDiff.Diff
---@field old NvimDiff.PairSide
---@field new NvimDiff.PairSide
---@field header? string Full header text; default `── <old label> → <new label> ──`.
---@field name? string Buffer name. Unnamed when omitted: the pair's per-blob names belong to the pair.
---@field win? integer Window to show the pane in. Omitted: a new tabpage.
--- Context folding, as `NvimDiff.PairSpec.fold`: `false` to show every line.
---@field fold? false|{ context?: integer, step?: integer }
--- The folds to open with instead of the computed ones, as `NvimDiff.PairSpec.folds`.
---@field folds? NvimDiff.Fold[]

---@class NvimDiff.Unified
---@field diff NvimDiff.Diff
---@field layout NvimDiff.UnifiedLayout
---@field buf integer
---@field win integer
---@field closed boolean
---@field lines { old: string[], new: string[] }
--- Closed folds, as display-row ranges: the same list a pair of this diff would carry.
---@field folds NvimDiff.Fold[]
---@field fold_base NvimDiff.Fold[] The folds the pane opened with; collapsing restores them.
---@field fold_opts false|NvimDiff.FoldOpts The spec's `fold`: false when folding is off.
---@field fold_step integer
---@field ranges NvimDiff.UnifiedFoldRange[] `folds` as buffer lines of the pane.
---@field private blocks table<any, NvimDiff.Block>
---@field private block_order any[]
---@field private augroup integer
---@field private virt { anchor: integer, lines: NvimDiff.VirtLine[] }[] The painted virtual rows.
local Unified = {}
Unified.__index = Unified

--- The default header of a unified pane.
---@param old_label string
---@param new_label string
---@return string
function M.header(old_label, new_label)
  if old_label == new_label then
    return sidebyside.header(old_label)
  end
  return sidebyside.header(old_label .. " → " .. new_label)
end

---@param spec NvimDiff.UnifiedSpec
---@return NvimDiff.Unified
function M.open(spec)
  hl.setup()
  local diff = spec.diff
  local layout = unified.layout(diff)
  local fold_opts = spec.fold == nil and {} or spec.fold
  local base = fold_opts and fold.compute(diff, fold_opts) or {}
  local self = setmetatable({
    diff = diff,
    layout = layout,
    blocks = {},
    block_order = {},
    closed = false,
    lines = { old = spec.old.lines, new = spec.new.lines },
    folds = fold_opts and spec.folds and vim.deepcopy(spec.folds) or base,
    fold_base = base,
    fold_step = fold_opts and fold_opts.step or fold.STEP,
    fold_opts = fold_opts,
    ranges = {},
  }, Unified)

  self.buf = buffer.create({
    lines = unified.text(layout, spec.old.lines, spec.new.lines),
    header = spec.header or M.header(spec.old.label, spec.new.label),
    name = spec.name,
    lang = spec.new.lang or spec.old.lang,
  })

  local placeholder
  if spec.win then
    self.win = spec.win
  else
    vim.cmd("tabnew")
    self.win = api.nvim_get_current_win()
    placeholder = api.nvim_win_get_buf(self.win)
  end
  window.pane(self.win, self.buf, { statuscolumn = unified.statuscolumn(sidebyside.number_width(diff)) })
  folds_scene.setup_window(self.win)
  self:apply_folds()
  api.nvim_win_set_cursor(self.win, { 1, 0 })
  if placeholder and api.nvim_buf_is_valid(placeholder) and api.nvim_buf_get_name(placeholder) == "" then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end

  self.virt = unified.render(self.buf, layout)

  self.augroup = api.nvim_create_augroup("nvim-diff.unified." .. self.buf, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.win),
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  folds_scene.attach(self, { self.buf }, self.augroup)

  event.emit_in({ win = self.win, buf = self.buf }, event.events.DIFF_BUF_READY, self.buf, {
    layout = "unified",
    unified = self,
  })
  return self
end

--- The side and file line under the cursor: `old` on a deleted line, `new` on an added or
--- unchanged one. Nil on the header.
---@return NvimDiff.Side?
---@return integer?
function Unified:cursor_pos()
  return unified.line_at(self.layout, api.nvim_win_get_cursor(self.win)[1])
end

--- The file line of `side` under the cursor: nil on the header, and on a line that only
--- exists on the other side.
---@param side NvimDiff.Side
---@return integer?
function Unified:cursor_line(side)
  local l = self.layout.lines[api.nvim_win_get_cursor(self.win)[1] - 1]
  return l and l[side]
end

--- Buffer line of `side`'s file line `lnum`, clamped into the file (the header when the
--- side is empty).
---@param side NvimDiff.Side
---@param lnum integer
---@return integer
function Unified:buf_line(side, lnum)
  local count = self.diff[side .. "_count"]
  if count == 0 then
    return 1
  end
  return unified.buf_line(self.layout, side, math.max(1, math.min(lnum, count)))
end

--- Put the cursor on `side`'s file line `lnum`, centred.
---@param side NvimDiff.Side
---@param lnum integer
function Unified:jump(side, lnum)
  api.nvim_win_set_cursor(self.win, { self:buf_line(side, lnum), 0 })
  api.nvim_win_call(self.win, function()
    vim.cmd("normal! zz")
  end)
end

--- Put the cursor on buffer line `bl` with the view scrolled so it sits on screen row
--- `winline` (1-based), as far as the file allows. A line inside a closed fold sits on the
--- fold's row.
---@param bl integer
---@param winline integer
function Unified:place(bl, winline)
  local v = unified.line_view(self.virt, bl, self.ranges) - (winline - 1)
  local tl, tf = unified.view_top(self.virt, api.nvim_buf_line_count(self.buf), v, self.ranges)
  api.nvim_win_call(self.win, function()
    vim.fn.winrestview({ topline = tl, topfill = tf, lnum = bl, col = 0, curswant = 0 })
  end)
end

--- The cursor's screen row in the pane (1-based), from the pane's own row maths. Not
--- `winline()`: measured, it is off with a closed fold at the top of the view under
--- `topfill`, or right below virtual rows, while the screen is right.
---@return integer
function Unified:winline()
  local view = api.nvim_win_call(self.win, vim.fn.winsaveview)
  local top = unified.line_view(self.virt, view.topline, self.ranges) - view.topfill
  return unified.line_view(self.virt, view.lnum, self.ranges) - top + 1
end

--- Show another diff of the same two files, as `Pair:set_diff`: same rows, so the buffer
--- and view stay; highlights are repainted and folds rebuilt with `fold.carry`.
---@param diff NvimDiff.Diff
function Unified:set_diff(diff)
  assert(
    diff.rows == self.diff.rows and diff.old_count == self.diff.old_count and diff.new_count == self.diff.new_count,
    "nvim-diff: set_diff needs a diff of the same files"
  )
  self.diff = diff
  self.layout = unified.layout(diff)
  local base = self.fold_opts and fold.compute(diff, self.fold_opts) or {}
  local list = self.fold_opts and fold.carry(self.folds, base) or {}
  self.fold_base = base
  self.virt = unified.render(self.buf, self.layout, self:block_list())
  self:set_folds(list)
end

--- The blocks in insertion order.
---@return NvimDiff.Block[]
function Unified:block_list()
  local list = {}
  for _, id in ipairs(self.block_order) do
    list[#list + 1] = self.blocks[id]
  end
  return list
end

--- Repaint every virtual row from the current blocks.
function Unified:repaint_virt()
  self.virt = unified.paint_virt(self.buf, self.layout, self:block_list())
end

-- Folding --------------------------------------------------------------------------------

--- Rebuild the window's folds from `folds`. Moves the view: callers restore it.
function Unified:apply_folds()
  self.ranges = unified.fold_ranges(self.layout, self.folds)
  folds_scene.build(self.win, self.ranges)
end

--- The side and file line under the cursor, when the current window is the pane.
---@return NvimDiff.Side?
---@return integer?
function Unified:fold_cursor()
  if api.nvim_get_current_win() ~= self.win then
    return nil, nil
  end
  return self:cursor_pos()
end

--- The closed fold holding the file's line `lnum` of `side`, and its index in `folds`.
---@param side NvimDiff.Side
---@param lnum integer
---@return NvimDiff.Fold?
---@return integer?
function Unified:fold_at(side, lnum)
  local d = self.diff:row_of(side, lnum)
  local i = d and fold.find(self.folds, d)
  if not i then
    return nil, nil
  end
  return self.folds[i], i
end

--- The closed fold on buffer line `bl`, if any.
---@param bl integer
---@return NvimDiff.Fold?
function Unified:fold_on_line(bl)
  local i = unified.range_at(self.ranges, bl)
  return i and self.folds[i] or nil
end

--- Replace the fold list and rebuild the pane's folds, keeping the view and putting the
--- cursor on buffer line `cursor` when given. Rows that blocks hang off are always kept
--- visible.
---@param list NvimDiff.Fold[]
---@param cursor? integer
function Unified:set_folds(list, cursor)
  for _, b in ipairs(self:block_list()) do
    list = fold.reveal(list, b.row)
  end
  self.folds = list
  local view = api.nvim_win_call(self.win, vim.fn.winsaveview)
  self:apply_folds()
  if cursor then
    view.lnum, view.col, view.curswant = cursor, 0, 0
  end
  api.nvim_win_call(self.win, function()
    vim.fn.winrestview(view)
    vim.fn.winline() -- scroll now if the cursor left the view
  end)
end

--- Reveal rows of the fold holding the file's line `lnum` of `side`, as `Pair:expand`: `n`
--- of them (default: all), from the end `dir` says. The cursor lands on what is left of the
--- fold, or on the first revealed line once the fold is gone. False when `lnum` is not
--- folded.
---@param side NvimDiff.Side
---@param lnum integer
---@param n? integer
---@param dir? NvimDiff.FoldDir
---@return boolean
function Unified:expand(side, lnum, n, dir)
  local f, i = self:fold_at(side, lnum)
  if not f or not i then
    return false
  end
  local list = fold.expand(self.folds, i, n, dir)
  local rest = fold.find(list, f.first) or fold.find(list, f.last)
  local target = rest and list[rest] or f
  self:set_folds(list, (unified.fold_lines(self.layout, target)))
  return true
end

--- Reveal every fold.
function Unified:expand_all()
  self:set_folds({})
end

--- Fold back up the context the file's line `lnum` of `side` came out of, as
--- `Pair:collapse`. The cursor lands on it. False when the line was never folded.
---@param side NvimDiff.Side
---@param lnum integer
---@return boolean
function Unified:collapse(side, lnum)
  local d = self.diff:row_of(side, lnum)
  local i = d and fold.find(self.fold_base, d)
  if not i then
    return false
  end
  local f = self.fold_base[i]
  local list = fold.restore(self.folds, self.fold_base, { [f.id] = true })
  self:set_folds(list, (unified.fold_lines(self.layout, f)))
  return true
end

--- Put every fold the pane opened with back.
function Unified:collapse_all()
  self:set_folds(vim.deepcopy(self.fold_base))
end

-- Blocks ---------------------------------------------------------------------------------

--- Insert (or replace) rows after display row `block.row`: `block.old` under the old line,
--- `block.new` under the new line. Same contract as `Pair:set_block`, a fold over that row
--- included: it is split around it.
---@param id any
---@param block NvimDiff.Block
function Unified:set_block(id, block)
  if not self.blocks[id] then
    self.block_order[#self.block_order + 1] = id
  end
  self.blocks[id] = block
  self:repaint_virt()
  if fold.find(self.folds, block.row) then
    self:set_folds(self.folds)
  end
end

--- Remove a block. No-op for an unknown id.
---@param id any
function Unified:remove_block(id)
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

---@class NvimDiff.SceneCloseOpts
--- Leave this window open (the layout toggle reuses it). If it still shows the pane's
--- buffer, that is swapped for an empty scratch buffer first.
---@field keep? integer

--- Tear the pane down: close its window, wipe its buffer. Idempotent.
---@param opts? NvimDiff.SceneCloseOpts
function Unified:close(opts)
  if self.closed then
    return
  end
  self.closed = true
  local keep = opts and opts.keep
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  if api.nvim_win_is_valid(self.win) then
    api.nvim_set_option_value("winfixbuf", false, { win = self.win, scope = "local" })
    if self.win == keep then
      if api.nvim_win_get_buf(self.win) == self.buf then
        api.nvim_win_set_buf(self.win, window.scratch())
      end
    elseif not pcall(api.nvim_win_close, self.win, true) then
      api.nvim_win_set_buf(self.win, api.nvim_create_buf(true, false))
    end
  end
  buffer.release(self.buf)
end

return M
