--- The hunk data model: what a diff of two files *is*, independent of how it was computed
--- or how it will be drawn.
---
--- Every later step reads this shape. The side-by-side and unified renderers read `hunks`,
--- `fillers` and `tokens`; context folding reads `unchanged`; the scroll corrector and
--- cursor correspondence read the display-row lookups; the comment keymap reads
--- `commentable_ranges`. The line engine (`diff/line.lua`) builds it today and the
--- structural engine will build it later, by replacing `tokens` (and setting
--- `formatting_only` on hunks) — never by changing the shape.
---
--- Vocabulary:
---
--- - **side** is `"old"` or `"new"`. The GitHub layer maps `LEFT`/`RIGHT` onto these; the
---   rev tuple's `a`/`b` are old/new too.
--- - **line numbers** are 1-based lines of that side's file. The renderer's header line at
---   buffer line 1 is the renderer's business, not the model's.
--- - **display rows** are 1-based rows of the aligned, unfolded two-pane view: every row
---   holds an old line, a new line, or one of each. A row missing a line on one side is
---   filler on that side. Both panes have exactly `diff.rows` display rows.
---
--- Pure data plus lookups. No buffers, windows, extmarks or git.

local M = {}

---@alias NvimDiff.Side "old"|"new"

--- `changed`: a line on each side, paired — red on the left, green on the right, with
--- brighter tokens inside. `added`: a new line with filler opposite. `deleted`: an old line
--- with filler opposite.
---@alias NvimDiff.RowKind "changed"|"added"|"deleted"

---@class NvimDiff.Row
---@field kind NvimDiff.RowKind
---@field old? integer Old line on this row; nil for `added` (filler on the old side).
---@field new? integer New line on this row; nil for `deleted` (filler on the new side).

---@class NvimDiff.Hunk
---@field index integer Position in `diff.hunks`.
--- `start`/`count` follow the unified-diff convention: when `count` is 0 the side has no
--- lines in this hunk and `start` is the line *after which* the other side's lines sit
--- (0 = before line 1).
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field row integer Display row of `rows[1]`.
---@field rows NvimDiff.Row[] Display order. Old lines ascend, new lines ascend.
--- True when the hunk changes layout but not meaning (a pure reformat), which folding
--- collapses to one separator row. The line engine always says false; only the structural
--- engine can know.
---@field formatting_only boolean

--- A maximal run of identical lines between hunks (or before the first / after the last).
--- Folding collapses these, keeping whatever context it chooses at each end.
---@class NvimDiff.Run
---@field old_start integer
---@field new_start integer
---@field count integer Same on both sides, by definition.
---@field row integer Display row of the first line.

--- A contiguous block of filler rows on one side: one merged `virt_lines` extmark.
---@class NvimDiff.Filler
---@field after integer The side's line the block sits below; 0 = above line 1.
---@field count integer
---@field row integer Display row of the first filler row.

--- Changed byte ranges, per side, keyed by line number. Every line on a `changed` row has an
--- entry (the list may be empty: text purely inserted into a line leaves nothing to light up
--- on the old side). From the line engine, `added` and `deleted` lines never have one — a
--- wholly new line is uniform colour; the structural engine gives one to an added or deleted
--- line only when some, not all, of its syntax is new. Spans are 0-based, end-exclusive
--- byte columns, ascending.
---@class NvimDiff.Tokens
---@field old table<integer, NvimDiff.Diff.Span[]>
---@field new table<integer, NvimDiff.Diff.Span[]>

---@class NvimDiff.Diff
---@field old_count integer Lines in the old file.
---@field new_count integer Lines in the new file.
---@field rows integer Display rows in the aligned view (same for both panes).
---@field hunks NvimDiff.Hunk[]
---@field unchanged NvimDiff.Run[]
---@field fillers { old: NvimDiff.Filler[], new: NvimDiff.Filler[] }
---@field tokens NvimDiff.Tokens
---@field token_source "line"|"structural" Which engine produced `tokens`.
--- The xdiff algorithm the hunks actually came from, set by the line engine. It can differ
--- from the one asked for: histogram falls back to myers on very scattered diffs.
---@field algorithm? string
local Diff = {}
Diff.__index = Diff

local OTHER = { old = "new", new = "old" }

---@param side any
local function check_side(side)
  if side ~= "old" and side ~= "new" then
    error(("nvim-diff: side must be 'old' or 'new', got %s"):format(vim.inspect(side)), 3)
  end
end

--- First line a hunk occupies on `side`, whether or not it has any there.
---@param h NvimDiff.Hunk
---@param side NvimDiff.Side
---@return integer
local function first_line(h, side)
  local start, count = h[side .. "_start"], h[side .. "_count"]
  return count > 0 and start or start + 1
end

--- Build the model from hunks that carry `old_start`/`old_count`/`new_start`/`new_count`
--- and `rows`, in file order. Fills in `index`, `row` and `formatting_only`, and derives
--- `unchanged`, `fillers` and the total row count. `tokens` starts empty.
---@param old_count integer
---@param new_count integer
---@param hunks NvimDiff.Hunk[]
---@return NvimDiff.Diff
function M.new(old_count, new_count, hunks)
  local unchanged = {}
  local fillers = { old = {}, new = {} }
  local row = 1
  local next_old, next_new = 1, 1

  ---@param side NvimDiff.Side
  ---@param after integer
  ---@param at integer
  ---@param extend boolean
  local function fill(side, after, at, extend)
    local list = fillers[side]
    if extend then
      list[#list].count = list[#list].count + 1
    else
      list[#list + 1] = { after = after, count = 1, row = at }
    end
  end

  for i, h in ipairs(hunks) do
    local old_first, new_first = first_line(h, "old"), first_line(h, "new")
    local gap = old_first - next_old
    assert(gap >= 0 and gap == new_first - next_new, "nvim-diff: hunks overlap or are out of order")
    if gap > 0 then
      unchanged[#unchanged + 1] = { old_start = next_old, new_start = next_new, count = gap, row = row }
      row = row + gap
    end

    h.index = i
    h.row = row
    if h.formatting_only == nil then
      h.formatting_only = false
    end

    local last_old, last_new = old_first - 1, new_first - 1
    local prev = nil ---@type NvimDiff.Row?
    for _, r in ipairs(h.rows) do
      if r.old then
        last_old = r.old
      else
        fill("old", last_old, row, prev ~= nil and prev.old == nil)
      end
      if r.new then
        last_new = r.new
      else
        fill("new", last_new, row, prev ~= nil and prev.new == nil)
      end
      prev = r
      row = row + 1
    end

    next_old = old_first + h.old_count
    next_new = new_first + h.new_count
  end

  local tail = old_count - next_old + 1
  assert(tail >= 0 and tail == new_count - next_new + 1, "nvim-diff: hunks do not cover the files")
  if tail > 0 then
    unchanged[#unchanged + 1] = { old_start = next_old, new_start = next_new, count = tail, row = row }
    row = row + tail
  end

  return setmetatable({
    old_count = old_count,
    new_count = new_count,
    rows = row - 1,
    hunks = hunks,
    unchanged = unchanged,
    fillers = fillers,
    tokens = { old = {}, new = {} },
    token_source = "line",
  }, Diff)
end

-- Lookups ---------------------------------------------------------------------------------

--- Per-hunk index from a side's line to its display row. Built on first use: most hunks are
--- never asked, and a 50,000-line added file is one hunk whose rows would otherwise be
--- scanned on every scroll. Weak keys, so the model stays plain data.
---@type table<NvimDiff.Hunk, { old: integer[], new: integer[] }>
local row_index = setmetatable({}, { __mode = "k" })

---@param h NvimDiff.Hunk
---@param side NvimDiff.Side
---@return integer[] rows Display row of the side's i-th line in the hunk.
local function rows_of(h, side)
  local idx = row_index[h]
  if not idx then
    idx = { old = {}, new = {} }
    for i, r in ipairs(h.rows) do
      if r.old then
        idx.old[#idx.old + 1] = h.row + i - 1
      end
      if r.new then
        idx.new[#idx.new + 1] = h.row + i - 1
      end
    end
    row_index[h] = idx
  end
  return idx[side]
end

--- The last element of a sorted list whose `key(elem)` is <= `value`.
---@generic T
---@param list T[]
---@param value integer
---@param key fun(elem: T): integer
---@return T?
local function floor_search(list, value, key)
  local lo, hi, found = 1, #list, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if key(list[mid]) <= value then
      found = list[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

--- The hunk whose lines on `side` include `lnum`, if any.
---@param side NvimDiff.Side
---@param lnum integer
---@return NvimDiff.Hunk?
function Diff:hunk_at(side, lnum)
  check_side(side)
  local count_key = side .. "_count"
  local h = floor_search(self.hunks, lnum, function(x)
    return first_line(x, side)
  end)
  -- A hunk with no lines on this side sorts at the unchanged line just after its insertion
  -- point, so landing on one means `lnum` is at or past that unchanged line: in no hunk.
  if h and lnum < first_line(h, side) + h[count_key] then
    return h
  end
  return nil
end

--- How `lnum` on `side` differs: `"changed"`, `"added"` (new side only), `"deleted"` (old
--- side only), or nil for an unchanged line.
---@param side NvimDiff.Side
---@param lnum integer
---@return NvimDiff.RowKind?
function Diff:kind(side, lnum)
  local h = self:hunk_at(side, lnum)
  if not h then
    return nil
  end
  local row = rows_of(h, side)[lnum - first_line(h, side) + 1]
  return h.rows[row - h.row + 1].kind
end

--- Display row of `lnum` on `side`, or nil when the side has no such line.
---@param side NvimDiff.Side
---@param lnum integer
---@return integer?
function Diff:row_of(side, lnum)
  check_side(side)
  if lnum < 1 or lnum > self[side .. "_count"] then
    return nil
  end
  local h = self:hunk_at(side, lnum)
  if h then
    return rows_of(h, side)[lnum - first_line(h, side) + 1]
  end
  local run = floor_search(self.unchanged, lnum, function(x)
    return x[side .. "_start"]
  end)
  assert(run, "nvim-diff: line is in neither a hunk nor an unchanged run")
  return run.row + lnum - run[side .. "_start"]
end

--- What sits on display row `row`: the old line and the new line, either of which is nil
--- where that side is filler. Both nil when `row` is out of range.
---@param row integer
---@return integer? old
---@return integer? new
function Diff:line_at(row)
  if row < 1 or row > self.rows then
    return nil, nil
  end
  local h = floor_search(self.hunks, row, function(x)
    return x.row
  end)
  if h and row < h.row + #h.rows then
    local r = h.rows[row - h.row + 1]
    return r.old, r.new
  end
  local run = floor_search(self.unchanged, row, function(x)
    return x.row
  end)
  assert(run, "nvim-diff: row is in neither a hunk nor an unchanged run")
  local offset = row - run.row
  return run.old_start + offset, run.new_start + offset
end

--- The line on the other side of `lnum`'s display row — where the cursor goes when it
--- crosses panes. Where the other side is filler, this is the nearest other-side line
--- above (0 when there is none), and `exact` is false.
---@param side NvimDiff.Side
---@param lnum integer
---@return integer? lnum nil only when `lnum` does not exist on `side`.
---@return boolean exact
function Diff:counterpart(side, lnum)
  local row = self:row_of(side, lnum)
  if not row then
    return nil, false
  end
  local other = OTHER[side]
  local h = self:hunk_at(side, lnum)
  if not h then
    local old, new = self:line_at(row)
    return (other == "old" and old or new), true
  end
  local at = row - h.row + 1
  for i = at, 1, -1 do
    local found = h.rows[i][other]
    if found then
      return found, i == at
    end
  end
  return first_line(h, other) - 1, false
end

--- Line ranges on `side` that a GitHub review comment may anchor to: every line of the
--- unified diff that side appears in — each hunk's own lines plus `context` lines around
--- it, with hunks whose context touches merged, exactly as `git diff -U<context>` groups
--- them. Derived from our local line hunks only; structural diff never changes it.
---@param side NvimDiff.Side
---@param context? integer Defaults to 3, git's and GitHub's default.
---@return [integer, integer][] ranges Inclusive `{ first, last }`, ascending, disjoint.
function Diff:commentable_ranges(side, context)
  check_side(side)
  context = context or 3
  local total = self[side .. "_count"]
  local count_key = side .. "_count"
  local ranges = {}
  for _, h in ipairs(self.hunks) do
    local first = first_line(h, side)
    local lo = math.max(1, first - context)
    local hi = math.min(total, first + h[count_key] - 1 + context)
    if lo <= hi then
      local last = ranges[#ranges]
      if last and lo <= last[2] + 1 then
        last[2] = math.max(last[2], hi)
      else
        ranges[#ranges + 1] = { lo, hi }
      end
    end
  end
  return ranges
end

--- Whether `lnum` on `side` falls inside `commentable_ranges(side, context)`.
---@param side NvimDiff.Side
---@param lnum integer
---@param context? integer
---@return boolean
function Diff:is_commentable(side, lnum, context)
  for _, r in ipairs(self:commentable_ranges(side, context)) do
    if lnum < r[1] then
      return false
    end
    if lnum <= r[2] then
      return true
    end
  end
  return false
end

--- Module-level form of `diff:commentable_ranges(side)`, so the comment keymap can depend
--- on this module alone.
---@param diff NvimDiff.Diff
---@param side NvimDiff.Side
---@param context? integer
---@return [integer, integer][]
function M.commentable_ranges(diff, side, context)
  return Diff.commentable_ranges(diff, side, context)
end

return M
