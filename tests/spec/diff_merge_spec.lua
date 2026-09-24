local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local diffgen = require("tests.diffgen")
local merge = require("nvim-diff.diff.merge")

local SIDES = merge.SIDES

--- Every structural promise of the model, checked against the three texts.
---@param m NvimDiff.Merge
---@param texts table<NvimDiff.MergeSide, string[]>
---@return string? problem
local function invariants(m, texts)
  for _, side in ipairs(SIDES) do
    -- Each line appears once, in order, and the two lookups agree.
    local last = 0
    local seen = 0
    for d = 1, m.rows do
      local lnum = m:line_at(side, d)
      if lnum then
        seen = seen + 1
        if lnum ~= last + 1 then
          return ("%s: row %d holds line %d after %d"):format(side, d, lnum, last)
        end
        if m.row_of[side][lnum] ~= d then
          return ("%s: row_of(%d) is not %d"):format(side, lnum, d)
        end
        last = lnum
      end
    end
    if seen ~= #texts[side] then
      return ("%s: %d of %d lines placed"):format(side, seen, #texts[side])
    end
    -- Fillers cover exactly the rows with no line.
    local filler_rows = 0
    for _, f in ipairs(m.fillers[side]) do
      filler_rows = filler_rows + f.count
      for d = f.row, f.row + f.count - 1 do
        if m:line_at(side, d) then
          return ("%s: filler over a line at row %d"):format(side, d)
        end
      end
      if f.after ~= (f.row > 1 and (m:line_at(side, f.row - 1) or f.after) or 0) then
        return ("%s: filler at row %d anchored after %d"):format(side, f.row, f.after)
      end
    end
    if filler_rows + seen ~= m.rows then
      return ("%s: %d filler + %d lines ~= %d rows"):format(side, filler_rows, seen, m.rows)
    end
  end
  -- Outside chunks, all three sides show the same text; inside, ranges match the rows.
  for d = 1, m.rows do
    if not m:chunk_at(d) then
      local o, b, th = m:line_at("ours", d), m:line_at("base", d), m:line_at("theirs", d)
      if not (o and b and th) or texts.ours[o] ~= texts.base[b] or texts.theirs[th] ~= texts.base[b] then
        return ("row %d is outside every chunk but differs"):format(d)
      end
    end
  end
  for _, c in ipairs(m.chunks) do
    for _, side in ipairs(SIDES) do
      local r = c[side]
      local n = 0
      for d = c.row, c.row + c.height - 1 do
        local lnum = m:line_at(side, d)
        if lnum then
          n = n + 1
          if lnum ~= r.start + n - 1 then
            return ("chunk at row %d: %s line %d outside its range"):format(c.row, side, lnum)
          end
        end
      end
      if n ~= r.count then
        return ("chunk at row %d: %s has %d lines, range says %d"):format(c.row, side, n, r.count)
      end
    end
  end
  return nil
end

--- Rows as `{ours, base, theirs}` line numbers, `false` for filler.
---@param m NvimDiff.Merge
---@return (integer|false)[][]
local function rows(m)
  local out = {}
  for d = 1, m.rows do
    out[d] = {
      m:line_at("ours", d) or false,
      m:line_at("base", d) or false,
      m:line_at("theirs", d) or false,
    }
  end
  return out
end

describe("diff.merge", function()
  it("lines up a change only ours made, the base mirrored on the theirs side", function()
    local base = { "a", "b one", "c" }
    local ours = { "a", "b two", "new", "c" }
    local m = merge.align(ours, base, base)
    expect.eq(nil, invariants(m, { ours = ours, base = base, theirs = base }))
    expect.eq({ { 1, 1, 1 }, { 2, 2, 2 }, { 3, false, false }, { 4, 3, 3 } }, rows(m))
    expect.eq(1, #m.chunks)
    expect.eq("ours", m.chunks[1].kind)
    expect.eq({ [2] = true, [3] = true }, m.changed.ours)
    expect.eq({ [2] = true }, m.changed.base)
    expect.eq({}, m.changed.theirs)
    expect.eq({ { 2, 5 } }, m.tokens.ours[2])
    expect.eq({ { 2, 5 } }, m.tokens.base[2])
  end)

  it("tells a shared change from a conflict", function()
    local base = { "a", "b", "c" }
    local same = merge.align({ "a", "X", "c" }, base, { "a", "X", "c" })
    expect.eq("both", same.chunks[1].kind)
    local m = merge.align({ "a", "O1", "O2", "c" }, base, { "a", "T", "c" })
    expect.eq("conflict", m.chunks[1].kind)
    expect.eq(1, #m:conflicts())
    expect.eq({ { 1, 1, 1 }, { 2, 2, 2 }, { 3, false, false }, { 4, 3, 3 } }, rows(m))
    expect.eq({ start = 2, count = 2 }, m.chunks[1].ours)
    expect.eq({ start = 2, count = 1 }, m.chunks[1].base)
    -- Touched by both sides: no single side's tokens on the base line.
    expect.eq(nil, m.tokens.base[2])
  end)

  it("groups insertions at one place into one chunk", function()
    local base = { "a", "b" }
    local m = merge.align({ "a", "o", "b" }, base, { "a", "t1", "t2", "b" })
    expect.eq(1, #m.chunks)
    expect.eq("conflict", m.chunks[1].kind)
    expect.eq({ start = 1, count = 0 }, m.chunks[1].base)
    expect.eq({ { 1, 1, 1 }, { 2, false, 2 }, { false, false, 3 }, { 3, 2, 4 } }, rows(m))
  end)

  it("keeps one side's separate changes as separate chunks", function()
    local base = { "1", "2", "3", "4", "5" }
    local m = merge.align({ "X", "2", "3", "4", "5" }, base, { "1", "2", "3", "4", "Y" })
    expect.eq({ "ours", "theirs" }, { m.chunks[1].kind, m.chunks[2].kind })
  end)

  it("handles empty files on any side", function()
    for _, case in ipairs({
      { {}, {}, {} },
      { { "a" }, {}, { "b", "c" } },
      { {}, { "a", "b" }, { "a", "b" } },
      { { "x" }, { "a" }, {} },
    }) do
      local texts = { ours = case[1], base = case[2], theirs = case[3] }
      local m = merge.align(case[1], case[2], case[3])
      expect.eq(nil, invariants(m, texts), vim.inspect(case))
    end
  end)

  it("keeps its promises on random three-way edits", function()
    local kinds = {}
    for seed = 1, 150 do
      local base, ours = diffgen.files(seed)
      -- A second, independent mutation of the same base. Shared changes still happen by
      -- chance (both sides deleting the same run).
      math.randomseed(seed * 7)
      local theirs = {}
      for i, l in ipairs(base) do
        local r = math.random()
        if r < 0.1 then
          theirs[#theirs + 1] = l .. " t"
        elseif r < 0.15 then
          theirs[#theirs + 1] = "tins " .. i
          theirs[#theirs + 1] = l
        elseif r >= 0.2 then
          theirs[#theirs + 1] = l
        end
      end
      local m = merge.align(ours, base, theirs)
      local problem = invariants(m, { ours = ours, base = base, theirs = theirs })
      expect.eq(nil, problem, "seed " .. seed)
      for _, c in ipairs(m.chunks) do
        kinds[c.kind] = true
      end
    end
    expect.eq({ ours = true, theirs = true, both = true, conflict = true }, kinds)
  end)
end)
