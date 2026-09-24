local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local hunk = require("nvim-diff.diff.hunk")
local line = require("nvim-diff.diff.line")

-- One of each kind of hunk. Display rows:
--
--    1  a  a
--    2  b  B      changed
--    3  c  c
--    4  d  d
--    5  e  ┈      deleted, filler on new
--    6  f  f
--    7  g  g
--    8  ┈  x      added, filler on old
--    9  ┈  y
--   10  h  h
local OLD = { "a", "b", "c", "d", "e", "f", "g", "h" }
local NEW = { "a", "B", "c", "d", "f", "g", "x", "y", "h" }

---@return NvimDiff.Diff
local function fixture()
  return line.diff(OLD, NEW)
end

---@param n integer
---@param changed table<integer, boolean>
---@return string[] old
---@return string[] new
local function numbered(n, changed)
  local old, new = {}, {}
  for i = 1, n do
    old[i] = "line " .. i
    new[i] = changed[i] and ("line " .. i .. " changed") or old[i]
  end
  return old, new
end

describe("diff.hunk model", function()
  it("lays out rows, runs and fillers", function()
    local d = fixture()
    expect.eq(10, d.rows)
    expect.eq(8, d.old_count)
    expect.eq(9, d.new_count)
    expect.eq(3, #d.hunks)
    expect.eq({
      { old_start = 1, new_start = 1, count = 1, row = 1 },
      { old_start = 3, new_start = 3, count = 2, row = 3 },
      { old_start = 6, new_start = 5, count = 2, row = 6 },
      { old_start = 8, new_start = 9, count = 1, row = 10 },
    }, d.unchanged)
    expect.eq({ { after = 7, count = 2, row = 8 } }, d.fillers.old)
    expect.eq({ { after = 4, count = 1, row = 5 } }, d.fillers.new)
  end)

  it("merges contiguous filler into one block and anchors top-of-file filler at 0", function()
    local d = line.diff({ "k" }, { "x", "y", "z", "k" })
    expect.eq({ { after = 0, count = 3, row = 1 } }, d.fillers.old)
    expect.eq({}, d.fillers.new)
  end)

  it("splits filler where a changed row interrupts it", function()
    local rows = {
      { kind = "added", new = 1 },
      { kind = "changed", old = 1, new = 2 },
      { kind = "added", new = 3 },
    }
    local d = hunk.new(1, 3, { { old_start = 1, old_count = 1, new_start = 1, new_count = 3, rows = rows } })
    expect.eq({
      { after = 0, count = 1, row = 1 },
      { after = 1, count = 1, row = 3 },
    }, d.fillers.old)
  end)

  it("rejects hunks that do not tile the files", function()
    expect.errors(function()
      hunk.new(3, 3, { { old_start = 2, old_count = 1, new_start = 3, new_count = 1, rows = {} } })
    end, "overlap or are out of order")
    expect.errors(function()
      hunk.new(3, 4, {})
    end, "do not cover")
  end)

  it("starts with empty tokens and a line token source", function()
    local d = hunk.new(1, 1, {})
    expect.eq({ old = {}, new = {} }, d.tokens)
    expect.eq("line", d.token_source)
  end)
end)

describe("diff.hunk lookups", function()
  it("classifies lines by kind", function()
    local d = fixture()
    expect.eq("changed", d:kind("old", 2))
    expect.eq("changed", d:kind("new", 2))
    expect.eq("deleted", d:kind("old", 5))
    expect.eq("added", d:kind("new", 7))
    expect.eq("added", d:kind("new", 8))
    expect.eq(nil, d:kind("old", 6))
    expect.eq(nil, d:kind("new", 9))
  end)

  it("finds the hunk holding a line, and none for a line next to an insertion point", function()
    local d = fixture()
    expect.eq(2, d:hunk_at("old", 5).index)
    expect.eq(3, d:hunk_at("new", 8).index)
    expect.eq(nil, d:hunk_at("old", 8))
    expect.eq(nil, d:hunk_at("new", 5))
    expect.eq(nil, d:hunk_at("old", 99))
  end)

  it("maps lines to display rows on both sides", function()
    local d = fixture()
    local old_rows, new_rows = {}, {}
    for l = 1, 8 do
      old_rows[l] = d:row_of("old", l)
    end
    for l = 1, 9 do
      new_rows[l] = d:row_of("new", l)
    end
    expect.eq({ 1, 2, 3, 4, 5, 6, 7, 10 }, old_rows)
    expect.eq({ 1, 2, 3, 4, 6, 7, 8, 9, 10 }, new_rows)
    expect.eq(nil, d:row_of("old", 0))
    expect.eq(nil, d:row_of("new", 10))
  end)

  it("maps display rows back to lines, nil on filler", function()
    local d = fixture()
    expect.eq({ 2, 2 }, { d:line_at(2) })
    expect.eq({ 5 }, { d:line_at(5) })
    local old, new = d:line_at(8)
    expect.eq({ nil, 7 }, { old, new })
    expect.eq({ 6, 5 }, { d:line_at(6) })
    expect.eq({ 8, 9 }, { d:line_at(10) })
    expect.eq({}, { d:line_at(11) })
  end)

  it("round-trips every line through row_of and line_at", function()
    local d = fixture()
    for _, side in ipairs({ "old", "new" }) do
      for l = 1, d[side .. "_count"] do
        local old, new = d:line_at(d:row_of(side, l))
        expect.eq(l, side == "old" and old or new, side .. " " .. l)
      end
    end
  end)

  it("gives the counterpart line, or the nearest one above a filler", function()
    local d = fixture()
    expect.eq({ 2, true }, { d:counterpart("new", 2) })
    expect.eq({ 5, true }, { d:counterpart("old", 6) })
    expect.eq({ 4, false }, { d:counterpart("old", 5) })
    expect.eq({ 7, false }, { d:counterpart("new", 7) })
    expect.eq({ 7, false }, { d:counterpart("new", 8) })
    expect.eq({ 9, true }, { d:counterpart("old", 8) })
    expect.eq({ nil, false }, { d:counterpart("old", 9) })
  end)

  it("gives 0 as the counterpart of a top-of-file addition", function()
    local d = line.diff({ "k" }, { "x", "k" })
    expect.eq({ 0, false }, { d:counterpart("new", 1) })
  end)

  it("rejects an unknown side", function()
    expect.errors(function()
      fixture():row_of("LEFT", 1)
    end, "side must be 'old' or 'new'")
  end)
end)

describe("diff.hunk commentable_ranges", function()
  it("is empty for identical files", function()
    local d = line.diff({ "a" }, { "a" })
    expect.eq({}, d:commentable_ranges("new"))
    expect.eq({}, hunk.commentable_ranges(d, "old"))
  end)

  it("covers each hunk plus 3 lines of context, clipped to the file", function()
    local d = line.diff(numbered(30, { [2] = true, [25] = true }))
    expect.eq({ { 1, 5 }, { 22, 28 } }, d:commentable_ranges("new"))
    expect.eq({ { 1, 5 }, { 22, 28 } }, d:commentable_ranges("old"))
  end)

  it("merges hunks up to 6 lines apart and keeps 7 apart separate, like git -U3", function()
    local d = line.diff(numbered(30, { [5] = true, [12] = true }))
    expect.eq({ { 2, 15 } }, d:commentable_ranges("new"))
    d = line.diff(numbered(30, { [5] = true, [13] = true }))
    expect.eq({ { 2, 8 }, { 10, 16 } }, d:commentable_ranges("new"))
  end)

  it("gives a side with no lines in the hunk the context around the insertion point", function()
    local d = fixture()
    expect.eq({ { 1, 8 } }, d:commentable_ranges("old"))
    expect.eq({ { 1, 9 } }, d:commentable_ranges("new"))
    expect.eq({ { 2, 2 }, { 5, 5 } }, d:commentable_ranges("old", 0))
    expect.eq({ { 2, 2 }, { 7, 8 } }, d:commentable_ranges("new", 0))
  end)

  it("answers is_commentable per line", function()
    local d = line.diff(numbered(30, { [2] = true, [25] = true }))
    expect.truthy(d:is_commentable("new", 5))
    expect.falsy(d:is_commentable("new", 6))
    expect.truthy(d:is_commentable("new", 22))
    expect.falsy(d:is_commentable("new", 29))
  end)

  it("agrees with the hunk headers of git diff -U3 --histogram", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    math.randomseed(7)
    for _ = 1, 25 do
      local old, new = {}, {}
      for i = 1, 60 do
        old[i] = "l" .. i
        new[#new + 1] = old[i]
        local roll = math.random(1, 12)
        if roll == 1 then
          new[#new] = "changed " .. i
        elseif roll == 2 then
          new[#new] = nil
        elseif roll == 3 then
          new[#new + 1] = "added after " .. i
        end
      end
      vim.fn.writefile(old, dir .. "/a")
      vim.fn.writefile(new, dir .. "/b")
      -- Hermetic: the user's config may route `git diff` through an external tool.
      local cmd = { "git", "diff", "--no-index", "--no-ext-diff", "--no-color", "--histogram", "-U3" }
      vim.list_extend(cmd, { dir .. "/a", dir .. "/b" })
      local env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" }
      local out = vim.system(cmd, { text = true, env = env }):wait().stdout or ""
      expect.matches("@@", out)
      local want = { old = {}, new = {} }
      ---@param side NvimDiff.Side
      ---@param start string
      ---@param count string A missing count means 1.
      local function add(side, start, count)
        local s, c = tonumber(start), tonumber(count ~= "" and count or "1")
        if c > 0 then
          want[side][#want[side] + 1] = { s, s + c - 1 }
        end
      end
      for os, oc, ns, nc in out:gmatch("\n@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@") do
        add("old", os, oc)
        add("new", ns, nc)
      end
      local d = line.diff(old, new)
      expect.eq(want.old, d:commentable_ranges("old"), "old")
      expect.eq(want.new, d:commentable_ranges("new"), "new")
    end
    vim.fn.delete(dir, "rf")
  end)
end)
