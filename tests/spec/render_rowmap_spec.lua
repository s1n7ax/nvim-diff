local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local diffgen = require("tests.diffgen")
local line = require("nvim-diff.diff.line")
local rowmap = require("nvim-diff.render.rowmap")

local SIDES = { "old", "new" }

--- Random blocks: after random rows, content on one side or both, of random heights.
---@param diff NvimDiff.Diff
---@param n integer
---@return NvimDiff.Block[]
local function random_blocks(diff, n)
  local blocks = {}
  local function lines(k)
    local out = {}
    for i = 1, k do
      out[i] = { { "thread " .. i, "" } }
    end
    return out
  end
  for i = 1, n do
    local b = { row = math.random(0, diff.rows) }
    local r = math.random()
    if r < 0.4 then
      b.new = lines(math.random(1, 5))
    elseif r < 0.7 then
      b.old = lines(math.random(1, 5))
    else
      b.old, b.new = lines(math.random(1, 4)), lines(math.random(1, 4))
    end
    blocks[i] = b
  end
  return blocks
end

describe("render.rowmap", function()
  it("puts the header at view row 0 and file lines one below their display row", function()
    local d = line.diff({ "a", "b", "c" }, { "a", "X", "b", "c" })
    local map = rowmap.new(d)
    expect.eq(0, map:line_view("old", 1))
    expect.eq(1, map:line_view("old", 2)) -- old 1 "a"
    expect.eq(3, map:line_view("old", 3)) -- old 2 "b", below the filler opposite "X"
    expect.eq(2, map:line_view("new", 3)) -- new 2 "X"
    expect.eq(5, map:height())
    expect.falsy(map.trailer)
  end)

  it("adds a trailer only when the last display row is filler on one side", function()
    expect.falsy(rowmap.new(line.diff({ "a" }, { "a" })).trailer)
    expect.falsy(rowmap.new(line.diff({ "a", "b" }, { "a", "c" })).trailer)
    expect.truthy(rowmap.new(line.diff({ "a" }, { "a", "b" })).trailer)
    expect.truthy(rowmap.new(line.diff({ "a", "b" }, { "a" })).trailer)
    expect.falsy(rowmap.new(line.diff({}, {})).trailer)
  end)

  it("reaches a top inside filler at the end of the file through the trailer", function()
    local d = line.diff({ "a" }, { "a", "b", "c", "d" })
    local map = rowmap.new(d)
    -- View rows: 0 header, 1 "a", 2..4 "b".."d" (filler on old), 5 trailer.
    expect.eq({ 3, 3 }, { map:view_top("old", 2) }) -- the trailer is old buffer line 3
    expect.eq({ 3, 1 }, { map:view_top("old", 4) })
    expect.eq({ 3, 0 }, { map:view_top("new", 2) })
    expect.eq(5, map:max_top())
  end)

  it("round-trips every reachable view row on random diffs with random blocks", function()
    for seed = 1, 60 do
      local old, new = diffgen.files(seed)
      local d = line.diff(old, new)
      local map = rowmap.new(d, random_blocks(d, seed % 7))
      for v = 0, map:height() - 1 do
        local reach = {}
        for _, side in ipairs(SIDES) do
          local tl, tf = map:view_top(side, v)
          reach[side] = tl ~= nil
          if tl then
            expect.eq(v, map:top_view(side, tl, tf), ("seed %d side %s v %d"):format(seed, side, v))
          end
        end
        -- A view row is either reachable from both panes or from neither.
        expect.eq(reach.old, reach.new, ("seed %d v %d"):format(seed, v))
      end
      -- Every view row up to the last line is reachable.
      for v = 0, map:max_top() do
        expect.truthy(map:view_top("old", v), ("seed %d v %d unreachable"):format(seed, v))
      end
    end
  end)

  it("gives the two lines of a display row the same view row", function()
    for seed = 100, 140 do
      local old, new = diffgen.files(seed)
      local d = line.diff(old, new)
      local map = rowmap.new(d, random_blocks(d, 4))
      for row = 1, d.rows do
        local o, n = d:line_at(row)
        if o and n then
          expect.eq(map:line_view("old", o + 1), map:line_view("new", n + 1), ("seed %d row %d"):format(seed, row))
        end
      end
      if map.trailer then
        expect.eq(map:line_view("old", map:trailer_line("old")), map:line_view("new", map:trailer_line("new")))
      end
    end
  end)

  it("counts block rows once per block, the taller side", function()
    local d = line.diff({ "a", "b" }, { "a", "b" })
    local map = rowmap.new(d, {
      { row = 1, old = { { { "x" } } }, new = { { { "y" } }, { { "z" } } } },
      { row = 0, new = { { { "q" } } } },
    })
    expect.eq(1 + 2 + 3, map:height())
    expect.eq(2, map:line_view("old", 2)) -- the row-0 block pushes line 1 down
    expect.eq(5, map:line_view("new", 3)) -- and the row-1 block pushes line 2
    expect.eq(0, map:anchor("old", 0))
    expect.eq(1, map:anchor("new", 1))
  end)

  it("anchors a block inside filler on the line the filler hangs from", function()
    local d = line.diff({ "a", "z" }, { "a", "b", "c", "z" })
    local map = rowmap.new(d)
    -- Display rows: 1 a/a, 2 -/b, 3 -/c, 4 z/z. Old filler hangs from old line 1.
    expect.eq(1, map:anchor("old", 2))
    expect.eq(1, map:anchor("old", 3))
    expect.eq(3, map:anchor("new", 3))
  end)
end)
