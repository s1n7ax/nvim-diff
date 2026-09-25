local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local child_mod = require("tests.child")
local config = require("nvim-diff.config")
local fileview = require("nvim-diff.scene.fileview")
local line = require("nvim-diff.diff.line")
local sidebyside = require("nvim-diff.render.sidebyside")
local threadview = require("nvim-diff.review.threadview")

local api = vim.api

---@type NvimDiff.FileView?
local current
---@type NvimDiff.TestChild?
local child

local NONE = {}

--- A thread fixture in `github/threads.lua`'s shape; `NONE` in `extra` removes a field.
---@param id string
---@param extra? table
---@return NvimDiff.GitHub.Thread
local function T(id, extra)
  local x = vim.tbl_extend("force", {
    id = id,
    path = "f.lua",
    side = "new",
    line = 2,
    resolved = false,
    outdated = false,
    subject = "line",
    comments = {
      { id = id .. "c1", author = "alice", body = "why " .. id .. "?", created_at = "2026-09-01T12:00:00Z" },
      { id = id .. "c2", author = "bob", body = "because", created_at = "2026-09-02T08:00:00Z" },
    },
  }, extra or {})
  for k, v in pairs(x) do
    if v == NONE then
      x[k] = nil
    end
  end
  return x
end

--- 30 unchanged lines, one change at line 2 and one at line 28: two hunks with a long
--- folded stretch between them.
local OLD, NEW = {}, {}
for i = 1, 30 do
  OLD[i] = "l" .. i
  NEW[i] = "l" .. i
end
NEW[2] = "L2"
NEW[28] = "L28"

---@param extra? table
---@return NvimDiff.FileView
local function open(extra)
  current = fileview.open(vim.tbl_extend("force", {
    diff = line.diff(OLD, NEW),
    old = { lines = OLD, label = "a/f.lua" },
    new = { lines = NEW, label = "b/f.lua" },
    mode = "line",
  }, extra or {}))
  return current
end

--- Every virtual line of `buf`, as `"<0-based anchor row>:<text>"`.
---@param buf integer
---@return string[]
local function virt(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, sidebyside.ns_virt, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(vl) do
        parts[#parts + 1] = chunk[1]
      end
      out[#out + 1] = m[2] .. ":" .. table.concat(parts)
    end
  end
  return out
end

---@param v NvimDiff.FileView
local function aligned(v)
  local p = v.scene --[[@as NvimDiff.Pair]]
  expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.old, {}).all)
  expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.new, {}).all)
end

describe("review.threadview", function()
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

  it("draws a collapsed thread under its line, the opposite pane blank, not filler", function()
    local v = open()
    threadview.attach(v, { T("A") })
    local p = v.scene --[[@as NvimDiff.Pair]]
    local new = virt(p.bufs.new)
    expect.eq(1, #new)
    -- A 40-column pane: the meta gives way before the excerpt.
    expect.matches("^2:▌ ▸ alice  why A%?  · 1 reply · unreso…$", new[1])
    expect.eq({ "2:" }, virt(p.bufs.old), "blank padding opposite, never ┈")
    aligned(v)
  end)

  it("expands in place from either pane's cursor line, and collapses again", function()
    local v = open()
    local tv = threadview.attach(v, { T("A") })
    local p = v.scene --[[@as NvimDiff.Pair]]
    -- The old pane's line faces the new pane's thread.
    api.nvim_set_current_win(p.wins.old)
    api.nvim_win_set_cursor(p.wins.old, { 3, 0 })
    expect.truthy(tv:toggle_at_cursor())
    expect.eq({
      "2:▌ ▾ L2 · 2 comments · unresolved",
      "2:▌ alice  2026-09-01",
      "2:▌   why A?",
      "2:▌ bob  2026-09-02",
      "2:▌   because",
    }, virt(p.bufs.new))
    expect.eq({ "2:", "2:", "2:", "2:", "2:" }, virt(p.bufs.old))
    aligned(v)
    expect.truthy(tv.state.expanded.A)
    expect.truthy(tv:toggle_at_cursor())
    expect.eq(1, #virt(p.bufs.new))
    api.nvim_win_set_cursor(p.wins.old, { 4, 0 })
    expect.falsy(tv:toggle_at_cursor(), "no thread on this line")
  end)

  it("puts every thread of a row into one block, padded to the taller side", function()
    local v = open()
    local tv = threadview.attach(v, { T("A"), T("B", { side = "old" }), T("C") })
    local p = v.scene --[[@as NvimDiff.Pair]]
    expect.eq(2, #virt(p.bufs.new))
    expect.eq(2, #virt(p.bufs.old))
    expect.matches("why B", virt(p.bufs.old)[1])
    expect.eq("2:", virt(p.bufs.old)[2])
    tv:expand("B")
    -- Old: B expanded (5 rows); new: A and C collapsed (2 rows) and 3 blank.
    expect.eq(5, #virt(p.bufs.old))
    expect.eq(5, #virt(p.bufs.new))
    expect.eq("2:", virt(p.bufs.new)[5])
    aligned(v)
  end)

  it("dims resolved threads by default, hides them on request, and says so in config", function()
    local v = open()
    local tv = threadview.attach(v, { T("A", { resolved = true }) })
    local p = v.scene --[[@as NvimDiff.Pair]]
    expect.matches("· ✓ reso…$", virt(p.bufs.new)[1])
    expect.eq("hide", tv:toggle_resolved())
    expect.eq({}, virt(p.bufs.new))
    expect.eq({}, virt(p.bufs.old))
    expect.falsy(tv:expand("A"), "a hidden thread does not expand")
    expect.eq("dim", tv:toggle_resolved())
    expect.eq(1, #virt(p.bufs.new))
    tv:detach()
    current:close()

    config.setup({ threads = { resolved = "hide" } })
    v = open()
    threadview.attach(v, { T("A", { resolved = true }), T("B", { line = 28 }) })
    expect.eq(1, #virt(v.scene.bufs.new))
  end)

  it("splits a context fold around a thread inside it", function()
    local v = open()
    local p = v.scene --[[@as NvimDiff.Pair]]
    local before = vim.deepcopy(p.folds)
    expect.eq(1, #before)
    threadview.attach(v, { T("A", { line = 15 }) })
    p = v.scene --[[@as NvimDiff.Pair]]
    expect.eq(2, #p.folds)
    local row = v:diff():row_of("new", 15)
    expect.eq(row - 1, p.folds[1].last)
    expect.eq(row + 1, p.folds[2].first)
    expect.eq({ "15:" }, virt(p.bufs.old))
    aligned(v)
    -- Collapsing every fold keeps the thread's line visible.
    p:collapse_all()
    expect.eq(2, #p.folds)
  end)

  it("works in unified, keeps expansion across the toggle, and maps keys in the new buffers", function()
    local v = open()
    local tv = threadview.attach(v, { T("A"), T("B", { side = "old", line = 28 }) })
    tv:expand("A")
    v:toggle()
    local u = v.scene --[[@as NvimDiff.Unified]]
    local lines = virt(u.buf)
    -- A under the new line 2 (after the deleted old line 2), B under the old line 28.
    expect.eq(6, #lines)
    expect.matches("^3:▌ ▾ L2", lines[1])
    expect.matches("^%d+:▌ ▸ alice  why B%?", lines[6])
    local mapped = false
    for _, m in ipairs(api.nvim_buf_get_keymap(u.buf, "n")) do
      mapped = mapped or m.lhs == "]t"
    end
    expect.truthy(mapped, "]t mapped in the unified buffer")
    v:toggle()
    -- A expanded (5 rows), and the blank row facing B.
    expect.eq(6, #virt(v.scene.bufs.new))
    aligned(v)
  end)

  it("jumps between threads, wrapping around", function()
    local v = open()
    local tv = threadview.attach(v, { T("A", { line = 28 }), T("B", { side = "old", line = 2 }) })
    local p = v.scene --[[@as NvimDiff.Pair]]
    api.nvim_set_current_win(p.wins.new)
    api.nvim_win_set_cursor(p.wins.new, { 10, 0 })
    expect.truthy(tv:jump(1))
    expect.eq({ "new", 28 }, { v:cursor().side, v:cursor().lnum })
    expect.truthy(tv:jump(1))
    expect.eq({ "new", 2 }, { v:cursor().side, v:cursor().lnum }, "stays in the new pane, facing B")
    expect.truthy(tv:jump(-1))
    expect.eq({ "new", 28 }, { v:cursor().side, v:cursor().lnum })
    -- A thread on a deleted line, from the new pane: the cursor goes to the old pane.
    tv:set_threads({ T("D", { side = "old", line = 5 }) })
    current:close()
    local old = vim.deepcopy(OLD)
    table.insert(old, 5, "gone")
    v = fileview.open({
      diff = line.diff(old, NEW),
      old = { lines = old, label = "a/f.lua" },
      new = { lines = NEW, label = "b/f.lua" },
      mode = "line",
    })
    current = v
    tv = threadview.attach(v, { T("D", { side = "old", line = 5 }) })
    api.nvim_set_current_win(v.scene.wins.new)
    expect.truthy(tv:jump(1))
    expect.eq(v.scene.wins.old, api.nvim_get_current_win())
    expect.eq({ "old", 5 }, { v:cursor().side, v:cursor().lnum })
  end)

  it("leaves outdated, file-level and off-file threads to the side list", function()
    local v = open()
    local tv = threadview.attach(v, {
      T("A", { outdated = true, line = NONE, original_line = 3 }),
      T("F", { subject = "file", line = NONE, side = NONE }),
      T("X", { line = 99 }),
      T("OK"),
    })
    expect.eq(
      { "A:outdated", "F:file", "X:off_file" },
      vim.tbl_map(function(l)
        return l.thread.id .. ":" .. l.place
      end, tv:unanchored())
    )
    expect.eq(1, #virt(v.scene.bufs.new))
  end)

  it("replaces its threads, and detaches without a trace", function()
    local v = open()
    local tv = threadview.attach(v, { T("A"), T("B", { line = 28 }) })
    tv:set_threads({ T("B", { line = 28 }) })
    expect.eq(
      { "28:" },
      vim.tbl_map(function(s)
        return s:match("^%d+:")
      end, virt(v.scene.bufs.new))
    )
    tv:detach()
    expect.eq({}, virt(v.scene.bufs.new))
    for _, m in ipairs(api.nvim_buf_get_keymap(v.scene.bufs.new, "n")) do
      expect.ne("]t", m.lhs)
    end
    v:toggle()
    expect.eq({}, virt(v.scene.buf), "no block replayed after detach")
  end)

  it("validates its config", function()
    expect.eq({}, config.validate({ threads = { resolved = "hide" }, keymaps = { threads = { list = false } } }))
    expect.matches(
      "`threads%.resolved`: expected one of dim, hide",
      config.validate({ threads = { resolved = "x" } })[1]
    )
    expect.matches("`keymaps%.threads%.toggle`", config.validate({ keymaps = { threads = { toggle = true } } })[1])
    config.setup({ keymaps = { threads = { toggle = false } } })
    local v = open()
    threadview.attach(v, { T("A") })
    for _, m in ipairs(api.nvim_buf_get_keymap(v.scene.bufs.new, "n")) do
      expect.ne("<CR>", m.lhs)
    end
  end)

  it("keeps only its path's threads with for_path", function()
    local list = { T("A"), T("B", { path = "g.lua" }), T("C") }
    expect.eq(
      { "A", "C" },
      vim.tbl_map(function(x)
        return x.id
      end, threadview.for_path(list, "f.lua"))
    )
  end)

  it("expands with the key on screen, side-by-side and unified, the old pane blank", function()
    child = child_mod.spawn()
    child:lua([[
      vim.o.columns = 80
      local old, new = { "a", "b", "c" }, { "a", "B", "c" }
      _G.V = require("nvim-diff.scene.fileview").open({
        diff = require("nvim-diff.diff.line").diff(old, new),
        old = { lines = old, label = "a/f" },
        new = { lines = new, label = "b/f" },
        mode = "line",
      })
      require("nvim-diff.review.threadview").attach(V, { {
        id = "A", path = "f", side = "new", line = 2, resolved = false, outdated = false, subject = "line",
        comments = {
          { id = "1", author = "alice", body = "why?", created_at = "2026-09-01T00:00:00Z" },
          { id = "2", author = "bob", body = "why not", created_at = "2026-09-02T00:00:00Z" },
        },
      } })
      vim.api.nvim_set_current_win(V.scene.wins.old)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
    ]])
    local screen = child:screen(2, 6, 1, 80)
    local right = child:lua("return vim.api.nvim_win_get_position(V.scene.wins.new)[2]")
    local function halves(rows)
      local out = {}
      for i, r in ipairs(rows) do
        local chars = vim.fn.split(r, "\\zs")
        out[i] = {
          vim.trim((table.concat(chars, "", 1, right):gsub("│%s*$", ""))),
          vim.trim(table.concat(chars, "", right + 1)),
        }
      end
      return out
    end
    expect.eq({
      { "── a/f ──", "── b/f ──" },
      { "1 a", "1 a" },
      { "2 b", "2 B" },
      { "", "▌ ▸ alice  why?  · 1 reply · unresolv…" },
      { "3 c", "3 c" },
    }, halves(screen))
    child:input("<CR>")
    expect.eq({
      { "2 b", "2 B" },
      { "", "▌ ▾ L2 · 2 comments · unresolved" },
      { "", "▌ alice  2026-09-01" },
      { "", "▌   why?" },
      { "", "▌ bob  2026-09-02" },
      { "", "▌   why not" },
      { "3 c", "3 c" },
    }, halves(child:screen(4, 10, 1, 80)))
    child:input("g<C-x>")
    local rows = vim.tbl_map(vim.trim, child:screen(2, 10, 1, 40))
    expect.eq({
      "── a/f → b/f ──",
      "1   1   a",
      "2     - b",
      "2 + B",
      "▌ ▾ L2 · 2 comments · unresolved",
      "▌ alice  2026-09-01",
      "▌   why?",
      "▌ bob  2026-09-02",
      "▌   why not",
    }, rows)
  end)
end)
