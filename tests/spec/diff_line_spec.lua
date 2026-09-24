local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local line = require("nvim-diff.diff.line")

--- A hunk's rows as compact strings: `"3=4"` changed, `"3-"` deleted, `"+4"` added.
---@param h NvimDiff.Hunk
---@return string[]
local function shape(h)
  local out = {}
  for i, r in ipairs(h.rows) do
    if r.kind == "changed" then
      out[i] = r.old .. "=" .. r.new
    elseif r.kind == "deleted" then
      out[i] = r.old .. "-"
    else
      out[i] = "+" .. r.new
    end
  end
  return out
end

---@param h NvimDiff.Hunk
---@return integer[]
local function range(h)
  return { h.old_start, h.old_count, h.new_start, h.new_count }
end

describe("diff.line", function()
  it("finds no hunks in identical files", function()
    local d = line.diff({ "a", "b" }, { "a", "b" })
    expect.eq({}, d.hunks)
    expect.eq({ { old_start = 1, new_start = 1, count = 2, row = 1 } }, d.unchanged)
    expect.eq(2, d.rows)
  end)

  it("diffs two empty files to nothing", function()
    local d = line.diff({}, {})
    expect.eq({}, d.hunks)
    expect.eq({}, d.unchanged)
    expect.eq(0, d.rows)
  end)

  it("treats an empty side as zero lines, not one empty line", function()
    local d = line.diff({}, { "a", "b" })
    expect.eq(1, #d.hunks)
    expect.eq({ 0, 0, 1, 2 }, range(d.hunks[1]))
    expect.eq({ "+1", "+2" }, shape(d.hunks[1]))

    d = line.diff({ "a" }, {})
    expect.eq({ 1, 1, 0, 0 }, range(d.hunks[1]))
    expect.eq({ "1-" }, shape(d.hunks[1]))
  end)

  it("reports an insertion with the unified-diff 'after line' convention", function()
    local d = line.diff({ "a", "b", "c" }, { "a", "x", "b", "c" })
    expect.eq({ 1, 0, 2, 1 }, range(d.hunks[1]))
    expect.eq({ "+2" }, shape(d.hunks[1]))
  end)

  it("reports a deletion the same way on the new side", function()
    local d = line.diff({ "a", "b", "c" }, { "a", "c" })
    expect.eq({ 2, 1, 1, 0 }, range(d.hunks[1]))
    expect.eq({ "2-" }, shape(d.hunks[1]))
  end)

  it("pairs a one-for-one replacement as a changed line with tokens", function()
    local d = line.diff({ "a", "port = 8080", "c" }, { "a", "port = 9090", "c" })
    expect.eq({ "2=2" }, shape(d.hunks[1]))
    expect.eq({ [2] = { { 7, 11 } } }, d.tokens.old)
    expect.eq({ [2] = { { 7, 11 } } }, d.tokens.new)
    expect.eq("line", d.token_source)
  end)

  it("gives added and deleted lines no tokens", function()
    local d = line.diff({ "a", "gone", "c" }, { "a", "c", "new" })
    expect.eq({}, d.tokens.old)
    expect.eq({}, d.tokens.new)
  end)

  it("pairs similar lines inside a hunk rather than by position", function()
    local d = line.diff({ "k", "x = 1", "y", "z = 3", "k2" }, { "k", "x = 10", "z = 30", "k2" })
    expect.eq(1, #d.hunks)
    expect.eq({ 2, 3, 2, 2 }, range(d.hunks[1]))
    expect.eq({ "2=2", "3-", "4=3" }, shape(d.hunks[1]))
  end)

  it("keeps a line-matched hunk as one hunk", function()
    local d = line.diff({ "foo = 1", "bar = 2", "baz" }, { "new line", "foo = 10", "bar = 20", "qux" })
    expect.eq(1, #d.hunks)
    expect.eq({ 1, 3, 1, 4 }, range(d.hunks[1]))
    expect.eq({ "+1", "1=2", "2=3", "3=4" }, shape(d.hunks[1]))
  end)

  it("pairs by position with linematch off: changed, then deleted, then added", function()
    local d = line.diff({ "a", "b", "c", "k" }, { "x", "y", "k" }, { linematch = 0 })
    expect.eq({ "1=1", "2=2", "3-" }, shape(d.hunks[1]))
    d = line.diff({ "a", "k" }, { "x", "y", "k" }, { linematch = 0 })
    expect.eq({ "1=1", "+2" }, shape(d.hunks[1]))
  end)

  it("finds separate hunks with the unchanged runs between them", function()
    local old = { "1", "2", "3", "4", "5", "6", "7" }
    local new = { "1", "two", "3", "4", "5", "six", "7", "8" }
    local d = line.diff(old, new)
    expect.eq(3, #d.hunks)
    expect.eq({ 2, 1, 2, 1 }, range(d.hunks[1]))
    expect.eq({ 6, 1, 6, 1 }, range(d.hunks[2]))
    expect.eq({ 7, 0, 8, 1 }, range(d.hunks[3]))
    expect.eq({
      { old_start = 1, new_start = 1, count = 1, row = 1 },
      { old_start = 3, new_start = 3, count = 3, row = 3 },
      { old_start = 7, new_start = 7, count = 1, row = 7 },
    }, d.unchanged)
    expect.eq({ 1, 2, 3 }, { d.hunks[1].index, d.hunks[2].index, d.hunks[3].index })
    expect.eq({ 2, 6, 8 }, { d.hunks[1].row, d.hunks[2].row, d.hunks[3].row })
    expect.eq(8, d.rows)
  end)

  it("marks every hunk as not formatting-only; only structural diff can say so", function()
    local d = line.diff({ "f(a, b)" }, { "f(", "  a,", "  b", ")" })
    expect.falsy(d.hunks[1].formatting_only)
  end)

  it("does not report a missing final newline, since lines carry none", function()
    local d = line.diff({ "a", "b" }, { "a", "b" })
    expect.eq(0, #d.hunks)
  end)

  it("handles lines holding a newline (a buffer NUL) without miscounting", function()
    local d = line.diff({ "a\nb", "c" }, { "a\nb", "d" })
    expect.eq(1, #d.hunks)
    expect.eq({ 2, 1, 2, 1 }, range(d.hunks[1]))
    expect.eq(2, d.rows)
  end)

  it("does not equate an escaped newline with a literal backslash-n", function()
    local d = line.diff({ "a\\nb" }, { "a\nb" })
    expect.eq(1, #d.hunks)
  end)

  it("skips token ranges when inline is off", function()
    local d = line.diff({ "x = 1" }, { "x = 2" }, { inline = false })
    expect.eq({ "1=1" }, shape(d.hunks[1]))
    expect.eq({}, d.tokens.old)
  end)

  it("accepts every algorithm vim.text.diff knows", function()
    for _, algorithm in ipairs({ "myers", "minimal", "patience", "histogram" }) do
      local d = line.diff({ "a", "b" }, { "a", "c" }, { algorithm = algorithm })
      expect.eq({ "2=2" }, shape(d.hunks[1]), algorithm)
    end
  end)

  it("keeps the row count equal to the lines of either side plus that side's filler", function()
    math.randomseed(42)
    for _ = 1, 50 do
      local old, new = {}, {}
      for i = 1, math.random(0, 40) do
        old[i] = tostring(math.random(1, 8))
      end
      for i = 1, math.random(0, 40) do
        new[i] = tostring(math.random(1, 8))
      end
      local d = line.diff(old, new)
      for _, side in ipairs({ "old", "new" }) do
        local fill = 0
        for _, f in ipairs(d.fillers[side]) do
          fill = fill + f.count
        end
        expect.eq(d.rows, #(side == "old" and old or new) + fill, side)
      end
      -- Every row maps back to lines that really are equal when unchanged.
      for row = 1, d.rows do
        local o, n = d:line_at(row)
        if o and n and not d:kind("old", o) then
          expect.eq(old[o], new[n])
        end
      end
    end
  end)

  it("diffs 50,000 lines with 5,000 changed in well under a second", function()
    local old, new = {}, {}
    for i = 1, 50000 do
      old[i] = ("local v%d = %d"):format(i, i)
      new[i] = i % 10 == 0 and ("local v%d = %d + 1"):format(i, i) or old[i]
    end
    local started = vim.uv.hrtime()
    local d = line.diff(old, new)
    local ms = (vim.uv.hrtime() - started) / 1e6
    expect.eq(5000, #d.hunks)
    expect.truthy(ms < 1000, ("took %.0f ms"):format(ms))
    -- Histogram alone takes seconds on this shape; the engine must have fallen back.
    expect.eq("myers", d.algorithm)
  end)

  it("keeps histogram for an ordinary diff, and reports which algorithm ran", function()
    local old, new = {}, {}
    for i = 1, 20000 do
      old[i] = "line " .. i
      new[i] = i % 1000 == 0 and "edited" or old[i]
    end
    expect.eq("histogram", line.diff(old, new).algorithm)
    expect.eq("patience", line.diff({ "a" }, { "b" }, { algorithm = "patience" }).algorithm)
  end)
end)
