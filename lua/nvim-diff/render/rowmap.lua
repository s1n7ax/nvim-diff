--- The view-row map of a two-pane diff: where every buffer line and virtual line of each
--- pane sits on screen, measured in rows from the top of the pane.
---
--- Both panes have the same view rows, which is what alignment *means*: view row `v` holds
--- the header (`v = 0`, when there is one), a line of the file, a filler row, a row of an
--- inserted block (a comment thread and the blank padding opposite it), or a separator row
--- standing for a whole fold (`render/fold.lua`), on each side. Every display row inside a
--- fold has the fold's view row, so view rows ascend with display rows but not strictly. The
--- scroll corrector reads one pane's `topline`/`topfill`, turns it into a view row, and asks
--- where the other pane must put its top to show the same view row.
---
--- Buffer layout, both panes: line 1 is the header, line `n + 1` is the file's line `n`,
--- and when `trailer` is set for the side there is one more, empty, line at the end. The
--- trailer exists only when the last display row has filler on one side: `topfill` counts
--- virtual lines *above* a line, so a top that lands inside virtual lines below the last
--- buffer line cannot be expressed, and the other pane would scroll further than this one.
---
--- A pair that shows its headers as winbars (a PR review, whose head pane is the real file,
--- `scene/filebuf.lua`) has no header line: line `n` is the file's line `n`, view row 0 is the first
--- display row, and what comes before the first line — leading filler, a block after row 0
--- — hangs *above* buffer line 1 (anchor -1), shown only with `topfill`. The header is
--- pair-wide, since the panes share view row 0. A side can also be denied the trailer (a
--- real file cannot grow a line): it then stops at its last line, `max_top` differs per
--- side, and the corrector keeps both panes at or above the smaller one.
---
--- Foreign virtual lines — ones another plugin draws in a pane, such as a diagnostic's
--- `virtual_lines` or a code lens in the real file's pane — take rows only on their side.
--- They become blocks too (`ext`): after the display row just before the next thing their
--- side shows, after every other block there, with blank rows on the other side. The
--- painter hangs its own rows first at a place (`right_gravity = false` sorts a mark before
--- the default right-gravity ones at the same spot, measured), so another plugin's rows
--- there follow nvim-diff's, and its padding lines up. A foreign line on a line inside a
--- closed fold is not drawn (Neovim skips every virtual line anchored in one), so it takes
--- no rows.
---
--- Pure data: no windows, no buffers.

local fold = require("nvim-diff.render.fold")

local M = {}

---@alias NvimDiff.VirtChunk [string, string|string[]?] Text and its highlight group(s).
---@alias NvimDiff.VirtLine NvimDiff.VirtChunk[] One virtual line: a list of chunks.

--- Extra rows inserted into both panes after one display row: content on one side, the
--- other side padded with blank rows to the same height. Comment threads are built on it.
---@class NvimDiff.Block
---@field row integer Display row it follows; 0 = above the first row (under the header).
---@field old? NvimDiff.VirtLine[]
---@field new? NvimDiff.VirtLine[]
--- Rows of a side that something else draws (foreign virtual lines), after the side's own:
--- they count toward the height, and the painter leaves them out.
---@field ext? { old?: integer, new?: integer }

--- Virtual lines another plugin draws in one pane, by the file line they hang off:
--- `below[l]` rows under line `l` (0: under the header line), `above[l]` rows over it.
---@class NvimDiff.ForeignLines
---@field below table<integer, integer>
---@field above table<integer, integer>

--- How the pane buffers are laid out around the file's lines.
---@class NvimDiff.RowMapLayout
--- Buffer line 1 of both panes is the header. Default true.
---@field header? boolean
--- Sides allowed to end with the trailer line, when the diff needs one. Default: both.
---@field trailer? { old?: boolean, new?: boolean }

--- The line of `side` on display row `d`, nil where that side is filler.
---@param diff NvimDiff.Diff
---@param side NvimDiff.Side
---@param d integer
---@return integer?
local function side_line(diff, side, d)
  local old, new = diff:line_at(d)
  if side == "old" then
    return old
  end
  return new
end

---@class NvimDiff.RowMap
---@field diff NvimDiff.Diff
---@field header boolean Whether both buffers start with the header line.
---@field trailer { old: boolean, new: boolean } Which buffers end with the extra trailer line.
---@field blocks NvimDiff.Block[] Sorted by `row`, stable.
--- Sorted, disjoint; no block sits after a row inside one, but foreign rows may follow its
--- last row.
---@field folds NvimDiff.Fold[]
---@field private hidden integer[] `hidden[i]`: rows `folds[1..i]` take out of the view.
---@field private block_rows integer[] `block_rows[i]`: rows of `blocks[i]`, i.e. the taller side.
---@field private cum integer[] `cum[i]`: rows of `blocks[1..i]`.
local RowMap = {}
RowMap.__index = RowMap

--- Whether a diff needs the trailer line: its last display row is filler on one side.
---@param diff NvimDiff.Diff
---@return boolean
function M.needs_trailer(diff)
  if diff.rows == 0 then
    return false
  end
  local old, new = diff:line_at(diff.rows)
  return old == nil or new == nil
end

--- Which sides end with the trailer line: those allowed to, when the diff needs one, and,
--- without a header, a side with no lines at all — its buffer still has a line, and its
--- filler needs one to hang from.
---@param diff NvimDiff.Diff
---@param header boolean
---@param allow { old?: boolean, new?: boolean }
---@return { old: boolean, new: boolean }
local function trailers(diff, header, allow)
  local needs = M.needs_trailer(diff)
  local out = {}
  for _, side in ipairs({ "old", "new" }) do
    out[side] = (needs and allow[side] ~= false) or (not header and diff[side .. "_count"] == 0)
  end
  return out
end

--- Rows of a block `side` draws itself: its content, then blank rows up to the height; not
--- the rows something else draws there (`ext`).
---@param block NvimDiff.Block
---@param side NvimDiff.Side
---@return integer
function M.own_rows(block, side)
  return M.block_height(block) - (block.ext and block.ext[side] or 0)
end

--- Height of a block, the same on both sides.
---@param block NvimDiff.Block
---@return integer
function M.block_height(block)
  local ext = block.ext or {}
  return math.max((block.old and #block.old or 0) + (ext.old or 0), (block.new and #block.new or 0) + (ext.new or 0))
end

--- The blocks foreign virtual lines take, given the closed folds.
---
--- Rows between a side's lines `l` and `l + 1` (under `l`, over `l + 1`, each only when its
--- line is not folded) come just before the next thing that side shows: line `l + 1`'s row,
--- or the first row of the fold holding it; after the last line, the end. The block follows
--- the display row before that, so it can sit after the last row of a fold (a code lens
--- over the line after a context fold), never inside one.
---@param diff NvimDiff.Diff
---@param folds NvimDiff.Fold[]
---@param foreign { old?: NvimDiff.ForeignLines, new?: NvimDiff.ForeignLines }
---@return NvimDiff.Block[] # Sorted by row.
local function foreign_blocks(diff, folds, foreign)
  local at = {}
  for _, side in ipairs({ "old", "new" }) do
    local f = foreign[side]
    local count = diff[side .. "_count"]
    local function folded(l)
      return l >= 1 and fold.find(folds, diff:row_of(side, l)) ~= nil
    end
    ---@param gap integer Rows between lines `gap` and `gap + 1`.
    ---@param n integer
    local function add(gap, n)
      local d = gap < count and diff:row_of(side, gap + 1) or diff.rows + 1
      local fi = d <= diff.rows and fold.find(folds, d)
      if fi then
        d = folds[fi].first
      end
      local b = at[d - 1]
      if not b then
        b = { row = d - 1, ext = { old = 0, new = 0 } }
        at[d - 1] = b
      end
      b.ext[side] = b.ext[side] + n
    end
    if f then
      for l, n in pairs(f.below) do
        if n > 0 and l >= 0 and l <= count and not folded(l) then
          add(l, n)
        end
      end
      for l, n in pairs(f.above) do
        if n > 0 and l >= 1 and l <= count and not folded(l) then
          add(l - 1, n)
        end
      end
    end
  end
  local list = vim.tbl_values(at)
  table.sort(list, function(a, b)
    return a.row < b.row
  end)
  return list
end

---@param diff NvimDiff.Diff
---@param blocks? NvimDiff.Block[] Any order; sorted here (stably, by `row`).
---@param folds? NvimDiff.Fold[] Closed folds, sorted and disjoint.
---@param layout? NvimDiff.RowMapLayout
--- Virtual lines other plugins draw in each pane; they follow every block at their row.
---@param foreign? { old?: NvimDiff.ForeignLines, new?: NvimDiff.ForeignLines }
---@return NvimDiff.RowMap
function M.new(diff, blocks, folds, layout, foreign)
  folds = folds or {}
  local all = blocks or {}
  if foreign and (foreign.old or foreign.new) then
    all = vim.list_extend(vim.list_extend({}, all), foreign_blocks(diff, folds, foreign))
  end
  local sorted = {}
  for i, b in ipairs(all) do
    assert(b.row >= 0 and b.row <= diff.rows, "nvim-diff: block row out of range")
    sorted[i] = { b, i }
  end
  table.sort(sorted, function(x, y)
    if x[1].row ~= y[1].row then
      return x[1].row < y[1].row
    end
    return x[2] < y[2]
  end)
  local list, heights, cum = {}, {}, {}
  local total = 0
  for i, pair in ipairs(sorted) do
    list[i] = pair[1]
    heights[i] = M.block_height(pair[1])
    total = total + heights[i]
    cum[i] = total
  end
  local hidden, h = {}, 0
  for i, f in ipairs(folds) do
    assert(f.first >= 1 and f.first <= f.last and f.last <= diff.rows, "nvim-diff: fold out of range")
    assert(i == 1 or folds[i - 1].last < f.first, "nvim-diff: folds overlap or are out of order")
    h = h + f.last - f.first
    hidden[i] = h
  end
  for _, b in ipairs(list) do
    -- Foreign rows may follow a fold's last row: they hang past it (`block_anchor`).
    local fi = fold.find(folds, b.row)
    assert(not fi or (b.ext and folds[fi].last == b.row), "nvim-diff: block inside a fold")
  end
  local header = not layout or layout.header ~= false
  return setmetatable({
    diff = diff,
    header = header,
    trailer = trailers(diff, header, layout and layout.trailer or {}),
    blocks = list,
    block_rows = heights,
    cum = cum,
    folds = folds,
    hidden = hidden,
  }, RowMap)
end

--- Block rows inserted strictly before display row `d` (blocks after rows `< d`).
---@param d integer
---@return integer
function RowMap:blocks_before(d)
  local lo, hi, found = 1, #self.blocks, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self.blocks[mid].row < d then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found > 0 and self.cum[found] or 0
end

--- Display rows folds take out of the view before display row `d`: all but one row of
--- each fold above it, and the rows of a fold holding `d` above `d`.
---@param d integer
---@return integer
function RowMap:folded_before(d)
  local folds = self.folds
  local lo, hi, found = 1, #folds, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if folds[mid].first <= d then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if found == 0 then
    return 0
  end
  local f = folds[found]
  if d <= f.last then
    return (self.hidden[found - 1] or 0) + d - f.first
  end
  return self.hidden[found]
end

--- Buffer lines before the file's first line: 1 with the header, else 0.
---@return integer
function RowMap:head()
  return self.header and 1 or 0
end

--- View row of display row `d` (`rows + 1` stands for the trailer). Every row of a fold
--- maps to the fold's one row.
---@param d integer
---@return integer
function RowMap:row_view(d)
  return d - 1 + self:head() + self:blocks_before(d) - self:folded_before(d)
end

--- Total view rows in `side`'s pane, header and trailer included, blocks after the last
--- row included, each fold counted as one row.
---@param side NvimDiff.Side
---@return integer
function RowMap:height(side)
  return self:head()
    + self.diff.rows
    + (self.trailer[side] and 1 or 0)
    + (self.cum[#self.cum] or 0)
    - (self.hidden[#self.hidden] or 0)
end

--- Buffer line of the file's line `lnum` (either side): the header, when there is one,
--- shifts everything by one.
---@param lnum integer
---@return integer
function RowMap:buf_line(lnum)
  return lnum + self:head()
end

--- The file's line on buffer line `bl` of `side`, or nil on the header and the trailer.
---@param side NvimDiff.Side
---@param bl integer
---@return integer?
function RowMap:file_line(side, bl)
  local lnum = bl - self:head()
  if lnum >= 1 and lnum <= self.diff[side .. "_count"] then
    return lnum
  end
  return nil
end

--- Buffer line of the trailer on `side`, or nil when there is none.
---@param side NvimDiff.Side
---@return integer?
function RowMap:trailer_line(side)
  return self.trailer[side] and self:buf_line(self.diff[side .. "_count"]) + 1 or nil
end

--- View row of buffer line `bl` on `side`.
---@param side NvimDiff.Side
---@param bl integer
---@return integer?
function RowMap:line_view(side, bl)
  if self.header and bl == 1 then
    return 0
  end
  local lnum = self:file_line(side, bl)
  if lnum then
    return self:row_view(self.diff:row_of(side, lnum))
  end
  if bl == self:trailer_line(side) then
    return self:row_view(self.diff.rows + 1)
  end
  return nil
end

--- View row at the top of a pane showing `side` whose view is `topline`/`topfill`.
---@param side NvimDiff.Side
---@param topline integer
---@param topfill integer
---@return integer?
function RowMap:top_view(side, topline, topfill)
  local v = self:line_view(side, topline)
  return v and v - (topfill or 0)
end

--- The first display row at or after `d` holding a line of `side`; `rows + 1` when there
--- is none (only filler follows).
---@param side NvimDiff.Side
---@param d integer
---@return integer
function RowMap:next_real_row(side, d)
  local diff = self.diff
  if d > diff.rows then
    return diff.rows + 1
  end
  if side_line(diff, side, d) then
    return d
  end
  -- `d` is filler on this side: jump to the end of its block.
  local f = self:filler_at(side, d)
  return f.row + f.count
end

--- Where a pane showing `side` must put its top so view row `v` is its first screen row.
--- Nil when no top can show it: `v` is out of range, or inside virtual rows after the last
--- buffer line (which the pane cannot scroll into).
---@param side NvimDiff.Side
---@param v integer
---@return integer? topline
---@return integer? topfill
function RowMap:view_top(side, v)
  if v < 0 then
    return nil, nil
  end
  if self.header and v == 0 then
    return 1, 0
  end
  local rows = self.diff.rows
  -- Smallest display row whose view row is >= v; view rows ascend with d (strictly
  -- outside folds), so inside a fold this lands on its first row.
  local lo, hi, d = 1, rows + 1, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if self:row_view(mid) >= v then
      d = mid
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  if not d then
    return nil, nil
  end
  d = self:next_real_row(side, d)
  local bl
  if d <= rows then
    bl = self:buf_line(side_line(self.diff, side, d))
  elseif self.trailer[side] then
    bl = self:trailer_line(side)
  else
    return nil, nil
  end
  return bl, self:row_view(d) - v
end

--- The last view row that can be at the top of `side`'s pane: its last buffer line's.
---@param side NvimDiff.Side
---@return integer
function RowMap:max_top(side)
  if self.trailer[side] then
    return self:row_view(self.diff.rows + 1)
  end
  local count = self.diff[side .. "_count"]
  if count == 0 then
    return 0 -- the header is the only line
  end
  return self:row_view(self.diff:row_of(side, count))
end

--- Anchor of the virtual rows that follow display row `d` on `side`: the 0-based buffer
--- row of the last line of `side` at or above `d` (0 is the header). -1 when there is none,
--- not even a header: the rows then hang above buffer row 0.
---@param side NvimDiff.Side
---@param d integer
---@return integer
function RowMap:anchor(side, d)
  if d == 0 then
    return self:head() - 1
  end
  local lnum = side_line(self.diff, side, d)
  if not lnum then
    lnum = self:filler_at(side, d).after
  end
  return self:buf_line(lnum) - 1
end

--- Where the rows of a block after display row `d` hang on `side`: under `anchor`, or —
--- after the last row of a closed fold, whose lines draw no virtual lines — over the
--- side's line on the next row, when it has one there. Only foreign rows sit there.
---@param side NvimDiff.Side
---@param d integer
---@return integer row 0-based buffer row.
---@return boolean above Over the row, not under it.
function RowMap:block_anchor(side, d)
  if d >= 1 and d < self.diff.rows and fold.find(self.folds, d) then
    local lnum = side_line(self.diff, side, d + 1)
    if lnum then
      return self:buf_line(lnum) - 1, true
    end
  end
  local a = self:anchor(side, d)
  if a < 0 then
    return 0, true
  end
  return a, false
end

--- The filler block of `side` covering display row `d`.
---@param side NvimDiff.Side
---@param d integer
---@return NvimDiff.Filler
function RowMap:filler_at(side, d)
  local list = self.diff.fillers[side]
  local lo, hi = 1, #list
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local f = list[mid]
    if d < f.row then
      hi = mid - 1
    elseif d >= f.row + f.count then
      lo = mid + 1
    else
      return f
    end
  end
  error("nvim-diff: display row is not filler on this side")
end

return M
