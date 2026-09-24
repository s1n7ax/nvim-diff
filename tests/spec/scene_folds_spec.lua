local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local child_mod = require("tests.child")

---@type NvimDiff.TestChild?
local child

--- Screen helpers defined in the child: `_G.read(win)` classifies each screen row of a pane
--- as a file line number, `"S:<label>"` for a separator band, `"F"` filler, `"H"` header,
--- `"B"` blank, `"~"`; `_G.check()` returns the rows whose two halves disagree, using only
--- the screen and the diff model (never the row map). A band faces a band with the same
--- label (the part before any scope, which may differ by side).
local HELPERS = [[
  function _G.read(win)
    local d, width = P.diff, require("nvim-diff.render.sidebyside").number_width(P.diff)
    local pos = vim.api.nvim_win_get_position(win)
    local wwidth = vim.api.nvim_win_get_width(win)
    local out = {}
    for r = 1, vim.api.nvim_win_get_height(win) do
      local row, col = pos[1] + r, pos[2] + 1
      local cells = {}
      for c = col, col + wwidth - 1 do
        cells[#cells + 1] = vim.fn.screenstring(row, c)
      end
      local text = table.concat(cells)
      local first = cells[1]
      local n = table.concat(cells, "", 1, width):match("%d+")
      if first == "·" then
        local label = text:match("(%d+ unchanged lines?)") or text:match("(reformatted into %d+ lines?)") or "?"
        out[r] = "S:" .. label
      elseif first == "┈" then
        out[r] = "F"
      elseif first == "~" then
        out[r] = "~"
      elseif n then
        out[r] = tonumber(n)
      elseif cells[width + 2] == "─" then
        out[r] = "H"
      else
        out[r] = "B"
      end
    end
    return out
  end

  local function other_is_filler(side, lnum)
    local d = P.diff
    local o, n = d:line_at(d:row_of(side, lnum))
    if side == "old" then return n == nil end
    return o == nil
  end

  function _G.check()
    vim.cmd("redraw")
    local d = P.diff
    local a, b = read(P.wins.old), read(P.wins.new)
    local bad = {}
    for r = 1, #a do
      local x, y = a[r], b[r]
      local ok
      if type(x) == "number" and type(y) == "number" then
        ok = d:row_of("old", x) == d:row_of("new", y)
      elseif type(x) == "number" then
        ok = y == "F" and other_is_filler("old", x)
      elseif type(y) == "number" then
        ok = x == "F" and other_is_filler("new", y)
      else
        ok = x == y and x ~= "F"
      end
      if not ok then
        bad[#bad + 1] = ("row %d: %s | %s"):format(r, tostring(x), tostring(y))
      end
    end
    return bad
  end

  function _G.bands(win)
    local out = {}
    for r, v in ipairs(read(win)) do
      if type(v) == "string" and v:sub(1, 2) == "S:" then
        out[#out + 1] = { r, v:sub(3) }
      end
    end
    return out
  end

  function _G.cursor(side)
    return vim.api.nvim_win_get_cursor(P.wins[side])[1]
  end
]]

--- Open a pair on `old`/`new` in two vertical splits, old on the left, new current.
local OPEN = [[
  local old, new, opts = ...
  opts = opts or {}
  local d = require("nvim-diff.diff.line").diff(old, new)
  for _, i in ipairs(opts.reformat or {}) do
    d.hunks[i].formatting_only = true
  end
  vim.o.scrolloff = opts.so or 0
  local right = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local left = vim.api.nvim_get_current_win()
  _G.P = require("nvim-diff.scene.pair").open({
    diff = d,
    old = { lines = old, label = "a/f.lua" },
    new = { lines = new, label = "b/f.lua" },
    wins = { old = left, new = right },
    fold = opts.fold,
  })
  vim.api.nvim_set_current_win(P.wins.new)
]]

---@param n integer
---@return string[]
local function numbered(n)
  local out = {}
  for i = 1, n do
    out[i] = "  line " .. i
  end
  return out
end

--- 60 lines with a scope line at 20 and 45 and a change at 25 and 50.
---@return string[], string[]
local function sample()
  local old = numbered(60)
  old[1] = "local M = {}"
  old[20] = "function M.server(opts)"
  old[45] = "function M.client()"
  local new = vim.deepcopy(old)
  new[25] = "  line 25 changed"
  new[50] = "  line 50 changed"
  return old, new
end

---@param old string[]
---@param new string[]
---@param opts? table
---@return NvimDiff.TestChild
local function open(old, new, opts)
  child = child_mod.spawn()
  child:lua(HELPERS)
  child:lua(OPEN, old, new, opts)
  return child
end

describe("scene.folds", function()
  after_each(function()
    if child then
      child:stop()
      child = nil
    end
  end)

  it("draws each fold as one steel band on the same row of both panes", function()
    local c = open(sample())
    expect.eq({}, c:lua("return check()"))
    local bands = c:lua("return bands(P.wins.old)")
    expect.eq(bands, c:lua("return bands(P.wins.new)"))
    -- 1..21 fold, 22..28 context, 29..46 fold, 47..53 context, 54..60 fold.
    expect.eq({ { 2, "21 unchanged lines" }, { 10, "18 unchanged lines" }, { 18, "7 unchanged lines" } }, bands)
    -- The scope is the nearest scope line above the fold's end; the pane cuts it off.
    expect.eq("······· 21 unchanged lines ··· function ", c:screen(2, 2, 1, 40)[1])
    local wide = c:lua([[
      vim.cmd("only")
      vim.cmd("redraw")
      local cells = {}
      for col = 1, 80 do
        cells[#cells + 1] = vim.fn.screenstring(10, col)
      end
      return table.concat(cells)
    ]])
    expect.truthy(vim.startswith(wide, "······· 18 unchanged lines ··· function M.client() ···"), wide)
    expect.truthy(vim.endswith(wide, "·"), wide)
  end)

  it("paints the band in one colour from column 1 to the window edge", function()
    local c = open(sample())
    local attrs = c:lua([[
      vim.cmd("redraw")
      local w = vim.api.nvim_win_get_width(P.wins.old)
      local set = {}
      for col = 1, w do
        set[vim.fn.screenattr(2, col)] = true
      end
      return { band = vim.tbl_count(set), a = vim.fn.screenattr(2, 1), line = vim.fn.screenattr(3, 8) }
    ]])
    expect.eq(1, attrs.band)
    expect.ne(attrs.line, attrs.a)
  end)

  it("reveals ten rows per zo in both panes and keeps the cursor on the band", function()
    local c = open(sample())
    c:input("30G") -- the second band: file lines 29..46, buffer lines 30..47
    expect.eq(30, c:lua("return cursor('new')"))
    c:input("zo")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ { 2, "21 unchanged lines" }, { 20, "8 unchanged lines" } }, c:lua("return bands(P.wins.new)"))
    expect.eq(c:lua("return bands(P.wins.new)"), c:lua("return bands(P.wins.old)"))
    expect.eq(40, c:lua("return cursor('new')")) -- still on the band, now at line 39
    expect.eq(40, c:lua("return vim.fn.foldclosed(40)"))
    c:input("zo") -- 8 left: less than a step, the rest opens
    expect.eq({}, c:lua("return check()"))
    expect.eq(0, c:lua("return #vim.tbl_filter(function(f) return f.first >= 29 and f.last <= 46 end, P.folds)"))
  end)

  it("reveals a fold at the top of the file from its bottom", function()
    local c = open(sample())
    c:input("2Gzo")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 2, "11 unchanged lines" }, c:lua("return bands(P.wins.new)[1]"))
    expect.eq(12, c:lua("return read(P.wins.new)[3]")) -- lines 12..21 now under the band
    expect.eq(2, c:lua("return cursor('new')"))
  end)

  it("opens and closes folds on both panes with zO, zc, za, zR and zM", function()
    local c = open(sample())
    c:input("30GzO")
    expect.eq({}, c:lua("return check()"))
    expect.eq(2, c:lua("return #P.folds"))
    c:input("5jzc") -- from inside what was revealed, fold it back
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #P.folds"))
    c:input("zR")
    expect.eq({}, c:lua("return check()"))
    expect.eq(0, c:lua("return #P.folds"))
    expect.eq(0, #c:lua("return bands(P.wins.new)"))
    expect.eq(0, #c:lua("return bands(P.wins.old)"))
    c:input("zM")
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #P.folds"))
    c:input("gg2Gza")
    expect.eq(2, c:lua("return #P.folds"))
    c:input("za")
    expect.eq(3, c:lua("return #P.folds"))
    -- The keys that would unmirror the panes do nothing.
    c:input("zE")
    c:input("zd")
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #P.folds"))
  end)

  it("works the same from the old pane", function()
    local c = open(sample())
    c:input("<C-w>h30Gzo")
    expect.eq({}, c:lua("return check()"))
    expect.eq(40, c:lua("return cursor('old')"))
    expect.eq(c:lua("return bands(P.wins.new)"), c:lua("return bands(P.wins.old)"))
  end)

  it("reveals a fold a search lands in on both panes", function()
    local c = open(sample())
    c:input("/line 40<CR>")
    expect.eq({}, c:lua("return check()"))
    expect.eq(-1, c:lua("return vim.api.nvim_win_call(P.wins.old, function() return vim.fn.foldclosed(41) end)"))
    expect.eq(2, c:lua("return #P.folds"))
  end)

  it("collapses a pure reformat to one band on both sides and opens it whole", function()
    local old = numbered(30)
    old[10] = "call(x, y, z)"
    local new = vim.deepcopy(old)
    new[10] = "call("
    table.insert(new, 11, "  x,")
    table.insert(new, 12, "  y,")
    table.insert(new, 13, "  z")
    table.insert(new, 14, ")")
    local c = open(old, new, { reformat = { 1 } })
    expect.eq({}, c:lua("return check()"))
    local bands = c:lua("return bands(P.wins.new)")
    expect.eq(bands, c:lua("return bands(P.wins.old)"))
    expect.eq({ 6, "reformatted into 5 lines" }, bands[2])
    expect.eq("······· reformatted into 5 lines — no s", c:screen(6, 6, 1, 39)[1])
    -- No filler anywhere: five lines against one cost one row each side.
    for _, v in ipairs(c:lua("return read(P.wins.old)")) do
      expect.ne("F", v)
    end
    c:input("11Gzo")
    expect.eq({}, c:lua("return check()"))
    expect.eq(4, #vim.tbl_filter(function(v)
      return v == "F"
    end, c:lua("return read(P.wins.old)")))
    c:input("zc")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 6, "reformatted into 5 lines" }, c:lua("return bands(P.wins.old)[2]"))
  end)

  it("draws a reformat as a virtual band on the side with no lines in it", function()
    local old = numbered(30)
    local new = vim.deepcopy(old)
    table.insert(new, 15, "")
    table.insert(new, 15, "")
    local c = open(old, new, { reformat = { 1 } })
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 6, "reformatted into 2 lines" }, c:lua("return bands(P.wins.old)[2]"))
    -- Its text starts in the same column as the folded side's.
    local l, r = c:screen(6, 6, 1, 39)[1], c:screen(6, 6, 42, 80)[1]
    expect.eq(l:find("reformatted", 1, true), r:find("reformatted", 1, true))
  end)

  it("splits a fold around a block so the block hangs off a visible line", function()
    local c = open(sample())
    c:lua([[P:set_block("t", { row = 35, new = { { { "thread", "" } } } })]])
    expect.eq({}, c:lua("return check()"))
    -- The 29..46 fold became 29..34 and 36..46 around the commented row.
    expect.eq(
      { { 2, "21 unchanged lines" }, { 10, "6 unchanged lines" }, { 13, "11 unchanged lines" } },
      vim.list_slice(c:lua("return bands(P.wins.new)"), 1, 3)
    )
    c:input("zM") -- collapsing keeps the block's row out
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 10, "6 unchanged lines" }, c:lua("return bands(P.wins.new)[2]"))
  end)

  it("shows every line when folding is off", function()
    local old, new = sample()
    local c = open(old, new, { fold = false })
    expect.eq(0, #c:lua("return bands(P.wins.new)"))
    expect.eq(0, c:lua("return #P.folds"))
  end)

  it("has a check that catches a fold open in one pane only", function()
    local c = open(sample())
    c:lua([[vim.api.nvim_win_call(P.wins.old, function() vim.cmd("normal! 30Gzo") end)]])
    expect.truthy(#c:lua("return check()") > 0)
  end)

  it("keeps both panes aligned through random scrolling, expanding and collapsing", function()
    local keys = {
      "<C-e>",
      "<C-y>",
      "<C-d>",
      "<C-u>",
      "<C-f>",
      "<C-b>",
      "j",
      "k",
      "5j",
      "5k",
      "}",
      "{",
      "zt",
      "zz",
      "zb",
      "G",
      "gg",
      "zo",
      "zo",
      "zo",
      "3zo",
      "zO",
      "zc",
      "za",
      "zR",
      "zM",
      "zj",
      "zk",
      "<C-w>w",
      "n",
      "N",
    }
    local ops, misaligned, refolds, failures = 0, 0, 0, {}
    for _, seed in ipairs({ 1, 2, 3, 4, 5, 6 }) do
      math.randomseed(seed)
      -- A long file with a few scattered edits: long unchanged runs to fold.
      local old = {}
      for i = 1, 400 do
        old[i] = ("w%d w%d"):format(math.random(1, 50), i)
      end
      local new = vim.deepcopy(old)
      for _ = 1, 8 do
        local at = math.random(1, #new - 5)
        local r = math.random()
        if r < 0.33 then
          new[at] = new[at] .. " x"
        elseif r < 0.66 then
          for k = 1, math.random(1, 4) do
            table.insert(new, at, "ins " .. k)
          end
        else
          for _ = 1, math.random(1, 4) do
            table.remove(new, at)
          end
        end
      end
      local reformat = {}
      local nhunks = #require("nvim-diff.diff.line").diff(old, new).hunks
      for i = 1, nhunks do
        if math.random() < 0.3 then
          reformat[#reformat + 1] = i
        end
      end
      local c = open(old, new, { reformat = reformat, so = ({ 0, 3, 8 })[seed % 3 + 1] })
      c:input("/w1<CR>")
      for _ = 1, 120 do
        local k = keys[math.random(#keys)]
        local before = c:lua("return vim.inspect(P.folds)")
        c:input(k)
        ops = ops + 1
        if c:lua("return vim.inspect(P.folds)") ~= before then
          refolds = refolds + 1
        end
        local bad = c:lua("return check()")
        if #bad > 0 then
          misaligned = misaligned + 1
          if #failures < 5 then
            failures[#failures + 1] = ("seed %d after %s: %s"):format(seed, k, bad[1])
          end
        end
      end
      c:stop()
      child = nil
    end
    io.stdout:write(
      ("       measured: %d/%d ops misaligned with folds, %d of them changed the folds\n"):format(
        misaligned,
        ops,
        refolds
      )
    )
    expect.truthy(refolds > 50, "the run barely touched the folds")
    expect.eq(0, misaligned, table.concat(failures, "\n      "))
  end)
end)
