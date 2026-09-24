--- The three-way model: ours, base and theirs aligned on shared display rows.
---
--- Built from two line diffs, base → ours and base → theirs. Their hunks are grouped into
--- **chunks** the way diff3 does it: hunks whose base ranges overlap or touch belong to one
--- chunk. A chunk is
---
--- - `ours` / `theirs`: only that side changed the base here. Its rows are that side's hunk
---   rows, so the changed side lines up against the base exactly as in a two-way diff, and
---   the untouched side mirrors the base line for line.
--- - `both`: both sides made the same change.
--- - `conflict`: both sides changed the base here, differently.
---
--- In a `both` or `conflict` chunk the three sides' lines are top-aligned and the shorter
--- sides padded with filler at the bottom: no single alignment fits three texts at once.
--- Between chunks every row holds the same line on all three sides.
---
--- Highlighting follows from the two diffs, never from a third colour: a line of ours or
--- theirs that differs from the base is "added" (green, with the tokens from its own two-way
--- diff), a base line either side replaced or removed is "deleted" (red). So a change only
--- one side made lights up in that side's pane alone — the base pane is what shows who
--- changed what.
---
--- Pure data: no buffers, windows or git.

local line_diff = require("nvim-diff.diff.line")

local M = {}

---@alias NvimDiff.MergeSide "ours"|"base"|"theirs"

M.SIDES = { "ours", "base", "theirs" }

---@alias NvimDiff.ChunkKind "ours"|"theirs"|"both"|"conflict"

---@class NvimDiff.MergeRange
---@field start integer First line; when `count` is 0, the line it sits after.
---@field count integer

---@class NvimDiff.Chunk
---@field kind NvimDiff.ChunkKind
---@field row integer First display row.
---@field height integer Display rows.
---@field ours NvimDiff.MergeRange
---@field base NvimDiff.MergeRange
---@field theirs NvimDiff.MergeRange

---@class NvimDiff.Merge
---@field counts table<NvimDiff.MergeSide, integer> Lines in each file.
---@field rows integer Display rows, the same for all three panes.
---@field chunks NvimDiff.Chunk[]
--- `line_of[side][row]`: the side's line on display row `row`; nil where it is filler.
---@field line_of table<NvimDiff.MergeSide, table<integer, integer>>
--- `row_of[side][lnum]`: display row of the side's line `lnum`.
---@field row_of table<NvimDiff.MergeSide, integer[]>
---@field fillers table<NvimDiff.MergeSide, NvimDiff.Filler[]>
--- Lines to paint as changed: `true` for ours/theirs lines that differ from the base, and
--- for base lines either side replaced or removed.
---@field changed table<NvimDiff.MergeSide, table<integer, true>>
---@field tokens table<NvimDiff.MergeSide, table<integer, NvimDiff.Diff.Span[]>>
---@field diffs { ours: NvimDiff.Diff, theirs: NvimDiff.Diff } base → ours, base → theirs.
local Merge = {}
Merge.__index = Merge

--- The base lines a hunk covers, as a half-open interval `[lo, hi)`. A pure insertion is
--- the empty interval at the line after which it sits, so two insertions at one place, or
--- an insertion right next to a change, touch.
---@param h NvimDiff.Hunk
---@return integer lo
---@return integer hi
local function base_interval(h)
  local lo = h.old_count > 0 and h.old_start or h.old_start + 1
  return lo, lo + h.old_count
end

--- Both sides' hunks in base order, each tagged with its side and base interval.
---@param d_ours NvimDiff.Diff
---@param d_theirs NvimDiff.Diff
---@return { side: "ours"|"theirs", hunk: NvimDiff.Hunk, lo: integer, hi: integer }[]
local function tagged(d_ours, d_theirs)
  local list = {}
  for _, pair in ipairs({ { "ours", d_ours }, { "theirs", d_theirs } }) do
    for _, h in ipairs(pair[2].hunks) do
      local lo, hi = base_interval(h)
      list[#list + 1] = { side = pair[1], hunk = h, lo = lo, hi = hi }
    end
  end
  table.sort(list, function(a, b)
    if a.lo ~= b.lo then
      return a.lo < b.lo
    end
    return a.side < b.side
  end)
  return list
end

---@param lines string[]
---@param range NvimDiff.MergeRange
---@return string[]
local function slice(lines, range)
  local out = {}
  for i = 1, range.count do
    out[i] = lines[range.start + i - 1]
  end
  return out
end

--- Align three files.
---@param ours string[]
---@param base string[]
---@param theirs string[]
---@param opts? NvimDiff.Diff.LineOpts Passed to both line diffs.
---@return NvimDiff.Merge
function M.align(ours, base, theirs, opts)
  local texts = { ours = ours, base = base, theirs = theirs }
  local diffs = { ours = line_diff.diff(base, ours, opts), theirs = line_diff.diff(base, theirs, opts) }
  local self = setmetatable({
    counts = { ours = #ours, base = #base, theirs = #theirs },
    rows = 0,
    chunks = {},
    line_of = { ours = {}, base = {}, theirs = {} },
    row_of = { ours = {}, base = {}, theirs = {} },
    fillers = { ours = {}, base = {}, theirs = {} },
    changed = { ours = {}, base = {}, theirs = {} },
    tokens = { ours = {}, base = {}, theirs = {} },
    diffs = diffs,
  }, Merge)

  local row = 0
  ---@param o integer?
  ---@param b integer?
  ---@param t integer?
  local function emit(o, b, t)
    row = row + 1
    self.line_of.ours[row], self.line_of.base[row], self.line_of.theirs[row] = o, b, t
  end

  -- Next base line to place, and each side's line offset from the base so far.
  local next_base = 1
  local delta = { ours = 0, theirs = 0 }
  local function unchanged_until(stop)
    for b = next_base, stop - 1 do
      emit(b + delta.ours, b, b + delta.theirs)
    end
    next_base = math.max(next_base, stop)
  end

  -- Which side's hunks touched each base line, for the base pane's tokens.
  local touched = {}

  local list = tagged(diffs.ours, diffs.theirs)
  local i = 1
  while i <= #list do
    -- Grow the chunk while the next hunk's interval overlaps or touches it.
    local lo, hi = list[i].lo, list[i].hi
    local j = i
    while j + 1 <= #list and list[j + 1].lo <= hi do
      j = j + 1
      hi = math.max(hi, list[j].hi)
    end
    unchanged_until(lo)

    local grew = { ours = 0, theirs = 0 }
    local sides = {}
    for k = i, j do
      local e = list[k]
      sides[e.side] = e.hunk
      grew[e.side] = grew[e.side] + e.hunk.new_count - e.hunk.old_count
      for _, r in ipairs(e.hunk.rows) do
        if r.old then
          touched[r.old] = touched[r.old] and "both" or e.side
          self.changed.base[r.old] = true
        end
        if r.new then
          self.changed[e.side][r.new] = true
          local spans = diffs[e.side].tokens.new[r.new]
          if spans then
            self.tokens[e.side][r.new] = spans
          end
        end
      end
    end

    local ranges = {
      base = { start = lo, count = hi - lo },
      ours = { start = lo + delta.ours, count = hi - lo + grew.ours },
      theirs = { start = lo + delta.theirs, count = hi - lo + grew.theirs },
    }
    for _, side in ipairs(M.SIDES) do
      if ranges[side].count == 0 then
        ranges[side].start = ranges[side].start - 1
      end
    end

    local kind
    if j == i then
      kind = list[i].side
    elseif not sides.ours or not sides.theirs then
      -- Unreachable: hunks of one diff never touch. Kept safe all the same.
      kind = sides.ours and "ours" or "theirs"
    elseif vim.deep_equal(slice(ours, ranges.ours), slice(theirs, ranges.theirs)) then
      kind = "both"
    else
      kind = "conflict"
    end

    local first_row = row + 1
    if j == i then
      -- One side changed the base here: its hunk rows, the other side mirroring the base.
      local side = list[i].side
      local other = side == "ours" and "theirs" or "ours"
      for _, r in ipairs(list[i].hunk.rows) do
        local mirrored = r.old and r.old + delta[other]
        if side == "ours" then
          emit(r.new, r.old, mirrored)
        else
          emit(mirrored, r.old, r.new)
        end
      end
    else
      local height = math.max(ranges.ours.count, ranges.base.count, ranges.theirs.count)
      local function at(side, n)
        local rg = ranges[side]
        return n <= rg.count and rg.start + n - 1 or nil
      end
      for n = 1, height do
        emit(at("ours", n), at("base", n), at("theirs", n))
      end
    end
    self.chunks[#self.chunks + 1] = {
      kind = kind,
      row = first_row,
      height = row - first_row + 1,
      ours = ranges.ours,
      base = ranges.base,
      theirs = ranges.theirs,
    }

    delta.ours = delta.ours + grew.ours
    delta.theirs = delta.theirs + grew.theirs
    next_base = hi
    i = j + 1
  end
  unchanged_until(#base + 1)
  self.rows = row

  for lnum, by in pairs(touched) do
    if by ~= "both" then
      local spans = diffs[by].tokens.old[lnum]
      if spans then
        self.tokens.base[lnum] = spans
      end
    end
  end

  for _, side in ipairs(M.SIDES) do
    local line_of, row_of, fillers = self.line_of[side], self.row_of[side], self.fillers[side]
    local last = 0
    for d = 1, self.rows do
      local lnum = line_of[d]
      if lnum then
        row_of[lnum] = d
        last = lnum
      else
        local f = fillers[#fillers]
        if f and f.row + f.count == d then
          f.count = f.count + 1
        else
          fillers[#fillers + 1] = { after = last, count = 1, row = d }
        end
      end
    end
    assert(#row_of == #texts[side], "nvim-diff: three-way alignment lost lines")
  end
  return self
end

--- The side's line on display row `d`; nil where it is filler.
---@param side NvimDiff.MergeSide
---@param d integer
---@return integer?
function Merge:line_at(side, d)
  return self.line_of[side][d]
end

--- The chunk covering display row `d`, and its index.
---@param d integer
---@return NvimDiff.Chunk?
---@return integer?
function Merge:chunk_at(d)
  local lo, hi = 1, #self.chunks
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local c = self.chunks[mid]
    if d < c.row then
      hi = mid - 1
    elseif d >= c.row + c.height then
      lo = mid + 1
    else
      return c, mid
    end
  end
  return nil, nil
end

--- Chunks of the kind `conflict`.
---@return NvimDiff.Chunk[]
function Merge:conflicts()
  return vim.tbl_filter(function(c)
    return c.kind == "conflict"
  end, self.chunks)
end

return M
