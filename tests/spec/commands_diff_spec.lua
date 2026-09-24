local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local commands = require("nvim-diff.commands.diff")
local config = require("nvim-diff.config")
local gitrepo = require("tests.gitrepo")
local repo_mod = require("nvim-diff.git.repo")
local views = require("nvim-diff.views.diff")

local api = vim.api

--- `main` and `feature` forked from `base`:
--- feature changes f.txt and adds g.txt; main then changes m.txt. The worktree is on main.
---@return Test.Repo repo
---@return { base: string, main: string, feature: string } oids
local function fixture()
  local r = gitrepo.new()
  r:write("f.txt", "f\n")
  r:write("m.txt", "m\n")
  local base = r:commit("base")
  r:git({ "checkout", "-q", "-b", "feature" })
  r:write("f.txt", "f\nfeature\n")
  r:write("g.txt", "g\n")
  local feature = r:commit("feature")
  r:git({ "checkout", "-q", "main" })
  r:write("m.txt", "m\nmain\n")
  local main = r:commit("main")
  return r, { base = base, main = main, feature = feature }
end

---@param view NvimDiff.DiffView
---@return string[]
local function paths(view)
  return vim.tbl_map(function(e)
    return e.path
  end, view.list.entries)
end

describe("commands.diff parse", function()
  it("reads revisions, flags and paths", function()
    expect.eq({}, commands.parse({}))
    expect.eq({ range = "main" }, commands.parse({ "main" }))
    expect.eq({ range = "main...feature" }, commands.parse({ "main...feature" }))
    expect.eq({ range = { "main", "feature" } }, commands.parse({ "main", "feature" }))
    expect.eq({ cached = true }, commands.parse({ "--staged" }))
    expect.eq(
      { range = "main", cached = true, imply_local = true, paths = { "a b", "--cached" } },
      commands.parse({ "--cached", "main", "--imply-local", "--", "a b", "--cached" })
    )
  end)

  it("refuses unknown options and a third revision", function()
    local opts, err = commands.parse({ "--nope" })
    expect.eq(nil, opts)
    expect.matches("unknown option %-%-nope", err)
    opts, err = commands.parse({ "a", "b", "c" })
    expect.eq(nil, opts)
    expect.matches("at most two revisions", err)
  end)
end)

describe("commands.diff resolve", function()
  local r, oids, repo

  before_each(function()
    r, oids = fixture()
    repo = assert(repo_mod.discover(r.root))
  end)

  after_each(function()
    config.reset()
    gitrepo.cleanup()
  end)

  ---@param opts NvimDiff.OpenOpts
  local function sides(opts)
    local res, err = commands.resolve(repo, opts)
    assert(res, err)
    local function show(rv)
      return rv.type == "commit" and rv.oid or rv.type
    end
    return { show(res.left), show(res.right), res.range and res.range.spec.mode or false }
  end

  it("defaults to HEAD against the worktree, or the index with --cached", function()
    expect.eq({ oids.main, "worktree", false }, sides({}))
    expect.eq({ oids.main, "index", false }, sides({ cached = true }))
    expect.eq({ oids.feature, "worktree", false }, sides({ range = "feature" }))
    expect.eq({ oids.feature, "index", false }, sides({ range = "feature", cached = true }))
  end)

  it("diffs a branch from the merge-base, or tip to tip when asked", function()
    expect.eq({ oids.base, oids.feature, "merge_base" }, sides({ range = "main...feature" }))
    expect.eq({ oids.main, oids.feature, "tip" }, sides({ range = "main..feature" }))
    expect.eq({ oids.base, oids.feature, "merge_base" }, sides({ range = { "main", "feature" } }))
    config.setup({ revs = { merge_base = false } })
    expect.eq({ oids.main, oids.feature, "tip" }, sides({ range = { "main", "feature" } }))
  end)

  it("swaps a right side at HEAD for the worktree with imply_local", function()
    expect.eq({ oids.base, oids.main, "merge_base" }, sides({ range = "feature...main" }))
    expect.eq({ oids.base, "worktree", "merge_base" }, sides({ range = "feature...main", imply_local = true }))
  end)

  it("uses the empty tree for HEAD on an unborn branch", function()
    local fresh = gitrepo.new()
    fresh:write("a.txt", "a\n")
    local frepo = assert(repo_mod.discover(fresh.root))
    local res = assert(commands.resolve(frepo, {}))
    expect.eq(assert(repo_mod.empty_tree(frepo)), res.left.oid)
    expect.eq("HEAD (unborn)", res.left.label)
  end)

  it("says why a request cannot be resolved", function()
    local res, err = commands.resolve(repo, { range = "nope" })
    expect.eq(nil, res)
    expect.matches('"nope" does not name a commit', err)
    res, err = commands.resolve(repo, { range = "main...feature", cached = true })
    expect.eq(nil, res)
    expect.matches("%-%-cached", err)
  end)
end)

describe("commands.diff open", function()
  ---@type NvimDiff.DiffView?
  local view
  local r, oids
  local cwd

  before_each(function()
    r, oids = fixture()
    cwd = vim.uv.cwd()
    vim.cmd.cd(r.root)
  end)

  after_each(function()
    if view then
      view:close()
      view = nil
    end
    vim.cmd.cd(cwd)
    config.reset()
    gitrepo.cleanup()
  end)

  it("opens a branch diff from the merge-base, titled as typed", function()
    view = assert(commands.open({ range = "main...feature" }))
    expect.eq("main...feature", view.title)
    expect.eq("main...feature", api.nvim_buf_get_lines(view.panel.buf, 0, 1, false)[1])
    expect.eq({ "f.txt", "g.txt" }, paths(view))
    expect.eq(oids.base, view.left.oid)
    expect.eq(view, views.get())
  end)

  it("flips to tip-to-tip and back with the range key, keeping untouched files", function()
    view = assert(commands.open({ range = "main...feature" }))
    local g = view.list.entries[2]
    view:select(g)
    local file = view.file

    -- The key is mapped in the panel and in the diff's buffers.
    for _, buf in ipairs({ view.panel.buf, file:bufs()[1] }) do
      expect.truthy(api.nvim_buf_call(buf, function()
        return vim.fn.maparg("gm", "n") ~= ""
      end))
    end

    api.nvim_set_current_win(view.panel.win)
    vim.cmd("normal gm")
    expect.eq("main..feature", view.title)
    expect.eq(oids.main, view.left.oid)
    expect.eq({ "f.txt", "g.txt", "m.txt" }, paths(view))
    -- g.txt is the same under both: same entry, same open diff.
    expect.eq(g, view.list.entries[2])
    expect.eq(file, view.file)

    expect.eq(true, view:toggle_range())
    expect.eq("main...feature", view.title)
    expect.eq({ "f.txt", "g.txt" }, paths(view))
  end)

  it("has nothing to flip for a diff against the worktree", function()
    config.setup({ log = { level = "error" } }) -- the warning, not the test output
    view = assert(commands.open())
    expect.eq("HEAD → worktree", view.title)
    expect.eq(false, view:toggle_range())
  end)

  it("limits the listing to paths relative to the cwd, and keeps the limit on refresh", function()
    r:write("sub/s.txt", "s\n")
    r:write("m.txt", "m\nmain\nmore\n")
    vim.cmd.cd("sub")
    view = assert(commands.open({ paths = { "." } }))
    expect.eq({ "sub/s.txt" }, paths(view))
    r:write("sub/t.txt", "t\n")
    view:refresh()
    expect.eq({ "sub/s.txt", "sub/t.txt" }, paths(view))

    local none, err = commands.open({ paths = { "/" } })
    expect.eq(nil, none)
    expect.matches("outside the repository", err)
  end)

  it("says why when the cwd is not in a repository", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.cmd.cd(outside)
    local none, err = commands.open()
    vim.fn.delete(outside, "rf")
    expect.eq(nil, none)
    expect.matches("not inside a git work tree", err)
  end)

  it("re-lists a worktree diff when its tabpage is entered again", function()
    view = assert(commands.open())
    expect.eq({}, paths(view))
    expect.truthy(view.augroup)
    vim.cmd("tabnew")
    local other = api.nvim_get_current_tabpage()
    r:write("f.txt", "changed\n")
    api.nvim_set_current_tabpage(view.tab)
    vim.wait(1000, function()
      return #view.list.entries > 0
    end)
    expect.eq({ "f.txt" }, paths(view))
    vim.cmd("tabclose " .. api.nvim_tabpage_get_number(other))
  end)

  it("does not watch a diff of two commits", function()
    view = assert(commands.open({ range = "main..feature" }))
    expect.eq(nil, view.augroup)
  end)

  it("closes the view in the current tabpage", function()
    config.setup({ log = { level = "error" } })
    local tabs = #api.nvim_list_tabpages()
    view = assert(commands.open())
    expect.eq(true, commands.close())
    expect.eq(nil, views.get())
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.eq(false, commands.close())
    view = nil
  end)

  it("completes flags, refs after a range operator, and paths after --", function()
    expect.eq({ "--cached" }, commands.complete("--c", "NvimDiffOpen --c"))
    expect.eq({ "main...feature" }, commands.complete("main...fe", "NvimDiffOpen main...fe"))
    expect.eq({ "main..main" }, commands.complete("main..ma", "NvimDiffOpen main..ma"))
    expect.eq({ "HEAD", "feature", "main" }, commands.complete("", "NvimDiffOpen "))
    expect.eq({ "f.txt" }, commands.complete("f", "NvimDiffOpen main -- f"))
  end)
end)

describe("commands.diff user commands", function()
  local r, cwd
  local notified

  before_each(function()
    r = fixture()
    cwd = vim.uv.cwd()
    vim.cmd.cd(r.root)
    vim.g.loaded_nvim_diff = nil
    vim.cmd.runtime("plugin/nvim-diff.lua")
    notified = {}
    local notify = vim.notify
    vim.notify = function(msg, level) -- luacheck: ignore 122
      notified[#notified + 1] = { msg, level }
    end
    notified.restore = function()
      vim.notify = notify -- luacheck: ignore 122
    end
  end)

  after_each(function()
    notified.restore()
    local view = views.get()
    if view then
      view:close()
    end
    vim.cmd.cd(cwd)
    gitrepo.cleanup()
  end)

  it(":NvimDiffOpen opens a view and :NvimDiffClose closes it", function()
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("NvimDiffOpen main feature")
    local view = assert(views.get())
    expect.eq("main...feature", view.title)
    vim.cmd("NvimDiffClose")
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.eq({}, { unpack(notified) })
  end)

  it(":NvimDiffOpen reports a bad revision as an error and opens nothing", function()
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("NvimDiffOpen nope")
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.eq(1, #notified)
    expect.matches('^nvim%-diff: "nope" does not name a commit', notified[1][1])
    expect.eq(vim.log.levels.ERROR, notified[1][2])
  end)
end)
