local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local gitrepo = require("tests.gitrepo")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local sidebyside = require("nvim-diff.render.sidebyside")
local sidelist = require("nvim-diff.review.sidelist")
local views = require("nvim-diff.views.diff")

local api = vim.api

local NONE = {}

---@param id string
---@param extra? table
---@return NvimDiff.GitHub.Thread
local function T(id, extra)
  local x = vim.tbl_extend("force", {
    id = id,
    path = "a.lua",
    side = "new",
    line = 2,
    resolved = false,
    outdated = false,
    subject = "line",
    comments = {
      { id = id .. "1", author = "alice", body = "about " .. id, created_at = "2026-09-01T12:00:00Z" },
    },
  }, extra or {})
  for k, v in pairs(x) do
    if v == NONE then
      x[k] = nil
    end
  end
  return x
end

---@param buf integer
---@return integer
local function virt_count(buf)
  local n = 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, sidebyside.ns_virt, 0, -1, { details = true })) do
    n = n + #(m[4].virt_lines or {})
  end
  return n
end

describe("review.sidelist", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    gitrepo.cleanup()
    vim.cmd("silent! only")
    vim.cmd("silent! tabonly")
  end)

  it("keeps only the outdated and file-level threads", function()
    local items = sidelist.items({
      T("A"),
      T("O", { outdated = true, line = NONE, original_line = 7 }),
      T("F", { subject = "file", line = NONE, side = NONE }),
    })
    expect.eq(
      { "O:outdated", "F:file" },
      vim.tbl_map(function(i)
        return i.thread.id .. ":" .. i.place
      end, items)
    )
  end)

  it("renders the threads in full, grouped by path, with highlights on the text", function()
    local text = sidelist.render({
      { thread = T("O", { outdated = true, line = NONE, original_line = 7 }), place = "outdated" },
      { thread = T("B", { path = "b.lua", subject = "file", line = NONE }), place = "file" },
      { thread = T("F", { subject = "file", line = NONE }), place = "file" },
    }, 60)
    expect.eq({
      "Outdated and file-level comments · 3",
      "",
      "a.lua",
      "╭─▾ outdated · L7 · 1 comment ──────────────  UNRESOLVED  ─╮",
      "│ alice  2026-09-01                                        │",
      "│   about O                                                │",
      "╰──────────────────────────────────────────────────────────╯",
      "",
      "╭─▾ file comment · 1 comment ───────────────  UNRESOLVED  ─╮",
      "│ alice  2026-09-01                                        │",
      "│   about F                                                │",
      "╰──────────────────────────────────────────────────────────╯",
      "",
      "b.lua",
      "╭─▾ file comment · 1 comment ───────────────  UNRESOLVED  ─╮",
      "│ alice  2026-09-01                                        │",
      "│   about B                                                │",
      "╰──────────────────────────────────────────────────────────╯",
    }, text.lines)
    local m = text.marks[1]
    expect.eq({ 0, 0, #text.lines[1], "NvimDiffPanelTitle" }, { m.row, m.col, m.end_col, m.group })
    expect.eq({ "None." }, { vim.trim(sidelist.render({}, 60).lines[3]) })
  end)

  it("opens as a split beside a window, read-only, and q closes it", function()
    local win = api.nvim_get_current_win()
    local list = sidelist.open({ items = sidelist.items({ T("F", { subject = "file", line = NONE }) }), win = win })
    expect.truthy(list:is_open())
    expect.eq(win, api.nvim_get_current_win(), "the cursor stays")
    expect.eq(50, api.nvim_win_get_width(list.win))
    expect.eq(false, vim.bo[list.buf].modifiable)
    expect.eq("file comment", api.nvim_buf_get_lines(list.buf, 3, 4, false)[1]:match("file comment"))
    api.nvim_set_current_win(list.win)
    vim.cmd("normal q")
    expect.falsy(list:is_open())
  end)

  it("knows which thread each of its lines draws", function()
    local win = api.nvim_get_current_win()
    local f = T("F", { subject = "file", line = NONE })
    local o = T("O", { outdated = true, line = NONE, path = "b.lua" })
    local list = sidelist.open({ items = sidelist.items({ f, o }), win = win })
    api.nvim_set_current_win(list.win)
    local seen = {}
    for lnum = 1, api.nvim_buf_line_count(list.buf) do
      api.nvim_win_set_cursor(list.win, { lnum, 0 })
      local th = list:thread_at_cursor()
      seen[#seen + 1] = th and th.id or "-"
    end
    -- Title, blank, a.lua, F's lines, blank, b.lua, O's lines.
    expect.eq("-", seen[1])
    expect.eq("-", seen[3])
    expect.eq("F", seen[4])
    expect.truthy(vim.tbl_contains(seen, "O"))
    expect.eq("O", seen[#seen])
    list:close()
  end)

  it("shows a PR's threads through the diff view, and keeps expansion across files", function()
    local r = gitrepo.new()
    r:write("a.lua", "a\nb\nc\n")
    r:write("b.lua", "x\ny\n")
    local base = r:commit("base")
    r:write("a.lua", "a\nB\nc\n")
    r:write("b.lua", "x\nY\n")
    local view = views.open({
      repo = assert(repo_mod.discover(r.root)),
      left = rev.commit(base, "main"),
      right = rev.worktree(),
    })
    local function find(p)
      for _, e in ipairs(view.list.entries) do
        if e.path == p then
          return e
        end
      end
      error(p)
    end
    view:select(find("a.lua"))
    view:set_threads({
      T("A"),
      T("O", { outdated = true, line = NONE, original_line = 9 }),
      T("X", { line = 50 }),
      T("B", { path = "b.lua", side = "old" }),
    })
    local tv = assert(view.thread_view)
    expect.eq(1, virt_count(view.file.scene.bufs.new), "A shows at once on the diff showing")
    tv:expand("A")
    expect.eq(4, virt_count(view.file.scene.bufs.new))

    view:toggle_thread_list()
    local list = assert(view.thread_list)
    local lines = api.nvim_buf_get_lines(list.buf, 0, -1, false)
    expect.eq("Outdated and file-level comments · 2", lines[1])
    local function has(prefix)
      for _, l in ipairs(lines) do
        if vim.startswith(l, prefix) then
          return true
        end
      end
      return false
    end
    expect.truthy(has("╭─▾ outdated · L9 · 1 comment ─"))
    expect.truthy(has("╭─▾ not in this diff · L50 "))

    view:select(find("b.lua"))
    expect.eq(1, virt_count(view.file.scene.bufs.old), "B on the old side of b.lua")
    expect.eq("Outdated and file-level comments · 1", api.nvim_buf_get_lines(list.buf, 0, 1, false)[1])
    view:select(find("a.lua"))
    expect.eq(4, virt_count(view.file.scene.bufs.new), "A is still expanded")

    -- The list key toggles it; the view closes it with itself.
    local keys = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(view.file.scene.bufs.new, "n")) do
      keys[m.lhs] = true
    end
    expect.truthy(keys.gC and keys["]t"] and keys["[t"] and keys.gR and keys["<CR>"])
    view:close()
    expect.falsy(list:is_open())
  end)
end)
