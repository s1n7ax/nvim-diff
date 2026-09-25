local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local config = require("nvim-diff.config")
local errors = require("nvim-diff.github.error")
local gitrepo = require("tests.gitrepo")
local host = require("nvim-diff.github.host")
local repo_mod = require("nvim-diff.git.repo")

describe("github host", function()
  after_each(function()
    config.reset()
    gitrepo.cleanup()
    vim.env.GH_HOST = nil
  end)

  describe("parse_remote", function()
    local cases = {
      {
        url = "https://github.com/octocat/hello-world.git",
        host = "github.com",
        owner = "octocat",
        repo = "hello-world",
      },
      { url = "https://github.com/octocat/hello-world", host = "github.com", owner = "octocat", repo = "hello-world" },
      { url = "git@github.com:octocat/hello-world.git", host = "github.com", owner = "octocat", repo = "hello-world" },
      { url = "github.com:octocat/hello-world.git", host = "github.com", owner = "octocat", repo = "hello-world" },
      {
        url = "ssh://git@github.com/octocat/hello-world.git",
        host = "github.com",
        owner = "octocat",
        repo = "hello-world",
      },
      {
        url = "ssh://git@ghe.corp.example:2222/octocat/hello-world.git",
        host = "ghe.corp.example",
        owner = "octocat",
        repo = "hello-world",
      },
      {
        url = "https://ghe.corp.example/octocat/hello-world/",
        host = "ghe.corp.example",
        owner = "octocat",
        repo = "hello-world",
      },
    }
    for _, case in ipairs(cases) do
      it(("parses %s"):format(case.url), function()
        expect.eq({ host = case.host, owner = case.owner, repo = case.repo }, host._parse_remote(case.url))
      end)
    end

    it("reports nil for something that is not a GitHub-shaped remote", function()
      expect.eq(nil, host._parse_remote("not a remote"))
      expect.eq(nil, host._parse_remote("https://github.com/just-an-org"))
      expect.eq(nil, host._parse_remote(""))
    end)
  end)

  describe("resolve", function()
    ---@return Test.Repo, NvimDiff.Git.Repo
    local function setup_repo(remote_url)
      local r = gitrepo.new()
      if remote_url then
        r:git({ "remote", "add", "origin", remote_url })
      end
      return r, assert(repo_mod.discover(r.root))
    end

    it("resolves host, owner and repo from the origin remote", function()
      local _, repo = setup_repo("git@github.com:octocat/hello-world.git")
      local target = assert(host.resolve(repo))
      expect.eq({ host = "github.com", owner = "octocat", repo = "hello-world" }, target)
    end)

    it("errors no_remote when the repository has no origin", function()
      local _, repo = setup_repo(nil)
      local target, err = host.resolve(repo)
      expect.eq(nil, target)
      expect.truthy(errors.is(err, "no_remote"), tostring(err))
    end)

    it("errors bad_remote when the remote is not GitHub-shaped", function()
      local _, repo = setup_repo("not-a-github-remote")
      local target, err = host.resolve(repo)
      expect.eq(nil, target)
      expect.truthy(errors.is(err, "bad_remote"), tostring(err))
    end)

    it("config.github.host overrides the host but not owner/repo", function()
      local _, repo = setup_repo("git@github.com:octocat/hello-world.git")
      config.setup({ github = { host = "ghe.internal.example" } })
      local target = assert(host.resolve(repo))
      expect.eq({ host = "ghe.internal.example", owner = "octocat", repo = "hello-world" }, target)
    end)

    it("GH_HOST overrides the remote's host when config.github.host is unset", function()
      local _, repo = setup_repo("git@github.com:octocat/hello-world.git")
      vim.env.GH_HOST = "ghe.env.example"
      local target = assert(host.resolve(repo))
      expect.eq("ghe.env.example", target.host)
    end)

    it("config.github.host wins over GH_HOST", function()
      local _, repo = setup_repo("git@github.com:octocat/hello-world.git")
      vim.env.GH_HOST = "ghe.env.example"
      config.setup({ github = { host = "ghe.config.example" } })
      local target = assert(host.resolve(repo))
      expect.eq("ghe.config.example", target.host)
    end)

    it("honours a non-default remote name", function()
      local r, repo = setup_repo("git@github.com:octocat/hello-world.git")
      r:git({ "remote", "add", "upstream", "git@ghe.corp.example:acme/widgets.git" })
      local target = assert(host.resolve(repo, { remote = "upstream" }))
      expect.eq({ host = "ghe.corp.example", owner = "acme", repo = "widgets" }, target)
    end)
  end)
end)
