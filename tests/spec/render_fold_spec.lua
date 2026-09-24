local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local diffgen = require("tests.diffgen")
local fold = require("nvim-diff.render.fold")
local line = require("nvim-diff.diff.line")
local rowmap = require("nvim-diff.render.rowmap")
local sidebyside = require("nvim-diff.render.sidebyside")

local SIDES = { "old", "new" }

---@param n integer
---@param prefix? string
---@return string[]
local function numbered(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or "  line ") .. i
  end
  return out
end

--- A 60-line file with one line changed at `at`.
---@param at integer
---@return NvimDiff.Diff
local function one_change(at)
  local old = numbered(60)
  local new = vim.deepcopy(old)
  new[at] = "changed"
  return line.diff(old, new)
end

---@param folds NvimDiff.Fold[]
---@return [integer, integer, string][]
local function ranges(folds)
  local out = {}
  for i, f in ipairs(folds) do
    out[i] = { f.first, f.last, f.kind }
  end
  return out
end

--- A random diff with some hunks marked as pure reformats, and random blocks outside the
--- folds (as the pair guarantees).
---@param seed integer
---@return NvimDiff.Diff, NvimDiff.Fold[], NvimDiff.Block[]
local function random_case(seed)
  local old, new = diffgen.files(seed)
  local d = line.diff(old, new)
  math.randomseed(seed)
  for _, h in ipairs(d.hunks) do
    h.formatting_only = math.random() < 0.3
  end
  local folds = fold.compute(d, { context = math.random(1, 4) })
  local blocks = {}
  for i = 1, seed % 5 do
    local b = { row = math.random(0, d.rows), new = { { { "thread " .. i } } } }
    if math.random() < 0.5 then
      b.old = { { { "x" } }, { { "y" } } }
    end
    blocks[i] = b
    folds = fold.reveal(folds, b.row)
  end
  -- Expand a few, as a reader would.
  for _ = 1, math.random(0, 3) do
    if #folds > 0 then
      local i = math.random(#folds)
      folds = fold.expand(folds, i, math.random() < 0.5 and 10 or nil, math.random() < 0.5 and "up" or "down")
    end
  end
  return d, folds, blocks
end

describe("render.fold", function()
  it("keeps three rows of context next to each hunk and folds the rest", function()
    local folds = fold.compute(one_change(30))
    -- Rows 1..26 and 34..60 fold; 27..29 and 31..33 stay as context around row 30.
    expect.eq({ { 1, 26, "context" }, { 34, 60, "context" } }, ranges(folds))
    expect.eq({ 1, 2 }, { folds[1].id, folds[2].id })
  end)

  it("keeps no context at the ends of the file and at least one row next to a hunk", function()
    expect.eq({ { 3, 60, "context" } }, ranges(fold.compute(one_change(1), { context = 1 })))
    expect.eq({ { 1, 58, "context" } }, ranges(fold.compute(one_change(60), { context = 1 })))
    expect.eq({ { 3, 60, "context" } }, ranges(fold.compute(one_change(1), { context = 0 })))
  end)

  it("folds an identical file whole and never makes a one-row fold", function()
    local same = line.diff(numbered(20), numbered(20))
    expect.eq({ { 1, 20, "context" } }, ranges(fold.compute(same)))
    -- A gap of 7 between two changes leaves one row between the contexts: not folded.
    local old = numbered(30)
    local new = vim.deepcopy(old)
    new[10], new[18] = "x", "y"
    local folds = fold.compute(line.diff(old, new))
    expect.eq({ { 1, 6, "context" }, { 22, 30, "context" } }, ranges(folds))
    new[19] = "z"
    expect.eq(0, #vim.tbl_filter(function(f)
      return f.first > 10 and f.last < 18
    end, fold.compute(line.diff(old, new))))
  end)

  it("folds a formatting-only hunk whole as a reformat separator, context around it", function()
    local old = numbered(20)
    local new = vim.deepcopy(old)
    new[10] = "a"
    table.insert(new, 11, "b")
    local d = line.diff(old, new)
    d.hunks[1].formatting_only = true
    local folds = fold.compute(d)
    expect.eq({ { 1, 6, "context" }, { 10, 11, "reformat" }, { 15, 21, "context" } }, ranges(folds))
    expect.eq(1, folds[2].hunk)
    expect.eq({ 10, 10 }, { fold.side_lines(d, folds[2], "old") })
    expect.eq({ 10, 11 }, { fold.side_lines(d, folds[2], "new") })
    expect.eq("··· reformatted into 2 lines — no semantic change", fold.label(d, folds[2]))
    expect.eq("NvimDiffReformatSeparator", fold.group(folds[2]))
  end)

  it("gives a side with no lines in a reformat hunk no fold range", function()
    local old = numbered(10)
    local new = vim.deepcopy(old)
    table.insert(new, 5, "")
    local d = line.diff(old, new)
    d.hunks[1].formatting_only = true
    local folds = fold.compute(d, { context = 1 })
    local r = folds[fold.find(folds, d.hunks[1].row)]
    expect.eq("reformat", r.kind)
    expect.eq({}, { fold.side_lines(d, r, "old") })
    expect.eq({ 5, 5 }, { fold.side_lines(d, r, "new") })
  end)

  it("expands ten rows from the top, from the bottom at the top of the file, or whole", function()
    local folds = fold.compute(one_change(30))
    expect.eq({ { 1, 16, "context" }, { 34, 60, "context" } }, ranges(fold.expand(folds, 1, 10)))
    expect.eq({ { 1, 26, "context" }, { 44, 60, "context" } }, ranges(fold.expand(folds, 2, 10)))
    expect.eq({ { 1, 26, "context" }, { 34, 50, "context" } }, ranges(fold.expand(folds, 2, 10, "up")))
    expect.eq({ { 34, 60, "context" } }, ranges(fold.expand(folds, 1)))
    -- A remainder under two rows is revealed with the rest.
    local small = { { first = 1, last = 11, kind = "context", id = 1 } }
    expect.eq({}, fold.expand(small, 1, 10))
    expect.eq(
      { { 1, 2, "context" } },
      ranges(fold.expand({ { first = 1, last = 12, kind = "context", id = 1 } }, 1, 10))
    )
  end)

  it("opens a reformat fold whole whatever the step", function()
    local folds = { { first = 5, last = 9, kind = "reformat", id = 1, hunk = 1 } }
    expect.eq({}, fold.expand(folds, 1, 1))
  end)

  it("restores a fold to its original range and keeps the others as they are", function()
    local base = fold.compute(one_change(30))
    local now = fold.expand(fold.expand(base, 1, 10), 2)
    expect.eq({ { 1, 16, "context" } }, ranges(now))
    expect.eq({ { 1, 16, "context" }, { 34, 60, "context" } }, ranges(fold.restore(now, base, { [2] = true })))
    expect.eq(ranges(base), ranges(fold.restore(now, base, { [1] = true, [2] = true })))
  end)

  it("splits a context fold around a revealed row and opens a reformat fold", function()
    local folds = { { first = 1, last = 20, kind = "context", id = 1 } }
    expect.eq({ { 1, 9, "context" }, { 11, 20, "context" } }, ranges(fold.reveal(folds, 10)))
    expect.eq({ { 2, 20, "context" } }, ranges(fold.reveal(folds, 1)))
    expect.eq({ { 1, 19, "context" } }, ranges(fold.reveal(folds, 20)))
    expect.eq(folds, fold.reveal(folds, 25))
    expect.eq({}, fold.reveal({ { first = 3, last = 4, kind = "reformat", id = 1, hunk = 1 } }, 4))
    local split = fold.reveal(folds, 10)
    expect.eq({ 1, 1 }, { split[1].id, split[2].id })
  end)

  it("labels a context fold with its size and the nearest scope line above its end", function()
    local lines = { "local M = {}", "", "function M.run(opts)", "  local x = 1", "end", "  y" }
    local idx = fold.scope_index(lines)
    expect.eq({ 1, 3 }, idx) -- `end` closes a scope rather than naming one
    expect.eq("function M.run(opts)", fold.scope_at(lines, idx, 6))
    expect.eq("local M = {}", fold.scope_at(lines, idx, 2))
    expect.eq(nil, fold.scope_at({ "  a", "  b" }, fold.scope_index({ "  a", "  b" }), 2))
    expect.eq("impl Server", fold.scope_at({ "impl Server {" }, { 1 }, 1))
    local long = ("x"):rep(100) .. "()"
    expect.eq(fold.SCOPE_MAX, vim.fn.strchars(fold.scope_at({ long }, { 1 }, 1)))

    local d = line.diff(numbered(10), numbered(10))
    local f = { first = 1, last = 128, kind = "context", id = 1 }
    expect.eq("··· 128 unchanged lines ··· impl Server", fold.label(d, f, "impl Server"))
    expect.eq("··· 1 unchanged line", fold.label(d, { first = 3, last = 3, kind = "context", id = 1 }))
  end)

  it("serves foldtext from the texts registered for the buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, numbered(10))
    fold.texts[buf] = { [3] = { "··· 4 unchanged lines", "NvimDiffContextSeparator" } }
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 40, height = 5 })
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldtext = fold.FOLDTEXT
    local got = vim.api.nvim_win_call(win, function()
      vim.cmd("3,6fold")
      vim.cmd("8,9fold")
      return { vim.fn.foldtextresult(3), vim.fn.foldtextresult(8) }
    end)
    -- A fold with no registered text still reads as a band, never as code.
    expect.eq({ "··· 4 unchanged lines ", "···" }, got)
    fold.texts[buf] = nil
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("render.rowmap with folds", function()
  it("gives every row of a fold the fold's one view row", function()
    local d = one_change(30)
    local map = rowmap.new(d, nil, fold.compute(d))
    -- View rows: 0 header, 1 the first fold, 2..8 rows 27..33, 9 the second fold.
    for lnum = 1, 26 do
      expect.eq(1, map:line_view("old", lnum + 1))
    end
    expect.eq(2, map:line_view("new", 28))
    expect.eq(8, map:line_view("new", 34))
    expect.eq(9, map:line_view("old", 35))
    expect.eq(9, map:line_view("new", 61))
    expect.eq(10, map:height())
    expect.eq({ 2, 0 }, { map:view_top("old", 1) }) -- a fold's first line is its top
    expect.eq({ 28, 0 }, { map:view_top("new", 2) })
  end)

  it("makes a reformat hunk one row on both sides, a virtual row where a side has none", function()
    local old = numbered(10)
    local new = vim.deepcopy(old)
    table.insert(new, 6, "")
    table.insert(new, 6, "")
    local d = line.diff(old, new)
    d.hunks[1].formatting_only = true
    local folds = fold.compute(d, { context = 1 })
    local map = rowmap.new(d, nil, folds)
    -- Rows: fold 1..4, 5 context, 6..7 reformat (filler on old), 8 context, fold 9..12.
    expect.eq({ { 1, 4, "context" }, { 6, 7, "reformat" }, { 9, 12, "context" } }, ranges(folds))
    expect.eq(3, map:line_view("new", 7))
    expect.eq(3, map:line_view("new", 8))
    expect.eq(4, map:line_view("old", 7)) -- old line 6 sits right under the one separator row
    expect.eq({ 7, 1 }, { map:view_top("old", 3) }) -- old shows it as virtual row above line 6
    expect.eq({ 7, 0 }, { map:view_top("new", 3) })
    -- The old side draws one separator row instead of two filler rows, after old line 5.
    local rows = sidebyside.virt_rows(map, "old")
    expect.eq(1, #rows)
    expect.eq(5, rows[1].anchor)
    expect.eq(1, #rows[1].lines)
    expect.matches("reformatted into 2 lines", rows[1].lines[1][2][1])
    expect.eq(0, #sidebyside.virt_rows(map, "new"))
  end)

  it("draws no filler for a folded reformat on the side that has lines", function()
    local old = numbered(10)
    local new = vim.deepcopy(old)
    new[5] = "  line 5 x"
    table.insert(new, 6, "  line 5 y")
    local d = line.diff(old, new)
    d.hunks[1].formatting_only = true
    local map = rowmap.new(d, nil, fold.compute(d, { context = 1 }))
    expect.eq(0, #sidebyside.virt_rows(map, "old"))
    expect.eq(1, #sidebyside.virt_rows(rowmap.new(d), "old"))
  end)

  it("refuses a block inside a fold", function()
    local d = one_change(30)
    expect.errors(function()
      rowmap.new(d, { { row = 5, new = { { { "x" } } } } }, fold.compute(d))
    end, "block inside a fold")
  end)

  it("round-trips every reachable view row with folds, reformats and blocks", function()
    for seed = 1, 80 do
      local d, folds, blocks = random_case(seed)
      local map = rowmap.new(d, blocks, folds)
      for v = 0, map:height() - 1 do
        local reach = {}
        for _, side in ipairs(SIDES) do
          local tl, tf = map:view_top(side, v)
          reach[side] = tl ~= nil
          if tl then
            expect.eq(v, map:top_view(side, tl, tf), ("seed %d side %s v %d"):format(seed, side, v))
          end
        end
        expect.eq(reach.old, reach.new, ("seed %d v %d"):format(seed, v))
      end
      for v = 0, map:max_top() do
        expect.truthy(map:view_top("old", v), ("seed %d v %d unreachable"):format(seed, v))
      end
    end
  end)

  it("gives both lines of a display row the same view row, folded or not", function()
    for seed = 200, 260 do
      local d, folds, blocks = random_case(seed)
      local map = rowmap.new(d, blocks, folds)
      for row = 1, d.rows do
        local o, n = d:line_at(row)
        if o and n then
          expect.eq(map:line_view("old", o + 1), map:line_view("new", n + 1), ("seed %d row %d"):format(seed, row))
        end
      end
    end
  end)

  it("counts each pane's own rows to the same height", function()
    for seed = 300, 340 do
      local d, folds, blocks = random_case(seed)
      local map = rowmap.new(d, blocks, folds)
      for _, side in ipairs(SIDES) do
        -- Distinct view rows of real lines, plus every virtual row drawn, plus the header.
        local seen, lines_rows = {}, 0
        for lnum = 1, d[side .. "_count"] do
          local v = map:line_view(side, lnum + 1)
          if not seen[v] then
            seen[v] = true
            lines_rows = lines_rows + 1
          end
        end
        local virt = 0
        for _, r in ipairs(sidebyside.virt_rows(map, side)) do
          virt = virt + #r.lines
        end
        local total = 1 + lines_rows + virt + (map.trailer and 1 or 0)
        expect.eq(map:height(), total, ("seed %d side %s"):format(seed, side))
      end
    end
  end)
end)
