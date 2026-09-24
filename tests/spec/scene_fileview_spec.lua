local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local child_mod = require("tests.child")
local config = require("nvim-diff.config")
local fileview = require("nvim-diff.scene.fileview")
local line = require("nvim-diff.diff.line")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

---@type NvimDiff.FileView?
local current
---@type NvimDiff.TestChild?
local child

---@param old string[]
---@param new string[]
---@param extra? table
---@return NvimDiff.FileView
local function open(old, new, extra)
  current = fileview.open(vim.tbl_extend("force", {
    diff = line.diff(old, new),
    old = { lines = old, label = "a/f.txt" },
    new = { lines = new, label = "b/f.txt" },
  }, extra or {}))
  return current
end

---@return integer
local function tab_wins()
  return #api.nvim_tabpage_list_wins(0)
end

local OLD = { "a", "b", "c", "d", "e", "f", "g" }
local NEW = { "a", "B", "c", "d", "n1", "n2", "e", "f", "g" }

describe("scene.fileview", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    if current then
      current:close()
      current = nil
    end
    if child then
      child:stop()
      child = nil
    end
    config.reset()
    vim.cmd("silent! only")
    vim.cmd("silent! tabonly")
  end)

  it("opens side-by-side by default and unified when config says so", function()
    local v = open(OLD, NEW)
    expect.eq("side_by_side", v.layout)
    expect.eq(2, tab_wins())
    v:close()
    config.setup({ layout = "unified" })
    v = open(OLD, NEW)
    expect.eq("unified", v.layout)
    expect.eq(1, tab_wins())
    v:close()
    v = open(OLD, NEW, { layout = "side_by_side" })
    expect.eq("side_by_side", v.layout)
  end)

  it("flips to unified in the window the cursor is in, and back into two panes", function()
    local v = open(OLD, NEW)
    local p = v.scene --[[@as NvimDiff.Pair]]
    local pair_bufs = { p.bufs.old, p.bufs.new }
    local win = p.wins.new
    api.nvim_set_current_win(win)
    v:toggle()
    expect.eq("unified", v.layout)
    expect.eq(1, tab_wins())
    local u = v.scene --[[@as NvimDiff.Unified]]
    expect.eq(win, u.win)
    expect.eq(u.buf, api.nvim_win_get_buf(win))
    for _, b in ipairs(pair_bufs) do
      expect.falsy(api.nvim_buf_is_valid(b), "pair buffer left behind")
    end
    expect.truthy(p.closed)

    local ubuf = u.buf
    v:toggle()
    expect.eq("side_by_side", v.layout)
    expect.eq(2, tab_wins())
    p = v.scene --[[@as NvimDiff.Pair]]
    expect.eq(win, p.wins.new)
    expect.falsy(api.nvim_buf_is_valid(ubuf), "unified buffer left behind")
    expect.truthy(u.closed)
    -- The left pane is the old side.
    expect.truthy(api.nvim_win_get_position(p.wins.old)[2] < api.nvim_win_get_position(p.wins.new)[2])
    -- No stray buffers: exactly the two panes' and the tab's original one.
    local names = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
      if vim.bo[b].buftype == "nofile" then
        names[#names + 1] = b
      end
    end
    expect.eq(2, #names)
  end)

  it("keeps the cursor on the same file line both ways, and in the same pane", function()
    local v = open(OLD, NEW)
    local p = v.scene --[[@as NvimDiff.Pair]]
    -- old "b" (changed): unified shows it as a deleted line.
    api.nvim_set_current_win(p.wins.old)
    api.nvim_win_set_cursor(p.wins.old, { 3, 0 })
    v:toggle()
    local u = v.scene --[[@as NvimDiff.Unified]]
    expect.eq({ "old", 2 }, { u:cursor_pos() })
    -- Move onto an unchanged line: back in side-by-side, the cursor is in the old pane.
    api.nvim_win_set_cursor(u.win, { u:buf_line("old", 6), 0 })
    v:toggle()
    p = v.scene --[[@as NvimDiff.Pair]]
    expect.eq(p.wins.old, api.nvim_get_current_win())
    expect.eq(6, p:cursor_line("old"))
    expect.eq(8, p:cursor_line("new"))
    -- From the new pane on an added line.
    api.nvim_set_current_win(p.wins.new)
    api.nvim_win_set_cursor(p.wins.new, { 7, 0 }) -- new "n2"
    v:toggle()
    expect.eq({ "new", 6 }, { v.scene:cursor_pos() })
    v:toggle()
    expect.eq(v.scene.wins.new, api.nvim_get_current_win())
    expect.eq(6, v.scene:cursor_line("new"))
  end)

  it("carries inserted blocks across the toggle", function()
    local v = open(OLD, NEW)
    v:set_block("t1", { row = 2, new = { { { "T1", "" } }, { { "T1b", "" } } } })
    v:set_block("t2", { row = 5, old = { { { "T2", "" } } } })
    v:remove_block("t2")
    v:set_block("t3", { row = 0, old = { { { "T3", "" } } } })
    v:toggle()
    local u = v.scene --[[@as NvimDiff.Unified]]
    local texts = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(u.buf, sidebyside.ns_virt, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines) do
        texts[#texts + 1] = m[2] .. ":" .. vl[1][1]
      end
    end
    expect.eq({ "0:T3", "3:T1", "3:T1b" }, texts)
    v:toggle()
    local p = v.scene --[[@as NvimDiff.Pair]]
    expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.new, {}).all)
    expect.eq(api.nvim_win_text_height(p.wins.old, {}).all, api.nvim_win_text_height(p.wins.new, {}).all)
    expect.eq(2, #p.map.blocks)
  end)

  it("maps the toggle key buffer-locally, and not at all when disabled", function()
    local v = open(OLD, NEW)
    for _, g in ipairs(api.nvim_get_keymap("n")) do
      expect.ne("g<C-X>", g.lhs)
    end
    for _, buf in ipairs({ v.scene.bufs.old, v.scene.bufs.new }) do
      local m = api.nvim_buf_call(buf, function()
        return vim.fn.maparg("g<C-x>", "n", false, true)
      end)
      expect.eq(1, m.buffer)
    end
    v:close()
    config.setup({ layout_keymaps = { toggle = false } })
    v = open(OLD, NEW)
    local m = api.nvim_buf_call(v.scene.bufs.new, function()
      return vim.fn.maparg("g<C-x>", "n", false, true)
    end)
    expect.eq({}, m)
  end)

  it("does nothing once its windows are gone", function()
    local v = open(OLD, NEW)
    v:close()
    expect.truthy(v:is_closed())
    expect.no_error(function()
      v:toggle()
    end)
    expect.eq("side_by_side", v.layout)
  end)
end)

--- In a child Neovim: open a random diff as a file view, and define `_G.read()` there,
--- which reads the current layout off the screen and checks it against nothing but the
--- files and the diff model.
---
--- Unified: every row showing a line number must show that file's line after the gutter,
--- with the sign its kind demands. Side-by-side: two panes showing lines face the same
--- display row.
local SETUP = [[
  local seed, size, nblocks = ...
  local old, new = require("tests.diffgen").files(seed, size)
  local d = require("nvim-diff.diff.line").diff(old, new)
  _G.V = require("nvim-diff.scene.fileview").open({
    diff = d,
    old = { lines = old, label = "a/f.txt" },
    new = { lines = new, label = "b/f.txt" },
  })
  for i = 1, nblocks do
    local rows = {}
    for k = 1, math.random(1, 4) do
      rows[k] = { { "thread " .. k, "" } }
    end
    V:set_block(i, { row = math.random(0, d.rows), [i % 2 == 0 and "old" or "new"] = rows })
  end
  local width = require("nvim-diff.render.sidebyside").number_width(d)

  local function cells(row, c1, c2)
    local out = {}
    for c = c1, c2 do
      out[#out + 1] = vim.fn.screenstring(row, c)
    end
    return table.concat(out)
  end

  local function check_unified(bad)
    local win = V.scene.win
    local pos = vim.api.nvim_win_get_position(win)
    local wwidth = vim.api.nvim_win_get_width(win)
    local text_col = pos[2] + 1 + width * 2 + 4
    for r = 1, vim.api.nvim_win_get_height(win) do
      local row = pos[1] + r
      local o = tonumber(cells(row, pos[2] + 1, pos[2] + width):match("%d+") or "")
      local n = tonumber(cells(row, pos[2] + width + 2, pos[2] + 2 * width + 1):match("%d+") or "")
      local sign = vim.fn.screenstring(row, pos[2] + 2 * width + 3)
      local shown = cells(row, text_col, pos[2] + wwidth):gsub("%s+$", "")
      local want, want_sign
      if o and n then
        want, want_sign = new[n], " "
        if old[o] ~= new[n] or d:row_of("old", o) ~= d:row_of("new", n) then
          bad[#bad + 1] = ("row %d: %d/%d shown as unchanged"):format(r, o, n)
        end
      elseif o then
        want, want_sign = old[o], "-"
      elseif n then
        want, want_sign = new[n], "+"
      end
      if want and (shown ~= want:sub(1, #shown) or #shown == 0 and #want > 0 or sign ~= want_sign) then
        bad[#bad + 1] = ("row %d: [%s|%s] %q, want [%s] %q"):format(r, tostring(o), tostring(n), shown, want_sign, want)
      end
    end
  end

  local function pane_nums(win)
    local pos = vim.api.nvim_win_get_position(win)
    local out = {}
    for r = 1, vim.api.nvim_win_get_height(win) do
      out[r] = tonumber(cells(pos[1] + r, pos[2] + 1, pos[2] + width):match("%d+") or "")
    end
    return out
  end

  local function check_pair(bad)
    local a, b = pane_nums(V.scene.wins.old), pane_nums(V.scene.wins.new)
    for r = 1, #a do
      if a[r] and b[r] and d:row_of("old", a[r]) ~= d:row_of("new", b[r]) then
        bad[#bad + 1] = ("row %d: old %d faces new %d"):format(r, a[r], b[r])
      end
    end
  end

  function _G.read()
    vim.cmd("redraw")
    local bad = {}
    if V.layout == "unified" then
      check_unified(bad)
    else
      check_pair(bad)
    end
    local at = V:cursor()
    local top = vim.fn.winsaveview()
    return { layout = V.layout, bad = bad, side = at.side, lnum = at.lnum, winline = at.winline,
      at_top = top.topline == 1 and top.topfill == 0, wins = #vim.api.nvim_tabpage_list_wins(0) }
  end
]]

local KEYS = { "<C-d>", "<C-u>", "<C-e>", "5j", "3k", "G", "gg", "20G", "zt", "zb", "<C-w>w" }

describe("scene.fileview, driven by real keystrokes", function()
  after_each(function()
    if child then
      child:stop()
      child = nil
    end
  end)

  it("flips the current file with the toggle key and draws each layout correctly", function()
    local toggles, bad_screens, lost, moved = 0, 0, 0, 0
    local failures = {}
    for seed = 31, 38 do
      child = child_mod.spawn()
      child:lua(SETUP, seed, 120, seed % 2 == 0 and 5 or 0)
      math.randomseed(seed)
      local state = child:lua("return _G.read()")
      expect.eq("side_by_side", state.layout)
      for _ = 1, 30 do
        for _ = 1, math.random(1, 3) do
          child:input(KEYS[math.random(#KEYS)])
        end
        local before = child:lua("return _G.read()")
        child:input("g<C-x>")
        local after = child:lua("return _G.read()")
        toggles = toggles + 1
        expect.truthy(after.layout ~= before.layout, "the key did not toggle")
        expect.eq(after.layout == "unified" and 1 or 2, after.wins)
        for _, s in ipairs({ before, after }) do
          if #s.bad > 0 then
            bad_screens = bad_screens + 1
            if #failures < 5 then
              failures[#failures + 1] = ("seed %d %s: %s"):format(seed, s.layout, s.bad[1])
            end
          end
        end
        if before.lnum and (after.side ~= before.side or after.lnum ~= before.lnum) then
          -- An unchanged line is one line in unified: the side may legitimately switch to
          -- the one remembered from side-by-side, but the file line is the same line.
          lost = lost + 1
          if #failures < 5 then
            failures[#failures + 1] = ("seed %d: cursor %s:%s -> %s:%s"):format(
              seed,
              before.side,
              tostring(before.lnum),
              after.side,
              tostring(after.lnum)
            )
          end
        end
        -- The cursor keeps its screen row, unless the new layout has fewer rows above it
        -- than that and is scrolled to the very top.
        if after.winline ~= before.winline and not (after.at_top and after.winline < before.winline) then
          moved = moved + 1
        end
      end
      child:stop()
      child = nil
    end
    io.stdout:write(
      ("       measured: %d toggles, %d bad screens, %d lost the line, %d moved the cursor's screen row\n"):format(
        toggles,
        bad_screens,
        lost,
        moved
      )
    )
    expect.eq(0, bad_screens, table.concat(failures, "\n      "))
    expect.eq(0, lost, table.concat(failures, "\n      "))
    expect.eq(0, moved, "the cursor changed its screen row")
  end)

  it("shows the unified layout on screen, with both numbers, signs and a thread", function()
    child = child_mod.spawn()
    child:lua([[
      _G.V = require("nvim-diff.scene.fileview").open({
        diff = require("nvim-diff.diff.line").diff({ "a", "b", "c" }, { "a", "B", "c", "n" }),
        old = { lines = { "a", "b", "c" }, label = "a/f" },
        new = { lines = { "a", "B", "c", "n" }, label = "b/f" },
      })
      V:set_block("t", { row = 2, new = { { { "> thread", "" } } } })
    ]])
    child:input("g<C-x>")
    expect.eq({
      "          ── a/f → b/f ──",
      "  1   1   a              ",
      "  2     - b              ",
      "      2 + B              ",
      "> thread                 ",
      "  3   3   c              ",
      "      4 + n              ",
      "~                        ",
    }, child:screen(2, 9, 1, 25))
    child:input("g<C-x>")
    expect.eq({
      "    ── a/f ──",
      "  1 a        ",
      "  2 b        ",
      "             ",
      "  3 c        ",
      "┈┈┈┈┈┈┈┈┈┈┈┈┈",
    }, child:screen(2, 7, 1, 13))
  end)
end)
