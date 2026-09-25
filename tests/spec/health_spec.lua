local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local health = require("nvim-diff.health")

--- Capture what `:checkhealth` would print.
---@return table report
local function record()
  local report = { sections = {}, ok = {}, warn = {}, error = {}, info = {}, current = nil }
  local real = vim.health

  ---@param list table[]
  ---@return fun(msg: string, advice?: string[])
  local function collector(list)
    return function(msg, advice)
      local text = advice and (msg .. "\n" .. table.concat(advice, "\n")) or msg
      list[#list + 1] = { report.current, text }
    end
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.health = {
    start = function(name)
      report.sections[#report.sections + 1] = name
      report.current = name
    end,
    ok = collector(report.ok),
    warn = collector(report.warn),
    error = collector(report.error),
    info = collector(report.info),
  }
  report.restore = function()
    vim.health = real
  end
  return report
end

---@param entries table[]
---@param pattern string
---@return boolean
local function has(entries, pattern)
  for _, entry in ipairs(entries) do
    if tostring(entry[2]):find(pattern) then
      return true
    end
  end
  return false
end

describe("health", function()
  local report

  before_each(function()
    config.reset()
    report = record()
  end)

  after_each(function()
    report.restore()
    config.reset()
  end)

  it("reports every section", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.eq(
      { "Neovim", "Configuration", "git", "gh (GitHub PR review)", "treesitter (structural diff)", "PR worktrees" },
      report.sections
    )
  end)

  it("passes the Neovim checks on this version", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.eq({}, report.error)
    expect.truthy(has(report.ok, "`vim%.text%.diff` is available"))
  end)

  it("finds git and reports its version", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.truthy(has(report.ok, "^git %d+%.%d+%.%d+$"), vim.inspect(report.ok))
  end)

  it("errors when git is missing and warns when gh is", function()
    config.setup({
      git = { bin = "nvim-diff-no-such-binary" },
      github = { bin = "nvim-diff-no-such-binary" },
    })
    health.check()
    expect.truthy(has(report.error, "not found on PATH"), "a missing git is fatal")
    expect.truthy(has(report.warn, "PR review is unavailable"), "a missing gh is not")
  end)

  it("probes parsers with get_string_parser and counts them", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.truthy(
      has(report.ok, "probed parsers installed") or has(report.warn, "no parser found"),
      vim.inspect({ report.ok, report.warn })
    )
  end)

  it("reports the configuration it is running on", function()
    config.setup({
      layout = "unified",
      github = { bin = "nvim-diff-no-such-binary" },
      highlights = { NvimDiffAddLine = "DiffAdd" },
    })
    health.check()
    expect.truthy(has(report.ok, "`setup%(%)` has been called"))
    expect.truthy(has(report.info, "layout: unified"))
    expect.truthy(has(report.info, "highlight overrides: NvimDiffAddLine"))
  end)

  it("says so when setup() has not run", function()
    config.reset()
    health.check()
    expect.truthy(has(report.info, "has not been called"))
  end)

  describe("git version", function()
    --- A `git` that only answers `--version`.
    ---@param version string
    ---@return string bin
    local dirs = {}

    after_each(function()
      for _, dir in ipairs(dirs) do
        vim.fn.delete(dir, "rf")
      end
      dirs = {}
    end)

    local function fake_git(version)
      local dir = vim.fn.tempname() .. "-gitstub"
      vim.fn.mkdir(dir, "p")
      dirs[#dirs + 1] = dir
      local bin = dir .. "/git"
      local fd = assert(io.open(bin, "w"))
      fd:write(("#!/bin/sh\nprintf 'git version %s\\n'\n"):format(version))
      fd:close()
      vim.uv.fs_chmod(bin, 448) -- 0700
      return bin
    end

    it("warns, not errors, when git predates --diff-merges=first-parent", function()
      config.setup({ git = { bin = fake_git("2.30.2") }, github = { bin = "nvim-diff-no-such-binary" } })
      health.check()
      expect.truthy(has(report.ok, "^git 2%.30%.2$"), "2.30 is above the 2.25 minimum")
      expect.truthy(has(report.warn, "no `%-%-diff%-merges=first%-parent` %(git 2%.31%)"), vim.inspect(report.warn))
      expect.truthy(has(report.warn, "merge commits"))
      expect.falsy(has(report.error, "git"), vim.inspect(report.error))
    end)

    it("warns below the 2.25 minimum", function()
      config.setup({ git = { bin = fake_git("2.20.1") }, github = { bin = "nvim-diff-no-such-binary" } })
      health.check()
      expect.truthy(has(report.warn, "git 2%.20%.1 is older than the supported 2%.25"), vim.inspect(report.warn))
    end)

    it("says nothing about merges from 2.31 on", function()
      config.setup({ git = { bin = fake_git("2.31.0") }, github = { bin = "nvim-diff-no-such-binary" } })
      health.check()
      expect.falsy(has(report.warn, "diff%-merges"), vim.inspect(report.warn))
    end)
  end)

  describe("gh", function()
    local ghstub = require("tests.ghstub")
    local gitrepo = require("tests.gitrepo")
    local cwd, gh_host

    --- A `gh` authenticated to github.com, with a rejected token for `stale.example`.
    ---@return string bin
    local function stub()
      return ghstub.new([[
  *"--version"*)
    printf 'gh version 2.101.0 (test)\n'
    exit 0
    ;;
  *"auth status --json hosts"*)
    printf '%s' '{"hosts":{
      "github.com":[{"state":"success","active":true,"host":"github.com","login":"octocat"}],
      "stale.example":[{"state":"error","active":true,"host":"stale.example","login":"old"}]
    }}'
    exit 0
    ;;
]])
    end

    --- chdir into a repository whose `origin` is `url`.
    ---@param url string
    local function enter_repo(url)
      local repo = gitrepo.new()
      repo:git({ "remote", "add", "origin", url })
      vim.uv.chdir(repo.root)
    end

    before_each(function()
      cwd = vim.uv.cwd()
      gh_host = vim.env.GH_HOST
      vim.env.GH_HOST = nil
    end)

    after_each(function()
      vim.uv.chdir(cwd)
      vim.env.GH_HOST = gh_host
      ghstub.cleanup()
      gitrepo.cleanup()
    end)

    it("names authenticated hosts with their login and warns about a rejected token", function()
      config.setup({ github = { bin = stub() } })
      health.check()
      expect.truthy(has(report.ok, "authenticated to github%.com %(octocat%)"), vim.inspect(report.ok))
      expect.truthy(has(report.warn, "token for stale%.example, but GitHub rejects it"), vim.inspect(report.warn))
      expect.truthy(has(report.warn, "gh auth refresh %-%-hostname stale%.example"))
    end)

    it("warns when the repository's GitHub Enterprise host is not authenticated", function()
      enter_repo("git@ghe.corp.example:acme/widgets.git")
      config.setup({ github = { bin = stub() } })
      health.check()
      expect.truthy(has(report.warn, "`gh` is not authenticated to ghe%.corp%.example"), vim.inspect(report.warn))
      expect.truthy(has(report.warn, "acme/widgets on ghe%.corp%.example %(host from the `origin` remote%)"))
      expect.truthy(has(report.warn, "gh auth login %-%-hostname ghe%.corp%.example"))
    end)

    it("checks the configured github.host rather than the remote's", function()
      enter_repo("git@git-internal.corp:acme/widgets.git")
      config.setup({ github = { bin = stub(), host = "github.com" } })
      health.check()
      expect.truthy(
        has(report.ok, "reviews acme/widgets on github%.com %(host from `github%.host`%)"),
        vim.inspect(report.ok)
      )
    end)

    it("honours $GH_HOST like gh does", function()
      enter_repo("https://github.com/acme/widgets.git")
      vim.env.GH_HOST = "stale.example"
      config.setup({ github = { bin = stub() } })
      health.check()
      expect.truthy(has(report.warn, "not authenticated to stale%.example"), vim.inspect(report.warn))
      expect.truthy(has(report.warn, "host from `%$GH_HOST`"))
    end)

    it("says so plainly when the repository has no origin remote", function()
      local repo = gitrepo.new()
      vim.uv.chdir(repo.root)
      config.setup({ github = { bin = stub() } })
      health.check()
      expect.truthy(has(report.info, "no PR host to check for the cwd: the repository has no `origin` remote"))
    end)

    it("says why there is no host to check outside a repository", function()
      vim.uv.chdir(vim.fs.normalize(vim.env.TMPDIR or "/tmp"))
      config.setup({ github = { bin = stub() } })
      health.check()
      expect.truthy(has(report.info, "no PR host to check for the cwd: not inside a git repository"))
    end)
  end)

  describe("orphan worktrees", function()
    it("returns a list in a repository and an explanation outside one", function()
      local paths, err = health.orphan_worktrees()
      expect.falsy(err, tostring(err))
      expect.eq("table", type(paths))

      local cwd = vim.uv.cwd()
      vim.uv.chdir(vim.fs.normalize(vim.env.TMPDIR or "/tmp"))
      local outside, outside_err = health.orphan_worktrees()
      vim.uv.chdir(cwd)
      expect.eq({}, outside)
      expect.matches("not inside a git repository", tostring(outside_err))
    end)

    it("reports nothing when git itself is unavailable", function()
      config.setup({ git = { bin = "nvim-diff-no-such-binary" } })
      local paths, err = health.orphan_worktrees()
      expect.eq({}, paths)
      expect.matches("git is unavailable", tostring(err))
    end)
  end)
end)
