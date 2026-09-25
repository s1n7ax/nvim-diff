local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local comments = require("nvim-diff.github.comments")
local config = require("nvim-diff.config")
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
  base = { ref = "main", oid = "b" },
  head = { ref = "feature", oid = "0123abcd" },
  target = { host = "ghe.corp.example", owner = "octocat", repo = "hello-world" },
}

--- A case arm answering with `status` and a one-line JSON body (no single quote in it).
---@param status string e.g. `201 Created`
---@param body string
---@param extra_headers? string
---@return string
local function answer(status, body, extra_headers)
  return ("    printf 'HTTP/2.0 %s\\n%s\\n%%s\\n' '%s'\n    exit 0\n    ;;\n"):format(
    status,
    extra_headers and (extra_headers .. "\\n") or "",
    body
  )
end

local CREATED = vim.json.encode({
  id = 555,
  node_id = "PRRC_new",
  body = "looks off",
  user = { login = "me" },
  created_at = "2026-09-25T10:00:00Z",
  html_url = "https://github.com/octocat/hello-world/pull/42#discussion_r555",
  path = "src/a.lua",
  line = 14,
  side = "RIGHT",
  start_line = 12,
  start_side = "RIGHT",
  in_reply_to_id = vim.NIL,
})

---@param argv string
---@param name string
---@return string? value The `-f`/`-F` field's value, up to the next field.
local function field(argv, name)
  return argv:match("%-[fF] " .. name .. "=(.-) %-[fF] ") or argv:match("%-[fF] " .. name .. "=(.*)$")
end

describe("github comments", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  it("posts a range comment at once, as REST fields on the head commit", function()
    local bin, calls = ghstub.new("  *pulls/42/comments*)\n" .. answer("201 Created", CREATED))
    config.setup({ github = { bin = bin } })

    local c = assert(comments.create(PR, {
      path = "src/a.lua",
      side = "new",
      line = 14,
      start_line = 12,
      body = "looks off\nsee `x`",
    }))
    expect.eq("PRRC_new", c.id)
    expect.eq("555", c.database_id)
    expect.eq("me", c.author)
    expect.eq("new", c.side)
    expect.eq(12, c.start_line)
    expect.eq(true, c.viewer_did_author)

    local sent = calls()[1]
    expect.matches(
      "^api %-%-hostname ghe%.corp%.example %-i %-%-method POST repos/octocat/hello%-world/pulls/42/comments ",
      sent
    )
    expect.eq("looks off\nsee `x`", field(sent, "body"))
    expect.matches("%-f commit_id=0123abcd ", sent)
    expect.matches("%-f path=src/a%.lua ", sent)
    expect.matches("%-F line=14 ", sent)
    expect.matches("%-f side=RIGHT ", sent)
    expect.matches("%-F start_line=12 ", sent)
    expect.matches("%-f start_side=RIGHT$", sent)
    expect.falsy(sent:find("position", 1, true), "never the legacy diff position")
    expect.falsy(sent:find("event", 1, true), "never a review")
  end)

  it("sends a single line on the old side as LEFT with no start fields", function()
    local bin, calls = ghstub.new("  *pulls/42/comments*)\n" .. answer("201 Created", CREATED))
    config.setup({ github = { bin = bin } })
    assert(comments.create(PR, { path = "a", side = "old", line = 3, start_line = 3, body = "gone?" }))
    local sent = calls()[1]
    expect.matches("%-f side=LEFT", sent)
    expect.falsy(sent:find("start_line", 1, true))
    expect.falsy(sent:find("start_side", 1, true))
  end)

  it("keeps a range across sides, start on the old side", function()
    local bin, calls = ghstub.new("  *pulls/42/comments*)\n" .. answer("201 Created", CREATED))
    config.setup({ github = { bin = bin } })
    assert(comments.create(PR, {
      path = "a",
      side = "new",
      line = 2,
      start_side = "old",
      start_line = 2,
      body = "x",
    }))
    local sent = calls()[1]
    expect.matches("%-f side=RIGHT", sent)
    expect.matches("%-F start_line=2", sent)
    expect.matches("%-f start_side=LEFT", sent)
  end)

  it("sends a body that looks like a file reference or a literal as plain text", function()
    local bin, calls = ghstub.new("  *pulls/42/comments*)\n" .. answer("201 Created", CREATED))
    config.setup({ github = { bin = bin } })
    assert(comments.create(PR, { path = "a", side = "new", line = 1, body = "@/etc/passwd" }))
    expect.matches("%-f body=@/etc/passwd ", calls()[1])
  end)

  it("replies through the first comment's REST id", function()
    local bin, calls = ghstub.new("  *pulls/42/comments/101/replies*)\n" .. answer("201 Created", CREATED))
    config.setup({ github = { bin = bin } })
    local thread = {
      id = "PRRT_1",
      path = "a",
      comments = { { id = "PRRC_1", database_id = "101" }, { id = "PRRC_2", database_id = "102" } },
    }
    assert(comments.reply(PR, thread --[[@as NvimDiff.GitHub.Thread]], "agreed"))
    local sent = calls()[1]
    expect.matches("%-%-method POST repos/octocat/hello%-world/pulls/42/comments/101/replies %-f body=agreed$", sent)
  end)

  it("says which field GitHub rejected", function()
    local body = '{"message":"Validation Failed","errors":["pull_request_review_thread.line must be part of the diff"]}'
    local bin = ghstub.new("  *pulls/42/comments*)\n" .. answer("422 Unprocessable Entity", body))
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    local c, err = comments.create(PR, { path = "a", side = "new", line = 99, body = "x" })
    expect.falsy(c)
    expect.eq("api_error", err.kind)
    expect.eq("Validation Failed: pull_request_review_thread.line must be part of the diff", err.message)
  end)

  it("reports a secondary rate limit with its retry-after", function()
    local body = '{"message":"You have exceeded a secondary rate limit"}'
    local bin = ghstub.new("  *pulls/42/comments*)\n" .. answer("403 Forbidden", body, "Retry-After: 60"))
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    local _, err = comments.create(PR, { path = "a", side = "new", line = 1, body = "x" })
    expect.eq("rate_limited", err.kind)
    expect.eq(60, err.retry_after)
  end)

  it("refuses an empty body and a thread with no REST id without calling gh", function()
    local bin, calls = ghstub.new("")
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    local _, err = comments.create(PR, { path = "a", side = "new", line = 1, body = "  \n " })
    expect.eq("invalid", err.kind)
    _, err = comments.reply(PR, { comments = {} } --[[@as NvimDiff.GitHub.Thread]], "x")
    expect.eq("invalid", err.kind)
    _, err = comments.edit(PR, { id = "PRRC_x" } --[[@as NvimDiff.GitHub.Comment]], "x")
    expect.eq("invalid", err.kind)
    _, err = comments.delete(PR, { id = "PRRC_x" } --[[@as NvimDiff.GitHub.Comment]])
    expect.eq("invalid", err.kind)
    _, err = comments.edit(PR, { id = "PRRC_x", database_id = "7" } --[[@as NvimDiff.GitHub.Comment]], " ")
    expect.eq("invalid", err.kind)
    _, err = comments.create_file(PR, "a", "")
    expect.eq("invalid", err.kind)
    expect.eq(0, #calls())
  end)

  it("posts a file-level comment with no line", function()
    local posted = vim.json.encode({
      id = 556,
      node_id = "PRRC_file",
      body = "split this file",
      user = { login = "me" },
      path = "src/a.lua",
      line = vim.NIL,
      side = vim.NIL,
      subject_type = "file",
    })
    local bin, calls = ghstub.new("  *pulls/42/comments*)\n" .. answer("201 Created", posted))
    config.setup({ github = { bin = bin } })
    local c = assert(comments.create_file(PR, "src/a.lua", "split this file"))
    expect.eq("file", c.subject)
    expect.eq(nil, c.line)
    local sent = calls()[1]
    expect.matches("%-%-method POST repos/octocat/hello%-world/pulls/42/comments ", sent)
    expect.eq("0123abcd", field(sent, "commit_id"))
    expect.eq("src/a.lua", field(sent, "path"))
    expect.eq("file", field(sent, "subject_type"))
    expect.falsy(sent:find("line=", 1, true))
  end)

  it("edits a comment by its REST id", function()
    local edited = vim.json.encode({ id = 101, node_id = "PRRC_1", body = "better words", user = { login = "me" } })
    local bin, calls = ghstub.new("  *pulls/comments/101*)\n" .. answer("200 OK", edited))
    config.setup({ github = { bin = bin } })
    local c = assert(
      comments.edit(PR, { id = "PRRC_1", database_id = "101" } --[[@as NvimDiff.GitHub.Comment]], "better words")
    )
    expect.eq("better words", c.body)
    local sent = calls()[1]
    expect.matches("^api %-%-hostname ghe%.corp%.example %-i %-%-method PATCH ", sent)
    expect.matches(" repos/octocat/hello%-world/pulls/comments/101 %-f body=better words$", sent)
  end)

  it("deletes a comment by its REST id, taking the empty 204 as success", function()
    local bin, calls =
      ghstub.new("  *pulls/comments/101*)\n    printf 'HTTP/2.0 204 No Content\\n\\n'\n    exit 0\n    ;;\n")
    config.setup({ github = { bin = bin } })
    expect.eq(true, comments.delete(PR, { id = "PRRC_1", database_id = "101" } --[[@as NvimDiff.GitHub.Comment]]))
    expect.matches("%-%-method DELETE repos/octocat/hello%-world/pulls/comments/101$", calls()[1])
  end)

  it("passes a refused delete through", function()
    local bin = ghstub.new("  *pulls/comments/101*)\n" .. answer("404 Not Found", '{"message":"Not Found"}'))
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    local ok, err = comments.delete(PR, { id = "PRRC_1", database_id = "101" } --[[@as NvimDiff.GitHub.Comment]])
    expect.falsy(ok)
    expect.eq("not_found", err.kind)
  end)
end)
