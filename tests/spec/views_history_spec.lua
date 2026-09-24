local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local event = require("nvim-diff.core.event")
local gitrepo = require("tests.gitrepo")
local history = require("nvim-diff.views.history")
local panel_mod = require("nvim-diff.ui.panel")
local repo_mod = require("nvim-diff.git.repo")

local api = vim.api

--- first: f.txt, d/x; second: f.txt edited, d/y added; rename: f.txt -> g.txt;
--- side (branch): g.txt edited; main2: d/x edited; then a merge of side.
---@return Test.Repo
local function fixture()
  local r = gitrepo.new()
  r:write("f.txt", "a\nb\n")
  r:write("d/x", "x\n")
  r:commit("first")
  r:write("f.txt", "a\nB\n")
  r:write("d/y", "y\n")
  r:commit("second")
  r:git({ "mv", "f.txt", "g.txt" })
  r:commit("rename")
  r:git({ "checkout", "-q", "-b", "side" })
  r:write("g.txt", "a\nB\ns\n")
  r:commit("side")
  r:git({ "checkout", "-q", "main" })
  r:write("d/x", "m\n")
  r:commit("main2")
  r:git({ "merge", "-q", "--no-edit", "side" })
  return r
end

---@param view NvimDiff.HistoryView
---@return string[]
local function panel_lines(view)
  return api.nvim_buf_get_lines(view.panel.buf, 0, -1, false)
end

--- Wait for the walk to end and the panel to catch up.
---@param view NvimDiff.HistoryView
local function settle(view)
  expect.truthy(vim.wait(5000, function()
    return view.state ~= "loading" and not view.redraw_pending
  end, 5))
end

--- `<id> <date> <subject> (nvim-diff)` for the commit `spec` names.
---@param r Test.Repo
---@param spec string
---@param subject string
---@return string
local function commit_text(r, spec, subject)
  local time = tonumber(vim.trim(r:git({ "log", "-1", "--format=%at", spec })))
  return ("%s %s %s (nvim-diff)"):format(r:oid(spec):sub(1, 7), os.date("%Y-%m-%d", time), subject)
end

---@param view NvimDiff.HistoryView
---@return string[] old
---@return string[] new
local function sides(view)
  local scene = assert(view.file).scene
  return api.nvim_buf_get_lines(scene.bufs.old, 0, -1, false), api.nvim_buf_get_lines(scene.bufs.new, 0, -1, false)
end

describe("views.history", function()
  ---@type NvimDiff.HistoryView?
  local view
  ---@type Test.Repo
  local r

  ---@param opts? table
  ---@return NvimDiff.HistoryView
  local function open(opts)
    local repo = assert(repo_mod.discover(r.root))
    view = history.open(vim.tbl_extend("force", { repo = repo }, opts or {}))
    return view
  end

  before_each(function()
    config.setup({})
    r = fixture()
  end)

  after_each(function()
    if view then
      view:close()
      view = nil
    end
    config.reset()
    gitrepo.cleanup()
  end)

  it("lists a file's commits across a rename, marking where the trail crossed it", function()
    open({ path = "g.txt" })
    expect.eq({ "History: g.txt", "0 commits  loading…" }, panel_lines(view))
    settle(view)
    expect.eq({
      "History: g.txt",
      "5 commits",
      "M " .. commit_text(r, "HEAD", "Merge branch 'side'") .. " +1 -0",
      "M " .. commit_text(r, "side", "side") .. " +1 -0",
      "R " .. commit_text(r, "HEAD~2", "rename") .. " +0 -0",
      "  ⤷ renamed from f.txt",
      "M " .. commit_text(r, "HEAD~3", "second") .. " +1 -1",
      "A " .. commit_text(r, "HEAD~4", "first") .. " +2 -0",
    }, panel_lines(view))
  end)

  it("opens the newest commit's diff against its first parent, above a bottom panel", function()
    open({ path = "g.txt" })
    settle(view)
    local scene = assert(view.file).scene
    -- The merge against main2, where side's line arrives.
    local old, new = sides(view)
    expect.eq({ "── a/g.txt ──", "a", "B" }, vim.list_slice(old, 1, 3))
    expect.eq({ "── b/g.txt ──", "a", "B", "s" }, vim.list_slice(new, 1, 4))
    expect.eq({
      "col",
      { { "row", { { "leaf", scene.wins.old }, { "leaf", scene.wins.new } } }, { "leaf", view.panel.win } },
    }, vim.fn.winlayout())
    expect.eq(16, api.nvim_win_get_height(view.panel.win))
    expect.eq(true, vim.wo[view.panel.win].winfixheight)
    -- The focus stays in the panel, and the panel marks the commit.
    expect.eq(view.panel.win, api.nvim_get_current_win())
    local marks = api.nvim_buf_get_extmarks(view.panel.buf, panel_mod.current_ns, 0, -1, {})
    expect.eq(2, marks[1][2])
  end)

  it("reads the old path on the rename commit's left side, and the empty tree at the root", function()
    open({ path = "g.txt" })
    settle(view)
    view:next_file() -- side
    view:next_file() -- rename
    expect.eq("f.txt", view.current.oldpath)
    local old, new = sides(view)
    expect.eq({ "── a/f.txt ──", "a", "B" }, old)
    expect.eq({ "── b/g.txt ──", "a", "B" }, new)
    view:prev_file()
    view:prev_file()
    view:prev_file() -- wraps to the root commit
    old, new = sides(view)
    expect.eq({ "── a/f.txt ──", "" }, vim.list_slice(old, 1, 2))
    expect.eq({ "── b/f.txt ──", "a", "b" }, vim.list_slice(new, 1, 3))
  end)

  it("stops at the rename when following is off", function()
    config.setup({ history = { follow = false } })
    open({ path = "g.txt" })
    settle(view)
    local lines = panel_lines(view)
    expect.eq("3 commits", lines[2])
    expect.eq("A " .. commit_text(r, "HEAD~2", "rename") .. " +2 -0", lines[5])
    expect.eq(5, #lines)
  end)

  it("folds a directory's commits, unfolding one and opening its first file on select", function()
    open({ path = "d" })
    settle(view)
    expect.eq({
      "History: d/",
      "3 commits",
      "▾ " .. commit_text(r, "HEAD~1", "main2") .. "  1 file +1 -1",
      "    M d/x +1 -1",
      "▸ " .. commit_text(r, "HEAD~3", "second") .. "  1 file +1 -0",
      "▸ " .. commit_text(r, "HEAD~4", "first") .. "  1 file +1 -0",
    }, panel_lines(view))

    -- <CR> on a folded commit: unfold, open its first file, cursor stays on the commit.
    api.nvim_win_set_cursor(view.panel.win, { 5, 0 })
    view:select_cursor()
    expect.eq("d/y", view.current.path)
    expect.eq("    A d/y +1 -0", panel_lines(view)[6])
    expect.eq(5, api.nvim_win_get_cursor(view.panel.win)[1])
    -- <CR> on it again folds it and leaves the diff alone.
    local file = view.file
    view:select_cursor()
    expect.eq(6, #panel_lines(view))
    expect.truthy(view.file == file)

    -- Next file walks into the folded root commit and unfolds it.
    view:next_file()
    view:next_file()
    expect.eq("d/x", view.current.path)
    expect.eq("    A d/x +1 -0", panel_lines(view)[#panel_lines(view)])
  end)

  it("lists the whole repository's history with every file of each commit", function()
    open()
    settle(view)
    local lines = panel_lines(view)
    expect.eq("History: whole repository", lines[1])
    expect.eq("6 commits", lines[2])
    expect.eq("▸ " .. commit_text(r, "HEAD~3", "second") .. "  2 files +2 -1", lines[#lines - 1])
    view:select(view.order[#view.order])
    expect.eq("f.txt", view.current.path)
    expect.eq({ "    A d/x +1 -0", "    A f.txt +2 -0" }, vim.list_slice(panel_lines(view), #lines + 1, #lines + 2))
  end)

  it("answers <CR>, <Tab> and R typed in the panel", function()
    open({ path = "d" })
    settle(view)
    local function feed(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    api.nvim_set_current_win(view.panel.win)
    api.nvim_win_set_cursor(view.panel.win, { 5, 0 })
    feed("<CR>")
    expect.eq("d/y", view.current.path)
    feed("<Tab>")
    expect.eq("d/x", view.current.path)
    expect.eq("A", view.current.change.status)
    feed("R")
    expect.eq("loading", view.state)
    settle(view)
    expect.eq("d/x", view.current.path)
    expect.eq("A", view.current.change.status)
  end)

  it("keeps rows and highlights right while commits stream in and fold, as a full redraw would", function()
    for i = 1, 40 do
      r:write(("d/f%d"):format(i % 7), ("%d\n"):format(i))
      r:commit("c" .. i)
    end
    open()
    -- Fold commits while the history is still arriving.
    local rng = 7
    local function random(n)
      rng = (rng * 1103515245 + 12345) % 2147483648
      return rng % n + 1
    end
    local ops = 0
    while view.state == "loading" or view.redraw_pending or ops < 60 do
      vim.wait(2)
      if view.drawn > 0 then
        local hc = view.commits[random(view.drawn)]
        hc.expanded = not hc.expanded
        view:redraw_commit(hc)
        ops = ops + 1
      end
      if ops > 400 then
        break
      end
    end
    local function snapshot()
      local rows = {}
      for lnum, row in pairs(view.panel.rows) do
        rows[lnum] = row.kind .. ":" .. tostring(row.entry) .. ":" .. tostring(row.commit)
      end
      local marks = vim.tbl_map(function(m)
        return { m[2], m[3], m[4].end_col, m[4].hl_group }
      end, api.nvim_buf_get_extmarks(view.panel.buf, panel_mod.ns, 0, -1, { details = true }))
      return { panel_lines(view), rows, marks }
    end
    local streamed = snapshot()
    view:render()
    local full = snapshot()
    expect.eq(full[1], streamed[1])
    expect.eq(full[2], streamed[2])
    expect.eq(full[3], streamed[3])
  end)

  it("defers a file over the size threshold in a commit until asked", function()
    config.setup({ thresholds = { defer_lines = 20 } })
    r:write("big.txt", string.rep("line\n", 30))
    r:commit("big")
    open({ path = "big.txt" })
    settle(view)
    local entry = view.order[1]
    expect.eq(true, entry.deferred)
    expect.eq(nil, view.file)
    expect.matches(
      "30 lines, over the 20%-line limit",
      table.concat(api.nvim_buf_get_lines(view.note_buf, 0, -1, false))
    )
    api.nvim_win_set_cursor(view.panel.win, { 3, 0 })
    view:select_cursor()
    expect.truthy(view.file)
  end)

  it("refreshes: new commits appear and the showing file is found again", function()
    open({ path = "d" })
    settle(view)
    view:next_file() -- second: d/y
    expect.eq("d/y", view.current.path)
    local file = view.file
    r:write("d/z", "z\n")
    r:commit("third")
    view:refresh()
    settle(view)
    expect.eq("4 commits", panel_lines(view)[2])
    expect.eq("d/y", view.current.path)
    expect.truthy(view.file == file, "the showing diff was replaced")
    local lnum = view.panel:line_of(view.current)
    expect.eq(lnum, api.nvim_win_get_cursor(view.panel.win)[1])
  end)

  it("refuses to open on an unborn branch or a bad revision", function()
    local empty = gitrepo.new()
    local repo = assert(repo_mod.discover(empty.root))
    local tabs = #api.nvim_list_tabpages()
    expect.errors(function()
      history.open({ repo = repo })
    end, "HEAD")
    expect.errors(function()
      history.open({ repo = assert(repo_mod.discover(r.root)), rev = "nope" })
    end, "nope")
    expect.eq(tabs, #api.nvim_list_tabpages())
  end)

  it("starts from another revision when asked, and says so", function()
    open({ path = "g.txt", rev = "side" })
    settle(view)
    local lines = panel_lines(view)
    expect.eq("History: g.txt @ side", lines[1])
    expect.eq("M " .. commit_text(r, "side", "side") .. " +1 -0", lines[3])
  end)

  it("closing stops the walk and removes its tab and buffers", function()
    local tabs = #api.nvim_list_tabpages()
    open()
    local task = view.task
    local panel_buf = view.panel.buf
    view:close()
    view = nil
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.truthy(task:wait(2000))
    expect.truthy(require("nvim-diff.core.job").is_cancelled(task.err))
    expect.falsy(api.nvim_buf_is_valid(panel_buf))
  end)

  it(":NvimDiffHistory opens a file's, a directory's or the repository's history", function()
    vim.cmd("runtime plugin/nvim-diff.lua")
    local opened = {}
    local off = event.on(event.events.VIEW_OPENED, function(v)
      opened[#opened + 1] = v
    end)
    local cwd = vim.uv.cwd()
    vim.cmd.cd(r.root)
    local ok, err = pcall(function()
      vim.cmd("edit g.txt")
      vim.cmd("NvimDiffHistory %")
      expect.eq("file", opened[1].kind)
      expect.eq("g.txt", opened[1].path)
      vim.cmd("NvimDiffHistory d")
      expect.eq("dir", opened[2].kind)
      vim.cmd("NvimDiffHistory")
      expect.eq("repo", opened[3].kind)
    end)
    vim.cmd.cd(cwd)
    off()
    for _, v in ipairs(opened) do
      settle(v)
      v:close()
    end
    vim.cmd("silent! bwipeout! g.txt")
    expect.truthy(ok, err)
  end)
end)
