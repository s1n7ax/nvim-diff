local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")
local gitrepo = require("tests.gitrepo")
local path = require("nvim-diff.core.path")
local prremote = require("tests.prremote")
local repo_mod = require("nvim-diff.git.repo")
local review_mod = require("nvim-diff.views.review")
local views = require("nvim-diff.views.diff")
local worktree = require("nvim-diff.git.worktree")

local api = vim.api

---@param body string A JSON object on one line, with no single quote in it.
---@return string
local function reply(body)
  return ("    printf 'HTTP/2.0 200 OK\\n\\n%%s\\n' '%s'\n    exit 0\n    ;;\n"):format(body)
end

--- A `gh` that knows PR #7 of `fixture`, with a.txt viewed, b.txt re-changed (DISMISSED)
--- and c.txt unviewed, and accepts every viewed mutation.
---@param fixture Test.PRRemote
---@param opts? { fail_mark?: boolean, fail_pr?: boolean }
---@return string bin
---@return fun(): string[] calls
local function stub(fixture, opts)
  opts = opts or {}
  local pr = vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          id = "PR_kwDO7",
          number = 7,
          title = "Change things",
          url = "https://github.com/octocat/hello-world/pull/7",
          state = "OPEN",
          isDraft = false,
          isCrossRepository = false,
          maintainerCanModify = false,
          headRefName = "feature",
          headRefOid = fixture.head,
          baseRefName = "main",
          baseRefOid = fixture.base,
        },
      },
    },
  })
  local files = vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          files = {
            pageInfo = { hasNextPage = false },
            nodes = {
              { path = "a.txt", viewerViewedState = "VIEWED" },
              { path = "b.txt", viewerViewedState = "DISMISSED" },
              { path = "c.txt", viewerViewedState = "UNVIEWED" },
            },
          },
        },
      },
    },
  })
  local ok_body = '{"data":{"x":{"clientMutationId":null}}}'
  local refused = '{"data":null,"errors":[{"message":"refused"}]}'
  return ghstub.new(table.concat({
    "  *markFileAsViewed*)",
    reply(opts.fail_mark and refused or ok_body),
    "  *viewerViewedState*)",
    reply(files),
    "  *headRefOid*)",
    reply(
      opts.fail_pr and '{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","message":"gone"}]}'
        or pr
    ),
  }, "\n"))
end

---@param review NvimDiff.Review
---@param p string
---@return NvimDiff.FileEntry
local function find(review, p)
  for _, e in ipairs(review.view.list.entries) do
    if e.path == p then
      return e
    end
  end
  error("no entry " .. p)
end

---@param review NvimDiff.Review
---@return table<string, NvimDiff.Viewed?>
local function states(review)
  local out = {}
  for _, e in ipairs(review.view.list.entries) do
    out[e.path] = e.viewed
  end
  return out
end

---@param buf integer
---@return table<string, boolean> descs
local function descs(buf)
  local out = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc then
      out[map.desc] = true
    end
  end
  return out
end

local MARK_DESC = "nvim-diff: mark the file viewed on GitHub and jump to the next unviewed file"

describe("views review", function()
  local home_tab

  before_each(function()
    config.reset()
    home_tab = api.nvim_get_current_tabpage()
  end)

  after_each(function()
    local review = review_mod.get(api.nvim_get_current_tabpage())
    for _, tab in ipairs(api.nvim_list_tabpages()) do
      local r = review_mod.get(tab)
      if r then
        r:close()
      end
    end
    if review then
      review:close()
    end
    if api.nvim_tabpage_is_valid(home_tab) then
      api.nvim_set_current_tabpage(home_tab)
    end
    vim.cmd("silent! tabonly")
    config.reset()
    ghstub.cleanup()
    prremote.cleanup()
    gitrepo.cleanup()
  end)

  ---@param opts? { fail_mark?: boolean, fail_pr?: boolean }
  ---@return Test.PRRemote fixture
  ---@return NvimDiff.Git.Repo repo
  ---@return fun(): string[] calls
  local function setup(opts)
    local fixture = prremote.new()
    local bin, calls = stub(fixture, opts)
    -- The refused mark and "all files viewed" are logged; keep them out of the test output.
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    return fixture, assert(repo_mod.discover(fixture.repo.root)), calls
  end

  it("checks the PR out into its worktree and diffs merge-base to head in its own tab", function()
    local fixture, repo = setup()
    local branch = fixture.repo:git({ "branch", "--show-current" })
    local refs = fixture.repo:git({ "for-each-ref" })
    fixture.repo:write("a.txt", "uncommitted\n")

    local review = review_mod.open({ number = 7, repo = repo })
    local view = review.view
    expect.ne(home_tab, view.tab)
    expect.eq(view.tab, api.nvim_get_current_tabpage())
    expect.eq(review, review_mod.get())
    expect.eq(view, views.get())

    local wt = worktree.path(repo, 7)
    expect.eq(wt, review.path)
    expect.eq(path.real(wt), path.real(vim.fn.getcwd(-1, 0)), "the tab's cwd is the worktree")
    expect.ne(path.real(wt), path.real(vim.fn.getcwd(-1, api.nvim_tabpage_get_number(home_tab))))
    expect.eq("new\n", table.concat(vim.fn.readfile(wt .. "/b.txt"), "\n") .. "\n")

    -- merge-base(base, head) is the fork point, so main's z.txt stays out of the diff.
    expect.eq(fixture.fork_point, view.left.oid)
    expect.eq(fixture.head, view.right.oid)
    expect.eq(
      { "a.txt", "b.txt", "c.txt" },
      vim.tbl_map(function(e)
        return e.path
      end, view.tree.order)
    )

    -- The user's branch, refs and uncommitted change are untouched.
    expect.eq(branch, fixture.repo:git({ "branch", "--show-current" }))
    expect.eq(refs, fixture.repo:git({ "for-each-ref" }))
    expect.eq("uncommitted\n", table.concat(vim.fn.readfile(fixture.repo.root .. "/a.txt"), "\n") .. "\n")
  end)

  it("shows GitHub's viewed state in the panel and opens the first file not viewed", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    expect.eq({ ["a.txt"] = "viewed", ["b.txt"] = "rechanged", ["c.txt"] = "unviewed" }, states(review))
    local lines = api.nvim_buf_get_lines(review.view.panel.buf, 0, -1, false)
    expect.matches("#7 Change things", lines[1])
    expect.matches("1/3 viewed", lines[2])
    local text = table.concat(lines, "\n")
    expect.matches("✓ A?M? ?a%.txt", text:gsub("%s+", " "))
    expect.truthy(text:find("↻", 1, true), "the re-changed file carries its mark")
    expect.eq(find(review, "b.txt"), review.view.current)
    expect.eq(review.view.panel.win, api.nvim_get_current_win(), "focus stays in the panel")
  end)

  it("marks a file viewed on GitHub and jumps to the next unviewed file", function()
    local _, repo, calls = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    local b, c = find(review, "b.txt"), find(review, "c.txt")

    expect.eq(true, review:mark_viewed())
    local sent = calls()[#calls()]
    expect.matches("markFileAsViewed", sent)
    expect.matches("%-f id=PR_kwDO7", sent)
    expect.matches("%-f path=b%.txt", sent)
    expect.eq("viewed", b.viewed)
    expect.eq(c, review.view.current)
    expect.matches("2/3 viewed", api.nvim_buf_get_lines(review.view.panel.buf, 1, 2, false)[1])

    -- The last one: nothing is left to jump to, so the current file stays.
    expect.eq(true, review:mark_viewed())
    expect.eq("viewed", c.viewed)
    expect.eq(c, review.view.current)
    expect.matches("3/3 viewed", api.nvim_buf_get_lines(review.view.panel.buf, 1, 2, false)[1])

    -- Unmarking the file under the panel's cursor, not the one showing.
    local a = find(review, "a.txt")
    api.nvim_set_current_win(review.view.panel.win)
    review.view.panel:set_cursor(assert(review.view.panel:line_of(a)))
    expect.eq(true, review:unmark_viewed())
    expect.matches("unmarkFileAsViewed", calls()[#calls()])
    expect.matches("%-f path=a%.txt", calls()[#calls()])
    expect.eq("unviewed", a.viewed)
    expect.eq(c, review.view.current, "unmarking does not jump")
  end)

  it("leaves the panel alone when GitHub refuses the mark", function()
    local _, repo = setup({ fail_mark = true })
    local review = review_mod.open({ number = 7, repo = repo })
    local b = find(review, "b.txt")
    expect.eq(false, review:mark_viewed())
    expect.eq("rechanged", b.viewed)
    expect.eq(b, review.view.current)
  end)

  it("maps the review keys in the panel and in every diff pane the view opens", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    expect.truthy(descs(review.view.panel.buf)[MARK_DESC])
    for _, buf in ipairs(review.view.file:bufs()) do
      expect.truthy(descs(buf)[MARK_DESC], "pane buffer " .. buf)
    end
    review.view:next_file()
    for _, buf in ipairs(review.view.file:bufs()) do
      expect.truthy(descs(buf)[MARK_DESC], "pane buffer after stepping " .. buf)
    end
  end)

  it("removes the worktree when the tab is closed with :tabclose", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    local wt = review.path
    expect.truthy(path.exists(wt))
    vim.cmd("tabclose")
    expect.truthy(vim.wait(2000, function()
      return review.closed and not path.exists(wt)
    end, 10))
    expect.falsy(review_mod.get(home_tab))
    local listed = vim.system({ "git", "worktree", "list", "--porcelain" }, { cwd = repo.toplevel }):wait().stdout
    expect.falsy(listed:find(wt, 1, true), "git no longer lists the worktree")
  end)

  it("removes the worktree when the view is closed with :NvimDiffClose", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    local wt = review.path
    local tabs = #api.nvim_list_tabpages()
    require("nvim-diff.commands.diff").close()
    expect.truthy(vim.wait(2000, function()
      return review.closed and not path.exists(wt)
    end, 10))
    expect.eq(tabs - 1, #api.nvim_list_tabpages())
  end)

  it("wipes buffers on the worktree's files when the review ends", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    -- Relative to the tab's cwd, which is the worktree.
    local buf = vim.fn.bufadd("b.txt")
    vim.fn.bufload(buf)
    expect.eq(path.real(review.path .. "/b.txt"), path.real(api.nvim_buf_get_name(buf)))
    review:close()
    expect.falsy(api.nvim_buf_is_valid(buf))
    expect.falsy(path.exists(review.path))
  end)

  it("enters the open review instead of checking the PR out twice", function()
    local _, repo = setup()
    local review = review_mod.open({ number = 7, repo = repo })
    api.nvim_set_current_tabpage(home_tab)
    expect.eq(review, review_mod.open({ number = 7, repo = repo }))
    expect.eq(review.view.tab, api.nvim_get_current_tabpage())
  end)

  it("raises without leaving a tab or a worktree behind when the PR cannot be fetched", function()
    local _, repo = setup({ fail_pr = true })
    local tabs = #api.nvim_list_tabpages()
    expect.errors(function()
      review_mod.open({ number = 7, repo = repo })
    end, "cannot fetch PR #7")
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.falsy(path.exists(worktree.path(repo, 7)))
  end)

  it("rejects something that is not a PR number", function()
    expect.errors(function()
      review_mod.open({ number = 0 })
    end, "not a PR number")
  end)
end)
