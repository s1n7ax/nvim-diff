local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local errors = require("nvim-diff.github.error")
local ghstub = require("tests.ghstub")
local threads = require("nvim-diff.github.threads")

local TARGET = { host = "github.com", owner = "octocat", repo = "hello-world" }

--- A `case` arm answering a GraphQL call with `json` (single quotes are not allowed in it).
---@param pattern string
---@param json string
---@return string
local function arm(pattern, json)
  assert(not json:find("'", 1, true))
  return ([[
  %s)
    printf 'HTTP/2.0 200 OK\n\n%%s\n' '%s'
    exit 0
    ;;
]]):format(pattern, (json:gsub("\n", " ")))
end

---@param id string
---@param extra? table
---@return table
local function comment(id, extra)
  return vim.tbl_extend("force", {
    id = id,
    fullDatabaseId = "10" .. id:match("%d+"),
    author = { login = "alice" },
    body = "why 9090?\r\nsecond line",
    outdated = false,
    createdAt = "2026-09-01T12:00:00Z",
    url = "https://github.com/octocat/hello-world/pull/42#discussion_r1",
    viewerDidAuthor = false,
    replyTo = vim.NIL,
  }, extra or {})
end

---@param id string
---@param comments table[]
---@param extra? table
---@param more? string Cursor of a second page of comments.
---@return table
local function thread(id, comments, extra, more)
  return vim.tbl_extend("force", {
    id = id,
    path = "lua/server.lua",
    line = 8,
    startLine = vim.NIL,
    originalLine = 8,
    originalStartLine = vim.NIL,
    diffSide = "RIGHT",
    startDiffSide = vim.NIL,
    isResolved = false,
    isOutdated = false,
    isCollapsed = false,
    subjectType = "LINE",
    viewerCanReply = true,
    viewerCanResolve = true,
    viewerCanUnresolve = false,
    resolvedBy = vim.NIL,
    comments = {
      pageInfo = { hasNextPage = more ~= nil, endCursor = more or vim.NIL },
      nodes = comments,
    },
  }, extra or {})
end

---@param nodes table[]
---@param next_cursor? string
---@return string
local function page(nodes, next_cursor)
  return vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          reviewThreads = {
            pageInfo = { hasNextPage = next_cursor ~= nil, endCursor = next_cursor or vim.NIL },
            nodes = nodes,
          },
        },
      },
    },
  })
end

describe("github threads", function()
  before_each(function()
    config.reset()
  end)

  after_each(function()
    config.reset()
    ghstub.cleanup()
  end)

  it("fetches every thread and comment, normalised, across pages of both", function()
    local p1 = page({
      thread("PRRT_1", { comment("C1"), comment("C2", { author = vim.NIL, replyTo = { id = "C1" } }) }),
      thread("PRRT_2", { comment("C3") }, { diffSide = "LEFT", line = 3, startLine = 1, startDiffSide = "LEFT" }, "K1"),
    }, "P1")
    local p2 = page({
      thread("PRRT_3", { comment("C5") }, {
        line = vim.NIL,
        isOutdated = true,
        isResolved = true,
        resolvedBy = { login = "carol" },
        originalLine = 40,
      }),
      thread("PRRT_4", { comment("C6") }, { subjectType = "FILE", line = vim.NIL, diffSide = vim.NIL }),
    })
    local more = vim.json.encode({
      data = { node = { comments = { pageInfo = { hasNextPage = false }, nodes = { comment("C4") } } } },
    })
    local bin, calls =
      ghstub.new(arm([[*"cursor=P1"*]], p2) .. arm([[*"id=PRRT_2"*"cursor=K1"*]], more) .. arm([[*"graphql"*]], p1))
    config.setup({ github = { bin = bin } })

    local list = assert(threads.fetch(TARGET, 42))
    expect.eq(
      { "PRRT_1", "PRRT_2", "PRRT_3", "PRRT_4" },
      vim.tbl_map(function(x)
        return x.id
      end, list)
    )
    local a, b, c, d = list[1], list[2], list[3], list[4]
    expect.eq("new", a.side)
    expect.eq(8, a.line)
    expect.eq(nil, a.start_line)
    expect.eq("line", a.subject)
    expect.eq(false, a.resolved)
    expect.eq(true, a.can_reply)
    expect.eq(2, #a.comments)
    expect.eq({
      id = "C1",
      database_id = "101",
      author = "alice",
      body = "why 9090?\nsecond line",
      outdated = false,
      created_at = "2026-09-01T12:00:00Z",
      url = "https://github.com/octocat/hello-world/pull/42#discussion_r1",
      viewer_did_author = false,
    }, a.comments[1])
    expect.eq("ghost", a.comments[2].author)
    expect.eq("C1", a.comments[2].reply_to)

    expect.eq("old", b.side)
    expect.eq("old", b.start_side)
    expect.eq({ 1, 3 }, { b.start_line, b.line })
    expect.eq({ "C3", "C4" }, { b.comments[1].id, b.comments[2].id }, "the second page of comments")

    expect.eq(nil, c.line)
    expect.eq(40, c.original_line)
    expect.eq({ true, true, "carol" }, { c.outdated, c.resolved, c.resolved_by })
    expect.eq("file", d.subject)
    expect.eq(nil, d.side)

    local sent = calls()
    expect.eq(3, #sent)
    expect.falsy(sent[1]:find("cursor=", 1, true), "the first page is asked for without a cursor")
    expect.matches("%-f owner=octocat", sent[1])
    expect.matches("%-f name=hello%-world", sent[1])
    expect.matches("%-F number=42", sent[1])
    expect.matches("X%-Github%-Next%-Global%-ID: 1", sent[1])
    expect.matches("%-f id=PRRT_2 %-f cursor=K1", sent[2])
    expect.matches("%-f cursor=P1", sent[3])
  end)

  it("errors not_found for a PR that does not exist", function()
    local bin = ghstub.new(arm([[*"graphql"*]], [[{"data":{"repository":{"pullRequest":null}}}]]))
    config.setup({ github = { bin = bin } })
    local list, err = threads.fetch(TARGET, 7)
    expect.eq(nil, list)
    expect.truthy(errors.is(err, "not_found"), tostring(err))
  end)

  it("passes a GraphQL error through", function()
    local bin = ghstub.new(arm([[*"graphql"*]], [[{"errors":[{"message":"Field subjectType does not exist"}]}]]))
    config.setup({ github = { bin = bin } })
    local list, err = threads.fetch(TARGET, 7)
    expect.eq(nil, list)
    expect.truthy(errors.is(err, "api_error"), tostring(err))
    expect.matches("subjectType", err.message)
  end)

  it("errors invalid without calling gh for a bad PR number", function()
    local bin, calls = ghstub.new([[
  *) exit 0 ;;
]])
    config.setup({ github = { bin = bin } })
    local list, err = threads.fetch(TARGET, 0)
    expect.eq(nil, list)
    expect.truthy(errors.is(err, "invalid"), tostring(err))
    expect.eq({}, calls())
  end)

  it("returns an empty list for a PR with no threads", function()
    local bin = ghstub.new(arm([[*"graphql"*]], page({})))
    config.setup({ github = { bin = bin } })
    expect.eq({}, assert(threads.fetch(TARGET, 7)))
  end)
end)
