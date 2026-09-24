--- The unified renderer: one pane holding both sides of a `Diff`, old lines red, new lines
--- green, unchanged lines once.
---
--- Line order follows `git diff` and GitHub: unchanged runs appear once, and each hunk shows
--- all of its old lines, then all of its new lines. So a unified pane has no filler at all —
--- a line missing on one side is simply not there — and needs no trailer line.
---
--- Buffer layout: line 1 is the header (as in the side-by-side panes), line `i + 1` is
--- `layout.lines[i]`. The colouring rules are the side-by-side ones, unchanged: a range
--- extmark with `hl_eol` at priority 150 for the line, background-only tokens at 250, and
--- a wholly added or deleted line carries no token.
---
--- Inserted blocks (comment threads) use the same `NvimDiff.Block` as the pair. There is
--- nothing to pad against in one pane, so each side's rows hang below that side's line:
--- `block.old` under the old line of `block.row`, `block.new` under the new line. Where the
--- row has no line on that side (a thread on the new side of a deleted row), the rows hang
--- under the line the row does have.
---
--- Line numbers: both, in the `statuscolumn`, followed by a `-`/`+` sign. The numbers per
--- buffer line live in buffer variables that a plain Vimscript `statuscolumn` indexes, so
--- no Lua runs per drawn row.
---
--- Context folding uses the side-by-side fold list unchanged (`render/fold.lua`: display-row
--- ranges). Every fold is a run of whole display rows, and the lines of such a run are
--- contiguous here too — an unchanged run is one line per row, a reformat fold is a whole
--- hunk, which is its old lines then its new lines — so each fold is one range of buffer
--- lines (`fold_lines`) and shows as one separator band.
---
--- Pure layout (`layout`, `text`, `virt_rows`, `fold_lines`) plus painting (`render`,
--- `paint_virt`).

local fold = require("nvim-diff.render.fold")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

local M = {}

--- The same namespaces as the side-by-side panes: whatever clears or reads "the diff's
--- highlights" or "the diff's virtual rows" of a buffer does not need to know its layout.
M.ns = sidebyside.ns
M.ns_virt = sidebyside.ns_virt

--- Buffer variables the `statuscolumn` reads. Vim lists, index 0 is the header.
M.VAR_OLD = "nvim_diff_old_nr"
M.VAR_NEW = "nvim_diff_new_nr"
M.VAR_SIGN = "nvim_diff_sign"

local GROUPS = {
  deleted = { line = "NvimDiffDelLine", token = "NvimDiffDelToken", side = "old" },
  added = { line = "NvimDiffAddLine", token = "NvimDiffAddToken", side = "new" },
}

local SIGNS = { context = " ", deleted = "-", added = "+" }

---@alias NvimDiff.UnifiedKind "context"|"deleted"|"added"

--- One line of the unified pane.
---@class NvimDiff.UnifiedLine
---@field kind NvimDiff.UnifiedKind `deleted`: an old line of a hunk. `added`: a new line of a hunk.
---@field old? integer Old line number; set for `context` and `deleted`.
---@field new? integer New line number; set for `context` and `added`.
---@field changed boolean On a `changed` row, so its tokens are painted.

---@class NvimDiff.UnifiedLayout
---@field diff NvimDiff.Diff
---@field lines NvimDiff.UnifiedLine[] Buffer line `i + 1` shows `lines[i]`.
--- File line to index into `lines`, per side. An unchanged line has the same index on both.
---@field index { old: integer[], new: integer[] }

--- Lay a diff out as one pane.
---@param diff NvimDiff.Diff
---@return NvimDiff.UnifiedLayout
function M.layout(diff)
  local lines = {}
  local index = { old = {}, new = {} }

  local function push(l)
    lines[#lines + 1] = l
    if l.old then
      index.old[l.old] = #lines
    end
    if l.new then
      index.new[l.new] = #lines
    end
  end

  -- Unchanged runs and hunks, merged in display-row order.
  local ui, hi = 1, 1
  local runs, hunks = diff.unchanged, diff.hunks
  while ui <= #runs or hi <= #hunks do
    local run, h = runs[ui], hunks[hi]
    if run and (not h or run.row < h.row) then
      for k = 0, run.count - 1 do
        push({ kind = "context", old = run.old_start + k, new = run.new_start + k, changed = false })
      end
      ui = ui + 1
    else
      for _, r in ipairs(h.rows) do
        if r.old then
          push({ kind = "deleted", old = r.old, changed = r.kind == "changed" })
        end
      end
      for _, r in ipairs(h.rows) do
        if r.new then
          push({ kind = "added", new = r.new, changed = r.kind == "changed" })
        end
      end
      hi = hi + 1
    end
  end
  assert(
    #index.old == diff.old_count and #index.new == diff.new_count,
    "nvim-diff: unified layout does not cover the diff"
  )
  return { diff = diff, lines = lines, index = index }
end

--- The pane's file text, without the header: unchanged lines are taken from the new side.
---@param layout NvimDiff.UnifiedLayout
---@param old string[]
---@param new string[]
---@return string[]
function M.text(layout, old, new)
  local out = {}
  for i, l in ipairs(layout.lines) do
    if l.kind == "deleted" then
      out[i] = old[l.old]
    else
      out[i] = new[l.new]
    end
  end
  return out
end

--- Buffer line of `side`'s file line `lnum`.
---@param layout NvimDiff.UnifiedLayout
---@param side NvimDiff.Side
---@param lnum integer
---@return integer?
function M.buf_line(layout, side, lnum)
  local i = layout.index[side][lnum]
  return i and i + 1
end

--- The side and file line on buffer line `bl`: `old` on a deleted line, `new` on an added or
--- unchanged one. Nil on the header.
---@param layout NvimDiff.UnifiedLayout
---@param bl integer
---@return NvimDiff.Side?
---@return integer?
function M.line_at(layout, bl)
  local l = layout.lines[bl - 1]
  if not l then
    return nil, nil
  end
  if l.kind == "deleted" then
    return "old", l.old
  end
  return "new", l.new
end

--- 0-based buffer row the rows of `side` in a block after display row `d` hang from.
---@param layout NvimDiff.UnifiedLayout
---@param side NvimDiff.Side
---@param d integer
---@return integer
function M.anchor(layout, side, d)
  if d == 0 then
    return 0
  end
  local old, new = layout.diff:line_at(d)
  local own, other = new, old
  if side == "old" then
    own, other = old, new
  end
  if own then
    return layout.index[side][own]
  end
  return layout.index[side == "old" and "new" or "old"][other]
end

--- The virtual rows of the pane grouped by anchor, ascending, one entry per anchor. Blocks
--- sharing an anchor keep their order (by `row`, then as given), old rows before new.
---@param layout NvimDiff.UnifiedLayout
---@param blocks NvimDiff.Block[]
---@return { anchor: integer, lines: NvimDiff.VirtLine[] }[]
function M.virt_rows(layout, blocks)
  local entries = {}
  for i, b in ipairs(blocks) do
    assert(b.row >= 0 and b.row <= layout.diff.rows, "nvim-diff: block row out of range")
    for s, side in ipairs({ "old", "new" }) do
      local own = b[side]
      if own and #own > 0 then
        entries[#entries + 1] = { anchor = M.anchor(layout, side, b.row), row = b.row, seq = i * 2 + s, lines = own }
      end
    end
  end
  table.sort(entries, function(x, y)
    if x.anchor ~= y.anchor then
      return x.anchor < y.anchor
    end
    if x.row ~= y.row then
      return x.row < y.row
    end
    return x.seq < y.seq
  end)
  local out = {}
  for _, e in ipairs(entries) do
    local last = out[#out]
    if last and last.anchor == e.anchor then
      vim.list_extend(last.lines, e.lines)
    else
      out[#out + 1] = { anchor = e.anchor, lines = vim.list_extend({}, e.lines) }
    end
  end
  return out
end

--- Height of one block in the unified pane: both sides' rows, no padding.
---@param block NvimDiff.Block
---@return integer
function M.block_height(block)
  return (block.old and #block.old or 0) + (block.new and #block.new or 0)
end

--- Total rows of the pane: header, lines and every virtual row.
---@param layout NvimDiff.UnifiedLayout
---@param blocks NvimDiff.Block[]
---@return integer
function M.height(layout, blocks)
  local n = 1 + #layout.lines
  for _, b in ipairs(blocks) do
    n = n + M.block_height(b)
  end
  return n
end

--- The `statuscolumn`: old number, new number, sign; blank on virtual rows and the header.
--- Each field is a minimum-width *group* around the item. Measured: a `%{}` result loses a
--- leading space, so padded text shifts; and an empty `%3{}` takes no width at all (the
--- statuscolumn then right-pads the shorter row, moving the sign), while `%3(%{}%)` keeps
--- its three cells when empty.
---
--- On a closed fold the whole column is band fill in the separator's colour, as in the
--- side-by-side panes, so the band runs from column 1 to the window edge.
---@param width integer Digits per number, `sidebyside.number_width(diff)`.
---@return string
function M.statuscolumn(width)
  local folded = "v:virtnum==0&&foldclosed(v:lnum)>0"
  local function item(var, w)
    return ("%%%d(%%{%s?repeat('%s',%d):v:virtnum<0?'':get(b:%s,v:lnum-1,'')}%%)"):format(w, folded, fold.FILL, w, var)
  end
  local function gap(text)
    return ("%%{%%%s?'%s':'%s'%%}"):format(folded, fold.FILL, text)
  end
  return ("%%{%%%s?'%%#NvimDiffContextSeparator#':'%%#NonText#'%%}"):format(folded)
    .. item(M.VAR_OLD, width)
    .. gap(" ")
    .. item(M.VAR_NEW, width)
    .. gap(" ")
    .. item(M.VAR_SIGN, 1)
    .. gap("%#Normal# ")
end

--- The three lists the `statuscolumn` reads, index 1 (Vim's 0) being the header.
---@param layout NvimDiff.UnifiedLayout
---@return string[] old
---@return string[] new
---@return string[] sign
function M.number_lists(layout)
  local old, new, sign = { "" }, { "" }, { "" }
  for i, l in ipairs(layout.lines) do
    old[i + 1] = l.old and tostring(l.old) or ""
    new[i + 1] = l.new and tostring(l.new) or ""
    sign[i + 1] = SIGNS[l.kind]
  end
  return old, new, sign
end

---@param buf integer
---@param row integer 0-based
---@param group string
local function line_mark(buf, row, group)
  api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    end_row = row + 1,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = sidebyside.PRIORITY_LINE,
  })
end

--- Paint the header, the changed lines and their tokens, and set the number lists.
---@param buf integer
---@param layout NvimDiff.UnifiedLayout
local function paint_lines(buf, layout)
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  line_mark(buf, 0, "NvimDiffHeader")
  local tokens = layout.diff.tokens
  for i, l in ipairs(layout.lines) do
    local g = GROUPS[l.kind]
    if g then
      line_mark(buf, i, g.line)
      if l.changed then
        for _, span in ipairs(tokens[g.side][l[g.side]] or {}) do
          api.nvim_buf_set_extmark(buf, M.ns, i, span[1], {
            end_row = i,
            end_col = span[2],
            hl_group = g.token,
            priority = sidebyside.PRIORITY_TOKEN,
            strict = false,
          })
        end
      end
    end
  end
  local old, new, sign = M.number_lists(layout)
  api.nvim_buf_set_var(buf, M.VAR_OLD, old)
  api.nvim_buf_set_var(buf, M.VAR_NEW, new)
  api.nvim_buf_set_var(buf, M.VAR_SIGN, sign)
end

--- Replace every virtual row of the pane.
---@param buf integer
---@param layout NvimDiff.UnifiedLayout
---@param blocks NvimDiff.Block[]
---@return { anchor: integer, lines: NvimDiff.VirtLine[] }[] virt What was painted.
function M.paint_virt(buf, layout, blocks)
  api.nvim_buf_clear_namespace(buf, M.ns_virt, 0, -1)
  local virt = M.virt_rows(layout, blocks)
  for _, v in ipairs(virt) do
    api.nvim_buf_set_extmark(buf, M.ns_virt, v.anchor, 0, {
      virt_lines = v.lines,
      virt_lines_leftcol = true,
    })
  end
  return virt
end

--- Paint the pane in full. Idempotent: clears its own namespaces first.
---@param buf integer
---@param layout NvimDiff.UnifiedLayout
---@param blocks? NvimDiff.Block[]
---@return { anchor: integer, lines: NvimDiff.VirtLine[] }[] virt
function M.render(buf, layout, blocks)
  paint_lines(buf, layout)
  return M.paint_virt(buf, layout, blocks or {})
end

-- Folding ------------------------------------------------------------------------------

--- A closed fold as buffer lines of the pane, inclusive.
---@class NvimDiff.UnifiedFoldRange
---@field first integer
---@field last integer

--- The buffer lines fold `f` covers: from its first row's first line to its last row's last
--- line, over both sides.
---@param layout NvimDiff.UnifiedLayout
---@param f NvimDiff.Fold
---@return integer first
---@return integer last
function M.fold_lines(layout, f)
  local lo, hi
  for _, side in ipairs({ "old", "new" }) do
    local a, b = fold.side_lines(layout.diff, f, side)
    if a and b then
      local ia, ib = layout.index[side][a], layout.index[side][b]
      lo = lo and math.min(lo, ia) or ia
      hi = hi and math.max(hi, ib) or ib
    end
  end
  assert(lo and hi, "nvim-diff: a fold with no lines")
  return lo + 1, hi + 1
end

--- `fold_lines` of every fold, in order.
---@param layout NvimDiff.UnifiedLayout
---@param folds NvimDiff.Fold[]
---@return NvimDiff.UnifiedFoldRange[]
function M.fold_ranges(layout, folds)
  local out = {}
  for i, f in ipairs(folds) do
    local a, b = M.fold_lines(layout, f)
    out[i] = { first = a, last = b }
  end
  return out
end

--- Index of the range holding buffer line `bl`, if any.
---@param ranges NvimDiff.UnifiedFoldRange[]
---@param bl integer
---@return integer?
function M.range_at(ranges, bl)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = ranges[mid]
    if bl < r.first then
      hi = mid - 1
    elseif bl > r.last then
      lo = mid + 1
    else
      return mid
    end
  end
  return nil
end

--- Screen row (0 = the header) of buffer line `bl`, given the painted virtual rows and the
--- closed folds. A line inside a fold is on the fold's one row. Virtual rows anchored inside
--- a closed fold are not drawn (measured in the side-by-side folding step), so they count
--- for nothing.
---@param virt { anchor: integer, lines: NvimDiff.VirtLine[] }[]
---@param bl integer
---@param ranges? NvimDiff.UnifiedFoldRange[] Closed folds, from `fold_ranges`.
---@return integer
function M.line_view(virt, bl, ranges)
  ranges = ranges or {}
  local v = bl - 1
  for _, r in ipairs(ranges) do
    if r.first >= bl then
      break
    end
    v = v - (math.min(r.last, bl) - r.first)
  end
  for _, x in ipairs(virt) do
    if x.anchor >= bl - 1 then
      break
    end
    if not M.range_at(ranges, x.anchor + 1) then
      v = v + #x.lines
    end
  end
  return v
end

--- The `topline`/`topfill` that puts screen row `v` at the top of the pane, clamped to
--- the pane: a row inside virtual rows is shown as the line below with `topfill`, and a
--- fold's row as the fold's first line.
---@param virt { anchor: integer, lines: NvimDiff.VirtLine[] }[]
---@param line_count integer Buffer lines.
---@param v integer
---@param ranges? NvimDiff.UnifiedFoldRange[] Closed folds, from `fold_ranges`.
---@return integer topline
---@return integer topfill
function M.view_top(virt, line_count, v, ranges)
  ranges = ranges or {}
  if v <= 0 then
    return 1, 0
  end
  -- Walk one screen row of buffer text at a time: a line, or a whole closed fold, from
  -- `bl` to `last`, on screen row `row`.
  local bl, row, vi, ri = 1, 0, 1, 1
  while true do
    local last = bl
    local r = ranges[ri]
    if r and r.first == bl then
      last = r.last
      ri = ri + 1
    end
    if last >= line_count then
      return bl, 0
    end
    while virt[vi] and virt[vi].anchor < last - 1 do
      vi = vi + 1 -- anchored inside the fold: not drawn
    end
    local below = 0
    if virt[vi] and virt[vi].anchor == last - 1 then
      if last == bl then
        below = #virt[vi].lines
      end
      vi = vi + 1
    end
    -- Rows of this line (or fold) and the virtual rows under it: row .. row + below.
    if v <= row + below then
      if v == row then
        return bl, 0
      end
      return last + 1, row + below - v + 1
    end
    row = row + 1 + below
    bl = last + 1
  end
end

return M
