local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local cmd = require("nvim-diff.github.cmd")
local config = require("nvim-diff.config")
local errors = require("nvim-diff.github.error")
local ghstub = require("tests.ghstub")

describe("github cmd", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  describe("run", function()
    it("reports a missing gh as spawn_failed, not an error", function()
      config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
      local res, err = cmd.run({ "--version" })
      expect.eq(nil, res)
      expect.truthy(errors.is(err, "spawn_failed"))
    end)

    it("reports a killed-on-timeout gh as timeout", function()
      -- `sleep` directly, not a ghstub script wrapping it: `core/job.lua`'s timeout
      -- mechanics are `job_spec.lua`'s job to prove; this only has to show `M.run` maps a
      -- timed-out result to the `timeout` kind.
      config.setup({ github = { bin = "sleep" } })
      local res, err = cmd.run({ "5" }, { timeout_ms = 50 })
      expect.eq(nil, res)
      expect.truthy(errors.is(err, "timeout"), tostring(err))
    end)

    it("strips everything but the allow-list from gh's environment", function()
      vim.env.NVIM_DIFF_GH_TEST_SECRET = "leak"
      local bin, _, env = ghstub.new([[
  *) exit 0 ;;
]])
      config.setup({ github = { bin = bin } })
      cmd.run({ "noop" })
      vim.env.NVIM_DIFF_GH_TEST_SECRET = nil

      expect.eq(nil, env("NVIM_DIFF_GH_TEST_SECRET"))
      expect.truthy(env("HOME"), "HOME is allow-listed and was inherited")
    end)

    it("forces GH_PROMPT_DISABLED and GH_NO_UPDATE_NOTIFIER regardless of the real environment", function()
      local bin, _, env = ghstub.new([[
  *) exit 0 ;;
]])
      config.setup({ github = { bin = bin } })
      cmd.run({ "noop" })
      expect.eq("1", env("GH_PROMPT_DISABLED"))
      expect.eq("1", env("GH_NO_UPDATE_NOTIFIER"))
    end)

    it("lets an allow-listed token through", function()
      vim.env.GH_TOKEN = "test-token"
      local bin, _, env = ghstub.new([[
  *) exit 0 ;;
]])
      config.setup({ github = { bin = bin } })
      cmd.run({ "noop" })
      vim.env.GH_TOKEN = nil
      expect.eq("test-token", env("GH_TOKEN"))
    end)
  end)

  describe("request/graphql", function()
    it("parses a successful GraphQL response and returns its data", function()
      local bin, calls = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n%s\n' '{"data":{"viewer":{"login":"octocat"}}}'
    exit 0
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{ viewer { login } }")
      expect.falsy(err, tostring(err))
      expect.eq({ viewer = { login = "octocat" } }, data)

      local sent = calls()[1]
      expect.matches("%-%-hostname github%.com", sent)
      expect.matches("X%-Github%-Next%-Global%-ID: 1", sent)
      expect.matches("query=query{ viewer { login } }", sent)
    end)

    it("sends -f for string variables and -F for typed ones", function()
      local bin, calls = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%s\n' '{"data":{}}'
    exit 0
    ;;
]])
      config.setup({ github = { bin = bin } })
      cmd.graphql("github.com", "query($o:String!,$n:Int!){x}", {
        { flag = "-f", name = "o", value = "owner" },
        { flag = "-F", name = "n", value = 42 },
      })
      local sent = calls()[1]
      expect.matches("%-f o=owner", sent)
      expect.matches("%-F n=42", sent)
    end)

    it("classifies a GraphQL-shaped NOT_FOUND error", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%s\n' '{"data":{"repository":null},
      "errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "not_found"))
      expect.matches("Could not resolve", err.message)
    end)

    it("classifies a GraphQL-shaped schema error as api_error", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\n%s\n' '{"errors":[{"message":"Field does not exist"}]}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "api_error"))
    end)

    it("classifies a 401 response as not_authenticated", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 401 Unauthorized\n\n%s\n' '{"message":"Bad credentials","status":"401"}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "not_authenticated"))
      expect.eq(401, err.status)
    end)

    it("classifies a 403 with Retry-After as rate_limited", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 403 Forbidden\nRetry-After: 30\n\n%s\n' '{"message":"secondary rate limit"}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "rate_limited"))
      expect.eq(30, err.retry_after)
    end)

    it("classifies a 403 with no Retry-After as forbidden", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 403 Forbidden\n\n%s\n' '{"message":"not permitted"}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "forbidden"))
    end)

    it("classifies a 404 response as not_found", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 404 Not Found\n\n%s\n' '{"message":"Not Found"}'
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "not_found"))
    end)

    it("reports a connection failure (no response at all) as request_failed", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'error connecting to does-not-exist.invalid\n' >&2
    exit 1
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "request_failed"), tostring(err))
      expect.matches("error connecting", err.message)
    end)

    it("reports a non-JSON body as api_error rather than throwing", function()
      local bin = ghstub.new([[
  *"graphql"*)
    printf 'HTTP/2.0 200 OK\n\nnot json\n'
    exit 0
    ;;
]])
      config.setup({ github = { bin = bin } })
      local data, err = cmd.graphql("github.com", "query{x}")
      expect.eq(nil, data)
      expect.truthy(errors.is(err, "api_error"), tostring(err))
    end)
  end)
end)
