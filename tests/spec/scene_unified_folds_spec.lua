local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local child_mod = require("tests.child")

---@type NvimDiff.TestChild?
local child

--- Screen helpers defined in the child, over the file view `V`:
---
--- * `_G.read()` classifies each screen row of the unified pane: `"S:<label>"` for a
---   separator band, `"<old>/<new>"` for a line (either number may be empty), `"H"` the
---   header, `"V"` a virtual row, `"~"`.
--- * `_G.expected()` is the same list for the whole pane, built from the layout, the fold
---   list and the blocks' virtual rows — never from the pane's row maths.
--- * `_G.check()` returns what is wrong: the screen must be one contiguous slice of the
---   expected rows, and the window's real folds must be exactly the fold list's.
--- * `_G.bands()` lists `{ screen row, label }` of every band on screen.
local HELPERS = [[
  local fold = require("nvim-diff.render.fold")
  local render = require("nvim-diff.render.unified")

  local function label(text)
    return text:match("(%d+ unchanged lines?)") or text:match("(reformatted into %d+ lines?)") or "?"
  end

  function _G.read()
    local u = V.scene
    local width = require("nvim-diff.render.sidebyside").number_width(u.diff)
    local pos = vim.api.nvim_win_get_position(u.win)
    local wwidth = vim.api.nvim_win_get_width(u.win)
    local out = {}
    for r = 1, vim.api.nvim_win_get_height(u.win) do
      local cells = {}
      for c = pos[2] + 1, pos[2] + wwidth do
        cells[#cells + 1] = vim.fn.screenstring(pos[1] + r, c)
      end
      local text = table.concat(cells)
      local o = table.concat(cells, "", 1, width):match("%d+")
      local n = table.concat(cells, "", width + 2, 2 * width + 1):match("%d+")
      if cells[1] == "·" then
        out[r] = "S:" .. label(text)
      elseif cells[1] == "~" then
        out[r] = "~"
      elseif o or n then
        out[r] = (o or "") .. "/" .. (n or "")
      elseif text:find("──", 1, true) then
        out[r] = "H"
      else
        out[r] = "V"
      end
    end
    return out
  end

  function _G.expected()
    local u = V.scene
    local out = { "H" }
    local virt = {}
    for _, v in ipairs(u.virt) do
      virt[v.anchor] = #v.lines
    end
    for _ = 1, virt[0] or 0 do
      out[#out + 1] = "V"
    end
    local count = vim.api.nvim_buf_line_count(u.buf)
    local bl = 2
    while bl <= count do
      local i = render.range_at(u.ranges, bl)
      if i then
        out[#out + 1] = "S:" .. label(fold.label(u.diff, u.folds[i]))
        bl = u.ranges[i].last + 1
      else
        local x = u.layout.lines[bl - 1]
        out[#out + 1] = (x.old and tostring(x.old) or "") .. "/" .. (x.new and tostring(x.new) or "")
        for _ = 1, virt[bl - 1] or 0 do
          out[#out + 1] = "V"
        end
        bl = bl + 1
      end
    end
    return out
  end

  function _G.check()
    vim.cmd("redraw")
    local u = V.scene
    local bad = {}
    local shown = read()
    while shown[#shown] == "~" do
      shown[#shown] = nil
    end
    local want = expected()
    local found = false
    for s = 1, #want - #shown + 1 do
      local ok = true
      for k = 1, #shown do
        if want[s + k - 1] ~= shown[k] then
          ok = false
          break
        end
      end
      if ok then
        found = true
        break
      end
    end
    if not found then
      bad[#bad + 1] = "screen is no slice of the pane: " .. table.concat(shown, " ")
    end
    vim.api.nvim_win_call(u.win, function()
      local count = vim.api.nvim_buf_line_count(u.buf)
      local bl, i = 1, 1
      while bl <= count do
        local r = u.ranges[i]
        local c = vim.fn.foldclosed(bl)
        if r and bl == r.first then
          if c ~= r.first or vim.fn.foldclosedend(bl) ~= r.last then
            bad[#bad + 1] = ("fold %d..%d is %d..%d in the window"):format(r.first, r.last, c, vim.fn.foldclosedend(bl))
          end
          bl, i = r.last + 1, i + 1
        else
          if c ~= -1 then
            bad[#bad + 1] = ("line %d is folded in the window only"):format(bl)
          end
          bl = bl + 1
        end
      end
    end)
    return bad
  end

  function _G.bands()
    local out = {}
    for r, v in ipairs(read()) do
      if v:sub(1, 2) == "S:" then
        out[#out + 1] = { r, v:sub(3) }
      end
    end
    return out
  end

  function _G.cursor()
    return vim.api.nvim_win_get_cursor(V.scene.win)[1]
  end
]]

--- Open a file view on `old`/`new`, unified unless `opts.layout` says otherwise.
local OPEN = [[
  local old, new, opts = ...
  opts = opts or {}
  local d = require("nvim-diff.diff.line").diff(old, new)
  for _, i in ipairs(opts.reformat or {}) do
    d.hunks[i].formatting_only = true
  end
  vim.o.scrolloff = opts.so or 0
  _G.V = require("nvim-diff.scene.fileview").open({
    diff = d,
    old = { lines = old, label = "a/f.lua" },
    new = { lines = new, label = "b/f.lua" },
    layout = opts.layout or "unified",
    wins = { win = vim.api.nvim_get_current_win() },
    fold = opts.fold,
  })
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
  child:lua(OPEN, old, new, opts)
  child:lua(HELPERS)
  return child
end

describe("scene.unified folds", function()
  after_each(function()
    if child then
      child:stop()
      child = nil
    end
  end)

  it("draws each fold as one steel band across the whole pane", function()
    local c = open(sample())
    expect.eq({}, c:lua("return check()"))
    -- The same folds a side-by-side pair of this diff opens with.
    expect.eq(
      { { 1, 21 }, { 29, 46 }, { 54, 60 } },
      c:lua("return vim.tbl_map(function(f) return { f.first, f.last } end, V.scene.folds)")
    )
    expect.eq(
      { { 2, "21 unchanged lines" }, { 11, "18 unchanged lines" }, { 20, "7 unchanged lines" } },
      c:lua("return bands()")
    )
    -- The fill covers both number columns and the sign, then the label and the scope.
    expect.eq(
      "············· 18 unchanged lines ··· function M.client() ···",
      c:screen(11, 11, 1, 60)[1]
    )
    local attrs = c:lua([[
      vim.cmd("redraw")
      local set = {}
      for col = 1, 80 do
        set[vim.fn.screenattr(2, col)] = true
      end
      return { band = vim.tbl_count(set), a = vim.fn.screenattr(2, 1), line = vim.fn.screenattr(3, 12) }
    ]])
    expect.eq(1, attrs.band)
    expect.ne(attrs.line, attrs.a)
  end)

  it("reveals ten rows per zo and keeps the cursor on the band", function()
    local c = open(sample())
    c:input(c:lua("return V.scene:buf_line('new', 29)") .. "G") -- the second band: file lines 29..46
    c:input("zo")
    expect.eq({}, c:lua("return check()"))
    expect.eq(
      { { 2, "21 unchanged lines" }, { 21, "8 unchanged lines" } },
      vim.list_slice(c:lua("return bands()"), 1, 2)
    )
    expect.eq(c:lua("return vim.fn.foldclosed(cursor())"), c:lua("return cursor()"))
    expect.eq(c:lua("return V.scene:buf_line('new', 39)"), c:lua("return cursor()"))
    c:input("zo") -- 8 left: less than a step, the rest opens
    expect.eq({}, c:lua("return check()"))
    expect.eq(2, c:lua("return #V.scene.folds"))
  end)

  it("reveals a fold at the top of the file from its bottom", function()
    local c = open(sample())
    c:input("2Gzo")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 2, "11 unchanged lines" }, c:lua("return bands()[1]"))
    expect.eq("12/12", c:lua("return read()[3]"))
    expect.eq(2, c:lua("return cursor()"))
  end)

  it("opens and closes folds with zO, zc, za, zR and zM, and ignores the rest", function()
    local c = open(sample())
    c:input(c:lua("return V.scene:buf_line('new', 29)") .. "GzO")
    expect.eq({}, c:lua("return check()"))
    expect.eq(2, c:lua("return #V.scene.folds"))
    c:input("5jzc")
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #V.scene.folds"))
    c:input("zR")
    expect.eq({}, c:lua("return check()"))
    expect.eq(0, #c:lua("return bands()"))
    c:input("zM")
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #V.scene.folds"))
    c:input("gg2Gza")
    expect.eq(2, c:lua("return #V.scene.folds"))
    c:input("za")
    expect.eq(3, c:lua("return #V.scene.folds"))
    c:input("zE")
    c:input("zd")
    c:input("zfj")
    expect.eq({}, c:lua("return check()"))
    expect.eq(3, c:lua("return #V.scene.folds"))
  end)

  it("reveals a fold a search lands in", function()
    local c = open(sample())
    c:input("/line 40<CR>")
    expect.eq({}, c:lua("return check()"))
    expect.eq(2, c:lua("return #V.scene.folds"))
    expect.eq(-1, c:lua("return vim.fn.foldclosed('.')"))
  end)

  it("collapses a pure reformat, old and new lines together, to one band and opens it whole", function()
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
    -- Band over 1..6, lines 7..9, the reformat (one old line, five new), lines 11..13.
    expect.eq(
      { { 2, "6 unchanged lines" }, { 6, "reformatted into 5 lines" } },
      vim.list_slice(c:lua("return bands()"), 1, 2)
    )
    expect.eq("············· reformatted into 5 lines — no semantic change", c:screen(6, 6, 1, 59)[1])
    expect.eq("11/15", c:lua("return read()[7]"))
    c:input(c:lua("return V.scene:buf_line('old', 10)") .. "Gzo")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ "10/", "/10", "/11", "/12", "/13", "/14" }, vim.list_slice(c:lua("return read()"), 6, 11))
    c:input("zc")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 6, "reformatted into 5 lines" }, c:lua("return bands()[2]"))
  end)

  it("splits a fold around a block so the block hangs off a visible line", function()
    local c = open(sample())
    c:lua([[V:set_block("t", { row = 35, new = { { { "thread", "" } } } })]])
    expect.eq({}, c:lua("return check()"))
    expect.eq(
      { { 2, "21 unchanged lines" }, { 11, "6 unchanged lines" }, { 14, "11 unchanged lines" } },
      vim.list_slice(c:lua("return bands()"), 1, 3)
    )
    expect.eq({ "35/35", "V" }, vim.list_slice(c:lua("return read()"), 12, 13))
    c:input("zM")
    expect.eq({}, c:lua("return check()"))
    expect.eq({ 11, "6 unchanged lines" }, c:lua("return bands()[2]"))
  end)

  it("shows every line when folding is off", function()
    local old, new = sample()
    local c = open(old, new, { fold = false })
    expect.eq({}, c:lua("return check()"))
    expect.eq(0, #c:lua("return bands()"))
    c:input("g<C-x>")
    expect.eq(0, c:lua("return #V.scene.folds"))
  end)

  it("keeps the folds as they are across the layout toggle, with the cursor on its band", function()
    local old, new = sample()
    local c = open(old, new, { layout = "side_by_side" })
    c:input("30Gzo") -- side-by-side: second fold, 10 lines revealed
    local folds = c:lua("return vim.inspect(V.scene.folds)")
    c:input("g<C-x>")
    expect.eq("unified", c:lua("return V.layout"))
    expect.eq(folds, c:lua("return vim.inspect(V.scene.folds)"))
    expect.eq({}, c:lua("return check()"))
    -- The cursor is still on the band, now of lines 39..46, at the same screen row.
    expect.eq(c:lua("return V.scene:buf_line('new', 39)"), c:lua("return vim.fn.foldclosed(cursor())"))
    c:input("zo")
    c:input("2Gzo")
    folds = c:lua("return vim.inspect(V.scene.folds)")
    c:input("g<C-x>")
    expect.eq("side_by_side", c:lua("return V.layout"))
    expect.eq(folds, c:lua("return vim.inspect(V.scene.folds)"))
    -- Collapsing still knows the original folds.
    c:input("zM")
    expect.eq(3, c:lua("return #V.scene.folds"))
  end)

  it("has a check that catches folds the window and the list disagree on", function()
    local c = open(sample())
    c:lua([[vim.api.nvim_win_call(V.scene.win, function() vim.cmd("normal! zE") end)]])
    expect.truthy(#c:lua("return check()") > 0)
    c:lua([[V.scene:set_folds(V.scene.folds)]])
    expect.eq({}, c:lua("return check()"))
    c:lua([[table.remove(V.scene.ranges, 2)]])
    expect.truthy(#c:lua("return check()") > 0)
  end)

  it("stays correct through random scrolling, fold keys and toggles", function()
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
      "n",
      "N",
      "g<C-x>",
      "g<C-x>",
    }
    local ops, bad_screens, refolds, lost_folds, toggles, failures = 0, 0, 0, 0, 0, {}
    for _, seed in ipairs({ 1, 2, 3, 4, 5, 6 }) do
      math.randomseed(seed)
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
      if seed % 2 == 0 then
        c:lua([[V:set_block("t", { row = 100, new = { { { "thread", "" } }, { { "more", "" } } } })]])
      end
      c:input("/w1<CR>")
      for _ = 1, 100 do
        local k = keys[math.random(#keys)]
        local before = c:lua("return vim.inspect(V.scene.folds)")
        c:input(k)
        ops = ops + 1
        local after = c:lua("return vim.inspect(V.scene.folds)")
        if k == "g<C-x>" then
          toggles = toggles + 1
          if after ~= before then
            lost_folds = lost_folds + 1
          end
        elseif after ~= before then
          refolds = refolds + 1
        end
        if c:lua("return V.layout") == "unified" then
          local bad = c:lua("return check()")
          if #bad > 0 then
            bad_screens = bad_screens + 1
            if #failures < 5 then
              failures[#failures + 1] = ("seed %d after %s: %s"):format(seed, k, bad[1])
            end
          end
        end
      end
      c:stop()
      child = nil
    end
    io.stdout:write(
      ("       measured: %d ops, %d bad unified screens, %d changed the folds, %d/%d toggles lost them\n"):format(
        ops,
        bad_screens,
        refolds,
        lost_folds,
        toggles
      )
    )
    expect.truthy(refolds > 40, "the run barely touched the folds")
    expect.truthy(toggles > 10, "the run barely toggled")
    expect.eq(0, bad_screens, table.concat(failures, "\n      "))
    expect.eq(0, lost_folds, "a toggle changed the folds")
  end)
end)
