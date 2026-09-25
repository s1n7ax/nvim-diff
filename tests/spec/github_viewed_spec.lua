local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")
local viewed = require("nvim-diff.github.viewed")

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
  base = { ref = "main", oid = "b" },
  head = { ref = "feature", oid = "h" },
  target = { host = "ghe.corp.example", owner = "octocat", repo = "hello-world" },
}

---@param body string A JSON object on one line, with no single quote in it.
---@return string
local function reply(body)
  return ("    printf 'HTTP/2.0 200 OK\\n\\n%%s\\n' '%s'\n    exit 0\n    ;;\n"):format(body)
end

describe("github viewed", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  it("reads every page of the file list and maps GitHub's states onto the panel's", function()
    local page1 = vim.json.encode({
      data = {
        repository = {
          pullRequest = {
            files = {
              pageInfo = { hasNextPage = true, endCursor = "CUR1" },
              nodes = {
                { path = "a.txt", viewerViewedState = "VIEWED" },
                { path = "b.txt", viewerViewedState = "DISMISSED" },
              },
            },
          },
        },
      },
    })
    local page2 = vim.json.encode({
      data = {
        repository = {
          pullRequest = {
            files = {
              pageInfo = { hasNextPage = false, endCursor = "CUR2" },
              nodes = { { path = "dir/c.txt", viewerViewedState = "UNVIEWED" } },
            },
          },
        },
      },
    })
    local bin, calls = ghstub.new(table.concat({
      '  *"viewerViewedState"*"after=CUR1"*)',
      reply(page2),
      '  *"viewerViewedState"*)',
      reply(page1),
    }, "\n"))
    config.setup({ github = { bin = bin } })

    local states = assert(viewed.fetch(PR))
    expect.eq({ ["a.txt"] = "viewed", ["b.txt"] = "rechanged", ["dir/c.txt"] = "unviewed" }, states)

    local sent = calls()
    expect.eq(2, #sent)
    expect.matches("%-%-hostname ghe%.corp%.example", sent[1])
    expect.matches("%-f owner=octocat", sent[1])
    expect.matches("%-f name=hello%-world", sent[1])
    expect.matches("%-F number=42", sent[1])
    expect.matches("X%-Github%-Next%-Global%-ID: 1", sent[1])
    expect.falsy(sent[1]:find("after=", 1, true), "the first page has no cursor")
    expect.matches("%-f after=CUR1", sent[2])
  end)

  it("marks and unmarks by the PR's node id and the file's path", function()
    local ok_body = '{"data":{"x":{"clientMutationId":null}}}'
    local bin, calls = ghstub.new(table.concat({
      "  *unmarkFileAsViewed*)",
      reply(ok_body),
      "  *markFileAsViewed*)",
      reply(ok_body),
    }, "\n"))
    config.setup({ github = { bin = bin } })

    expect.eq(true, (viewed.mark(PR, "dir/c.txt")))
    expect.eq(true, (viewed.unmark(PR, "a.txt")))
    local sent = calls()
    expect.matches("markFileAsViewed%(input:", sent[1])
    expect.falsy(sent[1]:find("unmarkFileAsViewed", 1, true))
    expect.matches("%-f id=PR_kwDOA1234", sent[1])
    expect.matches("%-f path=dir/c%.txt", sent[1])
    expect.matches("unmarkFileAsViewed%(input:", sent[2])
    expect.matches("%-f path=a%.txt", sent[2])
  end)

  it("passes a GraphQL error through as a value", function()
    local bin = ghstub.new(table.concat({
      "  *markFileAsViewed*)",
      reply('{"data":null,"errors":[{"type":"NOT_FOUND","message":"no such path"}]}'),
    }, "\n"))
    config.setup({ github = { bin = bin } })

    local ok, err = viewed.mark(PR, "nope.txt")
    expect.falsy(ok)
    expect.eq("not_found", err.kind)
    expect.eq("no such path", err.message)
  end)

  it("reports a PR with no file list", function()
    local bin = ghstub.new(table.concat({
      "  *viewerViewedState*)",
      reply('{"data":{"repository":{"pullRequest":null}}}'),
    }, "\n"))
    config.setup({ github = { bin = bin } })

    local states, err = viewed.fetch(PR)
    expect.falsy(states)
    expect.eq("not_found", err.kind)
  end)
end)
