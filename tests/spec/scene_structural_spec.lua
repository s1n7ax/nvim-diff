local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local child_mod = require("tests.child")
local config = require("nvim-diff.config")
local fileview = require("nvim-diff.scene.fileview")
local fold = require("nvim-diff.render.fold")
local line = require("nvim-diff.diff.line")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

--- Old and new Lua files: a call reformatted across five lines near the top (a pure
--- reformat), a real edit near the bottom, unchanged runs around both.
---@return string[] old
---@return string[] new
local function fixture()
  local old, new = { "local M = {}" }, { "local M = {}" }
  for i = 1, 12 do
    old[#old + 1] = ("local c%d = %d"):format(i, i)
    new[#new + 1] = old[#old]
  end
  old[#old + 1] = "local y = f(a, b, c)"
  vim.list_extend(new, { "local y = f(", "  a,", "  b,", "  c", ")" })
  for i = 13, 30 do
    old[#old + 1] = ("local c%d = %d"):format(i, i)
    new[#new + 1] = old[#old]
  end
  old[#old + 1] = "local z = g(1)"
  new[#new + 1] = "local z = g(2)"
  for i = 31, 33 do
    old[#old + 1] = ("local c%d = %d"):format(i, i)
    new[#new + 1] = old[#old]
  end
  old[#old + 1] = "return M"
  new[#new + 1] = "return M"
  return old, new
end

---@type NvimDiff.FileView?
local current

---@param extra? table
---@param old? string[]
---@param new? string[]
---@return NvimDiff.FileView
local function open(extra, old, new)
  if not old then
    old, new = fixture()
  end
  current = fileview.open(vim.tbl_extend("force", {
    diff = line.diff(old, new),
    old = { lines = old, label = "a/f.lua", lang = "lua" },
    new = { lines = new, label = "b/f.lua", lang = "lua" },
  }, extra or {}))
  return current
end

---@param folds NvimDiff.Fold[]
---@return string[]
local function kinds(folds)
  local out = {}
  for i, f in ipairs(folds) do
    out[i] = ("%s %d-%d"):format(f.kind, f.first, f.last)
  end
  return out
end

--- Token marks of a pane buffer, as `"<buffer row>:<col>-<end col>"`.
---@param buf integer
---@return string[]
local function token_marks(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, sidebyside.ns, 0, -1, { details = true })) do
    if m[4].priority == sidebyside.PRIORITY_TOKEN then
      out[#out + 1] = ("%d:%d-%d"):format(m[2], m[3], m[4].end_col)
    end
  end
  return out
end

describe("fold.carry", function()
  it("keeps context folds as they are, renumbered, and takes reformat folds from the base", function()
    local old, new = fixture()
    local d = line.diff(old, new)
    local s = require("nvim-diff.diff.structural").diff(d, old, new, "lua")
    assert(s)
    local line_base, s_base = fold.compute(d), fold.compute(s)
    expect.eq({ "context 1-10", "context 22-33" }, kinds(line_base))
    expect.eq({ "context 1-10", "reformat 14-18", "context 22-33" }, kinds(s_base))

    -- Under the line diff, the middle context fold was expanded by 10 from the top.
    local folds = fold.expand(line_base, 2, 10, "down")
    local carried = fold.carry(folds, s_base)
    expect.eq({ "context 1-10", "reformat 14-18", "context 32-33" }, kinds(carried))
    -- Ids are the new base's, so collapsing restores the right fold.
    expect.eq(s_base[3].id, carried[3].id)
    expect.eq(kinds(s_base), kinds(fold.restore(carried, s_base, { [carried[3].id] = true })))

    -- And back: the reformat fold goes, context stays.
    expect.eq({ "context 1-10", "context 32-33" }, kinds(fold.carry(carried, line_base)))
  end)
end)

describe("scene.fileview diff mode", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    if current then
      current:close()
      current = nil
    end
    config.reset()
    vim.cmd("silent! only")
    vim.cmd("silent! tabonly")
  end)

  it("opens structural by default, with the reformat folded to one band", function()
    local v = open()
    expect.eq("structural", v.mode)
    expect.eq("structural", v.scene.diff.token_source)
    expect.eq({ "context 1-10", "reformat 14-18", "context 22-33" }, kinds(v.scene.folds))
  end)

  it("flips to the line diff and back in place: same buffers, folds carried, tokens repainted", function()
    local v = open()
    local p = v.scene --[[@as NvimDiff.Pair]]
    local bufs = { p.bufs.old, p.bufs.new }
    local s_tokens = token_marks(p.bufs.new)
    -- The edit near the bottom: `2` alone in both modes.
    expect.eq({ "37:12-13" }, s_tokens)

    p:expand("new", 25, 10)
    local expanded = kinds(p.folds)
    expect.truthy(v:toggle_mode())
    expect.eq("line", v.mode)
    expect.eq(p, v.scene)
    expect.eq(bufs, { p.bufs.old, p.bufs.new })
    expect.eq("line", p.diff.token_source)
    expect.eq({ "context 1-10", "context 32-33" }, kinds(p.folds))
    -- The reformatted call is a plain change now: the old line's arguments light up.
    expect.truthy(#token_marks(p.bufs.old) > 1)

    expect.truthy(v:toggle_mode())
    expect.eq("structural", v.mode)
    expect.eq(expanded, kinds(p.folds))
    expect.eq(s_tokens, token_marks(p.bufs.new))
    -- Collapsing still restores the original context fold.
    p:collapse_all()
    expect.eq({ "context 1-10", "reformat 14-18", "context 22-33" }, kinds(p.folds))
  end)

  it("keeps the panes aligned across the flip", function()
    local v = open()
    local p = v.scene --[[@as NvimDiff.Pair]]
    for _ = 1, 2 do
      v:toggle_mode()
      expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.new, {}).all)
      expect.eq(api.nvim_win_text_height(p.wins.old, {}).all, api.nvim_win_text_height(p.wins.new, {}).all)
    end
  end)

  it("flips in the unified layout too, and a layout flip keeps the mode", function()
    local v = open({ layout = "unified" })
    local u = v.scene --[[@as NvimDiff.Unified]]
    expect.eq({ "context 1-10", "reformat 14-18", "context 22-33" }, kinds(u.folds))
    v:toggle_mode()
    expect.eq(u, v.scene)
    expect.eq("line", u.diff.token_source)
    expect.eq({ "context 1-10", "context 22-33" }, kinds(u.folds))
    v:toggle()
    expect.eq("side_by_side", v.layout)
    expect.eq("line", v.scene.diff.token_source)
    v:toggle_mode()
    v:toggle()
    expect.eq("structural", v.scene.diff.token_source)
    expect.eq("reformat", v.scene.folds[2].kind)
  end)

  it("opens the line diff when config turns structural off, and flips to structural on demand", function()
    config.setup({ diff = { structural = false } })
    local v = open()
    expect.eq("line", v.mode)
    expect.eq(nil, v.diffs.structural) -- not computed until asked for
    expect.truthy(v:set_mode("structural"))
    expect.eq("structural", v.scene.diff.token_source)
  end)

  it("falls back to the line diff, and says why, with no parser, mixed languages or too many lines", function()
    config.setup({ log = { level = "off" } })
    local old, new = fixture()
    local v = open({ old = { lines = old, label = "a/f" }, new = { lines = new, label = "b/f" } })
    expect.eq("line", v.mode)
    local ok, why = v:set_mode("structural")
    expect.falsy(ok)
    expect.matches("no treesitter parser", why)
    expect.eq("line", v.scene.diff.token_source)
    v:close()

    v = open({ old = { lines = old, label = "a/f.vim", lang = "vim" } })
    expect.eq("line", v.mode)
    expect.matches("different languages", v.structural_reason)
    v:close()

    config.setup({ thresholds = { structural_lines = 10 }, log = { level = "off" } })
    v = open()
    expect.eq("line", v.mode)
    expect.matches("over 10 lines", v.structural_reason)
  end)

  it("maps the mode key buffer-locally, and not at all when disabled", function()
    local v = open()
    for _, buf in ipairs(v:bufs()) do
      local m = api.nvim_buf_call(buf, function()
        return vim.fn.maparg("gs", "n", false, true)
      end)
      expect.eq(1, m.buffer)
    end
    v:close()
    config.setup({ layout_keymaps = { toggle_structural = false } })
    v = open()
    local m = api.nvim_buf_call(v:bufs()[2], function()
      return vim.fn.maparg("gs", "n", false, true)
    end)
    expect.eq({}, m)
  end)

  it("takes a key or false for the mode toggle, and nothing else", function()
    expect.eq("gs", config.get().layout_keymaps.toggle_structural)
    expect.eq({}, config.validate({ layout_keymaps = { toggle_structural = "<leader>s" } }))
    expect.eq({}, config.validate({ layout_keymaps = { toggle_structural = false } }))
    for _, bad in ipairs({ true, "", 1 }) do
      local errors = config.validate({ layout_keymaps = { toggle_structural = bad } })
      expect.eq(1, #errors)
      expect.matches("`layout_keymaps%.toggle_structural`", errors[1])
    end
  end)

  it("tells the owner the scene changed, so it can remember the mode", function()
    local seen = {}
    local v = open({
      on_scene = function(file)
        seen[#seen + 1] = file.mode
      end,
    })
    v:toggle_mode()
    v:toggle_mode()
    expect.eq({ "structural", "line", "structural" }, seen)
  end)
end)

describe("scene.fileview diff mode, on screen", function()
  ---@type NvimDiff.TestChild?
  local child

  after_each(function()
    if child then
      child:stop()
      child = nil
    end
  end)

  it("draws the reformat band in both panes, and the raw lines after gs", function()
    local old, new = fixture()
    child = child_mod.spawn()
    child:lua(
      [[
      local old, new = ...
      vim.o.lines, vim.o.columns = 24, 80
      _G.V = require("nvim-diff.scene.fileview").open({
        diff = require("nvim-diff.diff.line").diff(old, new),
        old = { lines = old, label = "a/f.lua", lang = "lua" },
        new = { lines = new, label = "b/f.lua", lang = "lua" },
      })
      function _G.pane(side)
        local win = V.scene.wins[side]
        local pos = vim.api.nvim_win_get_position(win)
        vim.cmd("redraw")
        local rows = {}
        for r = 1, 8 do
          local cells = {}
          for c = 1, 40 do
            cells[#cells + 1] = vim.fn.screenstring(pos[1] + r, pos[2] + c)
          end
          rows[r] = (table.concat(cells):gsub("%s+$", ""))
        end
        return rows
      end
    ]],
      old,
      new
    )
    local function band(rows)
      for r, text in ipairs(rows) do
        if text:find("reformatted into", 1, true) then
          return r, text:match("reformatted into %d+ lines")
        end
      end
    end

    local lr, ltext = band(child:lua("return pane('old')"))
    local rr, rtext = band(child:lua("return pane('new')"))
    expect.eq("reformatted into 5 lines", ltext)
    expect.eq(ltext, rtext)
    expect.eq(lr, rr)

    child:input("gs")
    local left, right = child:lua("return pane('old')"), child:lua("return pane('new')")
    expect.eq(nil, band(left))
    expect.eq(nil, band(right))
    expect.eq(" 14 local y = f(a, b, c)", left[6]:sub(1, 24))
    expect.eq(" 14 local y = f(", right[6]:sub(1, 16))
    expect.eq(" 15   a,", right[7]:sub(1, 8))
    expect.eq("line", child:lua("return V.mode"))

    child:input("gs")
    expect.eq("structural", child:lua("return V.mode"))
    expect.eq(lr, (band(child:lua("return pane('old')"))))
  end)
end)

describe("views.diff diff mode", function()
  local gitrepo = require("tests.gitrepo")
  local repo_mod = require("nvim-diff.git.repo")
  local rev = require("nvim-diff.git.rev")
  local views = require("nvim-diff.views.diff")

  ---@type NvimDiff.DiffView?
  local view

  after_each(function()
    if view then
      view:close()
      view = nil
    end
    config.reset()
    gitrepo.cleanup()
  end)

  it("opens panel diffs structural, and reopens a file in the mode it was left in", function()
    local old, new = fixture()
    local r = gitrepo.new()
    r:write("a.lua", table.concat(old, "\n") .. "\n")
    r:write("b.lua", "local b = 1\n")
    local base = r:commit("base")
    r:write("a.lua", table.concat(new, "\n") .. "\n")
    r:write("b.lua", "local b = 2\n")
    view = views.open({
      repo = assert(repo_mod.discover(r.root)),
      left = rev.commit(base, "main"),
      right = rev.worktree(),
    })

    view:select(view.list.entries[1])
    expect.eq("a.lua", view.current.path)
    local file = assert(view.file)
    expect.eq("structural", file.mode)
    expect.eq("reformat", file.scene.folds[2].kind)
    file:toggle_mode()

    view:next_file()
    expect.eq("b.lua", view.current.path)
    expect.eq("structural", assert(view.file).mode)
    view:prev_file()
    expect.eq("line", assert(view.file).mode)
    for _, f in ipairs(assert(view.file).scene.folds) do
      expect.eq("context", f.kind)
    end
  end)
end)
