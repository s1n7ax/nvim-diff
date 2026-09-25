--- The view-row map of a two-pane diff: where every buffer line and virtual line of each
--- pane sits on screen, measured in rows from the top of the pane.
---
--- Both panes have the same view rows, which is what alignment *means*: view row `v` holds
--- the header (`v = 0`), a line of the file, a filler row, a row of an inserted block
--- (a comment thread and the blank padding opposite it), or a separator row standing for a
--- whole fold (`render/fold.lua`), on each side. Every display row inside a fold has the
--- fold's view row, so view rows ascend with display rows but not strictly. The scroll corrector
--- reads one pane's `topline`/`topfill`, turns it into a view row, and asks where the other
--- pane must put its top to show the same view row.
---
--- Buffer layout, both panes: line 1 is the header, line `n + 1` is the file's line `n`,
--- and when `trailer` is set there is one more, empty, line at the end. The trailer exists
--- only when the last display row has filler on one side: `topfill` counts virtual lines
--- *above* a line, so a top that lands inside virtual lines below the last buffer line
--- cannot be expressed, and the other pane would scroll further than this one.
---
--- Pure data: no windows, no buffers.

local fold = require("nvim-diff.render.fold")

local M = {}

---@alias NvimDiff.VirtChunk [string, string|string[]?] Text and its highlight group(s).
---@alias NvimDiff.VirtLine NvimDiff.VirtChunk[] One virtual line: a list of chunks.

--- Extra rows inserted into both panes after one display row: content on one side, the
--- other side padded with blank rows to the same height. Comment threads are built on it.
---@class NvimDiff.Block
---@field row integer Display row it follows; 0 = directly under the header.
---@field old? NvimDiff.VirtLine[]
---@field new? NvimDiff.VirtLine[]

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
---@field trailer boolean Whether both buffers end with the extra trailer line.
---@field blocks NvimDiff.Block[] Sorted by `row`, stable.
---@field folds NvimDiff.Fold[] Sorted, disjoint; no block sits after a row inside one.
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

--- Height of a block, the same on both sides.
---@param block NvimDiff.Block
---@return integer
function M.block_height(block)
  return math.max(block.old and #block.old or 0, block.new and #block.new or 0)
end

---@param diff NvimDiff.Diff
---@param blocks? NvimDiff.Block[] Any order; sorted here (stably, by `row`).
---@param folds? NvimDiff.Fold[] Closed folds, sorted and disjoint.
---@return NvimDiff.RowMap
function M.new(diff, blocks, folds)
  local sorted = {}
  for i, b in ipairs(blocks or {}) do
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
  folds = folds or {}
  local hidden, h = {}, 0
  for i, f in ipairs(folds) do
    assert(f.first >= 1 and f.first <= f.last and f.last <= diff.rows, "nvim-diff: fold out of range")
    assert(i == 1 or folds[i - 1].last < f.first, "nvim-diff: folds overlap or are out of order")
    h = h + f.last - f.first
    hidden[i] = h
  end
  for _, b in ipairs(list) do
    assert(not fold.find(folds, b.row), "nvim-diff: block inside a fold")
  end
  return setmetatable({
    diff = diff,
    trailer = M.needs_trailer(diff),
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

--- View row of display row `d` (`rows + 1` stands for the trailer). Every row of a fold
--- maps to the fold's one row.
---@param d integer
---@return integer
function RowMap:row_view(d)
  return d + self:blocks_before(d) - self:folded_before(d)
end

--- Total view rows in each pane, header and trailer included, blocks after the last row
--- included, each fold counted as one row.
---@return integer
function RowMap:height()
  return 1 + self.diff.rows + (self.trailer and 1 or 0) + (self.cum[#self.cum] or 0) - (self.hidden[#self.hidden] or 0)
end

--- Buffer line of the file's line `lnum` (either side): the header shifts everything by one.
---@param lnum integer
---@return integer
function M.buf_line(lnum)
  return lnum + 1
end

--- The file's line on buffer line `bl` of `side`, or nil on the header and the trailer.
---@param side NvimDiff.Side
---@param bl integer
---@return integer?
function RowMap:file_line(side, bl)
  local lnum = bl - 1
  if lnum >= 1 and lnum <= self.diff[side .. "_count"] then
    return lnum
  end
  return nil
end

--- Buffer line of the trailer on `side`, or nil when there is none.
---@param side NvimDiff.Side
---@return integer?
function RowMap:trailer_line(side)
  return self.trailer and self.diff[side .. "_count"] + 2 or nil
end

--- View row of buffer line `bl` on `side`.
---@param side NvimDiff.Side
---@param bl integer
---@return integer?
function RowMap:line_view(side, bl)
  if bl == 1 then
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
--- buffer line (which neither pane can scroll into, so both stop at the same place).
---@param side NvimDiff.Side
---@param v integer
---@return integer? topline
---@return integer? topfill
function RowMap:view_top(side, v)
  if v < 0 then
    return nil, nil
  end
  if v == 0 then
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
    bl = side_line(self.diff, side, d) + 1
  elseif self.trailer then
    bl = self:trailer_line(side)
  else
    return nil, nil
  end
  return bl, self:row_view(d) - v
end

--- The last view row that can be at the top of a pane: the last buffer line's.
---@return integer
function RowMap:max_top()
  if self.trailer then
    return self:row_view(self.diff.rows + 1)
  end
  return self.diff.rows > 0 and self:row_view(self.diff.rows) or 0
end

--- Anchor of the virtual rows that follow display row `d` on `side`: the 0-based buffer
--- row of the last line of `side` at or above `d` (0 is the header).
---@param side NvimDiff.Side
---@param d integer
---@return integer
function RowMap:anchor(side, d)
  if d == 0 then
    return 0
  end
  local lnum = side_line(self.diff, side, d)
  if lnum then
    return lnum
  end
  local f = self:filler_at(side, d)
  return f.after
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
