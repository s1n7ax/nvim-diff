local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local gh_review = require("nvim-diff.github.review")
local ghstub = require("tests.ghstub")

---@type NvimDiff.GitHub.PR
local PR = {
  id = "PR_kwDOA1234",
  number = 42,
  title = "t",
  url = "u",
  state = "OPEN",
  draft = false,
  cross_repository = false,
  maintainer_can_modify = false,
  base = { ref = "main", oid = "b0b0" },
  head = { ref = "feature", oid = "h3ad" },
  target = { host = "ghe.corp.example", owner = "octocat", repo = "hello-world" },
}

---@param status string e.g. `200 OK`.
---@param body string A JSON object on one line, with no single quote in it.
---@return string
local function reply(status, body)
  return ("    printf 'HTTP/2.0 %s\\n\\n%%s\\n' '%s'\n    exit 0\n    ;;\n"):format(status, body)
end

local OK = '{"id":9001,"node_id":"PRR_1","state":"APPROVED","html_url":"https://x/pull/42#pullrequestreview-9001"}'

describe("github review", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  it("posts the verdict and head commit to the PR's reviews, with no comments", function()
    local bin, calls = ghstub.new("  *pulls/42/reviews*)\n" .. reply("200 OK", OK))
    config.setup({ github = { bin = bin } })

    local review = assert(gh_review.submit(PR, "APPROVE"))
    expect.eq({
      id = 9001,
      node_id = "PRR_1",
      state = "APPROVED",
      url = "https://x/pull/42#pullrequestreview-9001",
    }, review)

    local sent = calls()
    expect.eq(1, #sent)
    expect.matches("%-%-hostname ghe%.corp%.example", sent[1])
    expect.matches("repos/octocat/hello%-world/pulls/42/reviews", sent[1])
    expect.matches("%-f event=APPROVE", sent[1])
    expect.matches("%-f commit_id=h3ad", sent[1])
    expect.falsy(sent[1]:find("body=", 1, true), "an empty summary is not sent")
    expect.falsy(sent[1]:find("comments", 1, true), "a verdict never carries comments")
  end)

  it("sends the summary as the body, verbatim", function()
    local bin, calls = ghstub.new("  *pulls/42/reviews*)\n" .. reply("200 OK", OK))
    config.setup({ github = { bin = bin } })

    assert(gh_review.submit(PR, "REQUEST_CHANGES", "Two things:\n\n- the `%s` format\n- tests"))
    local sent = calls()[1]
    expect.matches("%-f event=REQUEST_CHANGES", sent)
    expect.truthy(sent:find("-f body=Two things:\n\n- the `%s` format\n- tests", 1, true))
  end)

  it("refuses a missing summary where GitHub requires one, sending nothing", function()
    local bin, calls = ghstub.new("  *)\n" .. reply("200 OK", OK))
    config.setup({ github = { bin = bin } })

    for _, event in ipairs({ "REQUEST_CHANGES", "COMMENT" }) do
      local review, err = gh_review.submit(PR, event, "  \n\t")
      expect.falsy(review)
      expect.eq("invalid", err.kind)
      expect.matches("needs a summary", err.message)
    end
    local review, err = gh_review.submit(PR, "PENDING", "x")
    expect.falsy(review)
    expect.eq("invalid", err.kind, "an unknown event would make a pending review")
    expect.eq(0, #calls())
  end)

  it("reports GitHub's reason for a 422, such as approving your own PR", function()
    local bin = ghstub.new(
      "  *pulls/42/reviews*)\n"
        .. reply(
          "422 Unprocessable Entity",
          '{"message":"Unprocessable Entity","errors":["Can not approve your own pull request"],"status":"422"}'
        )
    )
    config.setup({ github = { bin = bin }, log = { level = "off" } })

    local review, err = gh_review.submit(PR, "APPROVE")
    expect.falsy(review)
    expect.eq("api_error", err.kind)
    expect.eq(422, err.status)
    expect.eq("Can not approve your own pull request", err.message)
  end)

  it("passes other errors through with their kind", function()
    local bin = ghstub.new("  *pulls/42/reviews*)\n" .. reply("404 Not Found", '{"message":"Not Found"}'))
    config.setup({ github = { bin = bin }, log = { level = "off" } })

    local review, err = gh_review.submit(PR, "COMMENT", "lgtm")
    expect.falsy(review)
    expect.eq("not_found", err.kind)
  end)
end)
