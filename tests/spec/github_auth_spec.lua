local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local auth = require("nvim-diff.github.auth")
local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")

describe("github auth", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  it("reports not installed when gh is missing", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    local status = auth.status()
    expect.eq({ installed = false, hosts = {} }, status)
  end)

  it("reports the version and every authenticated host", function()
    local bin = ghstub.new([[
  *"--version"*)
    printf 'gh version 2.101.0 (test)\nhttps://github.com/cli/cli/releases/tag/v2.101.0\n'
    exit 0
    ;;
  *"auth status --json hosts"*)
    printf '%s' '{"hosts":{
      "github.com":[{"state":"success","active":true,"host":"github.com","login":"octocat"}],
      "ghe.corp.example":[{"state":"success","active":true,"host":"ghe.corp.example","login":"octocat2"}]
    }}'
    exit 0
    ;;
]])
    config.setup({ github = { bin = bin } })
    local status = auth.status()
    expect.eq(true, status.installed)
    expect.eq("gh version 2.101.0 (test)", status.version)
    expect.eq({
      { host = "ghe.corp.example", authenticated = true, login = "octocat2", active = true },
      { host = "github.com", authenticated = true, login = "octocat", active = true },
    }, status.hosts)
    expect.truthy(auth.is_authenticated(status, "github.com"))
    expect.truthy(auth.is_authenticated(status, "GitHub.com"), "host comparison is case-insensitive")
    expect.falsy(auth.is_authenticated(status, "ghe.other.example"))
  end)

  it("tells a rejected token apart from never having logged in, even though gh exits 0 for both", function()
    local bin = ghstub.new([[
  *"--version"*)
    printf 'gh version 2.101.0 (test)\n'
    exit 0
    ;;
  *"auth status --json hosts"*)
    printf '%s' '{"hosts":{"github.com":[{"state":"error","active":true,"host":"github.com","login":""}]}}'
    exit 0
    ;;
]])
    config.setup({ github = { bin = bin } })
    local status = auth.status()
    expect.eq({ { host = "github.com", authenticated = false, active = false } }, status.hosts)
    expect.falsy(auth.is_authenticated(status, "github.com"))
  end)

  it("reports no hosts when gh is installed but never logged in", function()
    local bin = ghstub.new([[
  *"--version"*)
    printf 'gh version 2.101.0 (test)\n'
    exit 0
    ;;
  *"auth status --json hosts"*)
    printf '%s' '{"hosts":{}}'
    exit 0
    ;;
]])
    config.setup({ github = { bin = bin } })
    local status = auth.status()
    expect.eq(true, status.installed)
    expect.eq({}, status.hosts)
  end)
end)
