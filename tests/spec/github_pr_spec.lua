local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local errors = require("nvim-diff.github.error")
local ghstub = require("tests.ghstub")
local gitrepo = require("tests.gitrepo")
local pr = require("nvim-diff.github.pr")
local repo_mod = require("nvim-diff.git.repo")

describe("github pr", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
    gitrepo.cleanup()
  end)

  ---@param remote_url? string
  ---@return NvimDiff.Git.Repo
  local function setup_repo(remote_url)
    local r = gitrepo.new()
    if remote_url then
      r:git({ "remote", "add", "origin", remote_url })
    end
    return assert(repo_mod.discover(r.root))
  end

  local SUCCESS_BODY = [[
{
  "data": {
    "repository": {
      "pullRequest": {
        "id": "PR_kwDOA1234",
        "number": 42,
        "title": "Add feature",
        "url": "https://github.com/octocat/hello-world/pull/42",
        "state": "OPEN",
        "isDraft": false,
        "isCrossRepository": true,
        "maintainerCanModify": true,
        "headRefName": "feature",
        "headRefOid": "abc1230000000000000000000000000000000000",
        "headRepository": {
          "name": "hello-world",
          "owner": { "login": "forker" },
          "url": "https://github.com/forker/hello-world"
        },
        "baseRefName": "main",
        "baseRefOid": "def4560000000000000000000000000000000000",
        "baseRepository": {
          "name": "hello-world",
          "owner": { "login": "octocat" },
          "url": "https://github.com/octocat/hello-world"
        }
      }
    }
  }
}
]]

  it("fetches a PR's identifying data over GraphQL, never touching /pulls/{n}/files", function()
    local repo = setup_repo("git@github.com:octocat/hello-world.git")
    local body = SUCCESS_BODY:gsub("\n", " ")
    local bin, calls = ghstub.new(([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%%s\n' '%s'
    exit 0
    ;;
]]):format(body))
    config.setup({ github = { bin = bin } })

    local fetched = assert(pr.fetch(repo, 42))
    expect.eq("PR_kwDOA1234", fetched.id)
    expect.eq(42, fetched.number)
    expect.eq("OPEN", fetched.state)
    expect.eq(false, fetched.draft)
    expect.eq(true, fetched.cross_repository)
    expect.eq({
      ref = "main",
      oid = "def4560000000000000000000000000000000000",
      owner = "octocat",
      repo = "hello-world",
      url = "https://github.com/octocat/hello-world",
    }, fetched.base)
    expect.eq({
      ref = "feature",
      oid = "abc1230000000000000000000000000000000000",
      owner = "forker",
      repo = "hello-world",
      url = "https://github.com/forker/hello-world",
    }, fetched.head)
    expect.eq({ host = "github.com", owner = "octocat", repo = "hello-world" }, fetched.target)

    local sent = calls()[1]
    expect.matches("%-%-hostname github%.com", sent)
    expect.matches("%-f owner=octocat", sent)
    expect.matches("%-f name=hello%-world", sent)
    expect.matches("%-F number=42", sent)
    expect.falsy(sent:find("/pulls/", 1, true), "the PR fetch never calls the paginating REST files endpoint")
  end)

  it("resolves against a GitHub Enterprise Server remote's own host", function()
    local repo = setup_repo("git@ghe.corp.example:acme/widgets.git")
    local bin, calls = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%s\n' '{"data":{"repository":{"pullRequest":{
      "id":"PR_1","number":7,"title":"t","url":"u","state":"OPEN","isDraft":false,
      "isCrossRepository":false,"maintainerCanModify":false,
      "headRefName":"h","headRefOid":"h1","baseRefName":"b","baseRefOid":"b1"
    }}}}'
    exit 0
    ;;
]])
    config.setup({ github = { bin = bin } })
    local fetched = assert(pr.fetch(repo, 7))
    expect.eq("ghe.corp.example", fetched.target.host)
    expect.matches("%-%-hostname ghe%.corp%.example", calls()[1])
  end)

  it("errors not_found when the PR does not exist", function()
    local repo = setup_repo("git@github.com:octocat/hello-world.git")
    local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%s\n' '{"data":{"repository":{"pullRequest":null}},
      "errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest"}]}'
    exit 1
    ;;
]])
    config.setup({ github = { bin = bin } })
    local fetched, err = pr.fetch(repo, 999999)
    expect.eq(nil, fetched)
    expect.truthy(errors.is(err, "not_found"), tostring(err))
  end)

  it("errors invalid without ever calling gh for a bad PR number", function()
    local repo = setup_repo("git@github.com:octocat/hello-world.git")
    local bin, calls = ghstub.new([[
  *) exit 0 ;;
]])
    config.setup({ github = { bin = bin } })

    for _, bad in ipairs({ 0, -1, 1.5 }) do
      local fetched, err = pr.fetch(repo, bad)
      expect.eq(nil, fetched)
      expect.truthy(errors.is(err, "invalid"), tostring(err))
    end
    expect.eq({}, calls(), "gh is never invoked for input that is invalid before any request")
  end)

  it("errors no_remote when the repository has no origin to resolve", function()
    local repo = setup_repo(nil)
    local bin = ghstub.new([[
  *) exit 0 ;;
]])
    config.setup({ github = { bin = bin } })
    local fetched, err = pr.fetch(repo, 1)
    expect.eq(nil, fetched)
    expect.truthy(errors.is(err, "no_remote"), tostring(err))
  end)
end)
