local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local child_mod = require("tests.child")

---@type NvimDiff.TestChild?
local child

--- Open a pair in the child, and define `_G.check()` there: read both panes off the screen
--- and count the screen rows whose two halves do not belong to the same display row.
---
--- The check uses nothing but the screen and the diff model: a row showing old line `a`
--- and new line `b` is aligned iff `row_of("old", a) == row_of("new", b)`; a row showing
--- a line against filler is aligned iff that line's display row has no line on the other
--- side; header faces header, trailer faces trailer, `~` faces `~`.
local SETUP = [[
  local seed, size, so, nblocks = ...
  local old, new = require("tests.diffgen").files(seed, size)
  local d = require("nvim-diff.diff.line").diff(old, new)
  vim.o.scrolloff = so
  local left = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local right = vim.api.nvim_get_current_win()
  _G.P = require("nvim-diff.scene.pair").open({
    diff = d,
    old = { lines = old, label = "a/f.txt" },
    new = { lines = new, label = "b/f.txt" },
    wins = { old = right, new = left },
  })
  local width = require("nvim-diff.render.sidebyside").number_width(d)
  -- Blocks stand in for comment threads: text on one side, blank padding on the other.
  for i = 1, nblocks do
    local rows = {}
    for k = 1, math.random(1, 6) do
      rows[k] = { { "thread " .. k, "" } }
    end
    P:set_block(i, { row = math.random(0, d.rows), [i % 2 == 0 and "old" or "new"] = rows })
  end

  local function read(win)
    local pos = vim.api.nvim_win_get_position(win)
    local out = {}
    for r = 1, vim.api.nvim_win_get_height(win) do
      local row, col = pos[1] + r, pos[2] + 1
      local first = vim.fn.screenstring(row, col)
      local num = {}
      for c = col, col + width - 1 do
        num[#num + 1] = vim.fn.screenstring(row, c)
      end
      local n = table.concat(num):match("%d+")
      if first == "┈" then
        out[r] = "F"
      elseif first == "~" then
        out[r] = "~"
      elseif n then
        out[r] = tonumber(n)
      elseif vim.fn.screenstring(row, col + width + 1) == "─" then
        out[r] = "H"
      else
        out[r] = "B"
      end
    end
    return out
  end

  local function other_is_filler(side, lnum)
    local o, n = d:line_at(d:row_of(side, lnum))
    if side == "old" then return n == nil end
    return o == nil
  end

  function _G.check()
    vim.cmd("redraw")
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

  function _G.tops()
    local out = {}
    for _, side in ipairs({ "old", "new" }) do
      local v = vim.api.nvim_win_call(P.wins[side], vim.fn.winsaveview)
      out[#out + 1] = P.map:top_view(side, v.topline, v.topfill)
    end
    return out
  end

  function _G.other_pane_cell()
    local cur = vim.api.nvim_get_current_win()
    local win = cur == P.wins.old and P.wins.new or P.wins.old
    local pos = vim.api.nvim_win_get_position(win)
    return { pos[1] + 3, pos[2] + 10 }
  end
]]

local KEYS = {
  "<C-e>",
  "<C-y>",
  "3<C-e>",
  "4<C-y>",
  "<C-d>",
  "<C-u>",
  "<C-f>",
  "<C-b>",
  "j",
  "k",
  "7j",
  "9k",
  "}",
  "{",
  "zt",
  "zb",
  "zz",
  "H",
  "L",
  "M",
  "G",
  "gg",
  "20G",
  "45G",
}

describe("scene.scrollsync, driven by real keystrokes", function()
  after_each(function()
    if child then
      child:stop()
      child = nil
    end
  end)

  it("keeps both panes on the same display rows through scrolling, jumps and pane switches", function()
    local ops, misaligned, switches, jumps = 0, 0, 0, 0
    local failures = {}
    -- { seed, scrolloff, blocks }
    local configs = {
      { 11, 0, 0 },
      { 12, 8, 0 },
      { 13, 3, 0 },
      { 14, 0, 0 },
      { 15, 8, 0 },
      { 16, 5, 0 },
      { 17, 0, 6 },
      { 18, 8, 6 },
      { 19, 3, 12 },
      { 20, 0, 12 },
    }
    for _, cfg in ipairs(configs) do
      local seed, so, nblocks = cfg[1], cfg[2], cfg[3]
      child = child_mod.spawn()
      child:lua(SETUP, seed, 160, so, nblocks)
      math.randomseed(seed)
      for _ = 1, 200 do
        local r = math.random()
        local label
        if r < 0.1 then
          label = "<C-w>w"
          local before = child:lua("return _G.tops()")
          child:input("<C-w>w")
          local after = child:lua("return _G.tops()")
          switches = switches + 1
          if not vim.deep_equal(before, after) then
            jumps = jumps + 1
          end
        elseif r < 0.2 then
          local cell = child:lua("return _G.other_pane_cell()")
          local dir = math.random() < 0.5 and "down" or "up"
          label = "wheel " .. dir .. " on the other pane"
          child:mouse("wheel", dir, "", 0, cell[1], cell[2])
        else
          label = KEYS[math.random(#KEYS)]
          child:input(label)
        end
        ops = ops + 1
        local bad = child:lua("return _G.check()")
        if #bad > 0 then
          misaligned = misaligned + 1
          if #failures < 5 then
            failures[#failures + 1] = ("seed %d so %d after %s: %s"):format(seed, so, label, bad[1])
          end
        end
      end
      child:stop()
      child = nil
    end
    io.stdout:write(
      ("       measured: %d/%d ops misaligned, %d/%d pane switches scrolled\n"):format(misaligned, ops, jumps, switches)
    )
    expect.eq(0, misaligned, table.concat(failures, "\n      "))
    expect.eq(0, jumps, "entering a pane scrolled it")
  end)

  it("moves the other pane's cursor to the counterpart line as the cursor moves", function()
    child = child_mod.spawn()
    local got = child:lua([[
      local left = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      local right = vim.api.nvim_get_current_win()
      _G.P = require("nvim-diff.scene.pair").open({
        diff = require("nvim-diff.diff.line").diff({ "a", "b", "c" }, { "a", "X", "Y", "b", "c" }),
        old = { lines = { "a", "b", "c" }, label = "a" },
        new = { lines = { "a", "X", "Y", "b", "c" }, label = "b" },
        wins = { old = right, new = left },
      })
      vim.api.nvim_set_current_win(P.wins.new)
    ]])
    expect.eq(vim.NIL, got)
    child:input("5G") -- new "b"
    expect.eq(3, child:lua("return vim.api.nvim_win_get_cursor(P.wins.old)[1]")) -- old "b"
    child:input("3G") -- new "X", filler opposite
    expect.eq(2, child:lua("return vim.api.nvim_win_get_cursor(P.wins.old)[1]")) -- old "a"
  end)
end)
