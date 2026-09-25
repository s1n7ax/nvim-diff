--- Posting review comments: a new comment on a line or a range of lines, and a reply to a
--- thread. Each one goes up to GitHub **immediately**, on its own — never into a pending
--- review.
---
--- REST, not GraphQL: the GraphQL `addPullRequestReviewThread` mutation only adds to a
--- pending review, which is the batching the requirements ruled out. REST
--- `POST /repos/{o}/{r}/pulls/{n}/comments` posts at once (GitHub wraps it in an
--- auto-created `COMMENTED` review) and `POST …/comments/{id}/replies` answers a thread by
--- the REST id of its first comment — which `github/threads.lua` keeps as `database_id`.
---
--- Lines are lines of the file, not diff positions: `side = "new"` (`RIGHT`) counts in the
--- PR head, `"old"` (`LEFT`) in the base. `commit_id` is the PR head, the commit the review
--- worktree is checked out at. The legacy `position` field is never sent.
---
--- Every field goes as a separate `gh api` field — `-f` for text, so a body that happens to
--- read `true` or `@file` is never retyped or read from disk; `-F` only for the line numbers,
--- which must arrive as integers.

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")

local M = {}

--- The hunk model's sides to GitHub's.
M.SIDES = { old = "LEFT", new = "RIGHT" }
local FROM_SIDE = { LEFT = "old", RIGHT = "new" }

---@class NvimDiff.GitHub.NewComment
---@field path string Git path of the file.
---@field side NvimDiff.Side Which file `line` counts in.
---@field line integer Last line of the commented range (the only one, for a single line).
---@field start_side? NvimDiff.Side Which file `start_line` counts in; defaults to `side`.
---@field start_line? integer First line of a multi-line range; omit for a single line.
---@field body string Markdown.

--- A comment as the REST API returned it, in `github/threads.lua`'s shape, plus where it is
--- anchored.
---@class NvimDiff.GitHub.PostedComment : NvimDiff.GitHub.Comment
---@field path string
---@field side? NvimDiff.Side
---@field line? integer
---@field start_side? NvimDiff.Side
---@field start_line? integer
---@field in_reply_to? string REST id of the comment this one answers.

---@param v any
---@return any
local function value(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param raw table REST pull request review comment.
---@return NvimDiff.GitHub.PostedComment
local function from_rest(raw)
  local user = value(raw.user)
  local id = value(raw.id)
  local reply = value(raw.in_reply_to_id)
  return {
    id = value(raw.node_id) or "",
    database_id = id ~= nil and tostring(id) or nil,
    author = user and value(user.login) or "ghost",
    body = (value(raw.body) or ""):gsub("\r\n?", "\n"),
    outdated = false,
    created_at = value(raw.created_at) or "",
    url = value(raw.html_url),
    viewer_did_author = true,
    path = value(raw.path) or "",
    side = FROM_SIDE[value(raw.side)],
    line = value(raw.line),
    start_side = FROM_SIDE[value(raw.start_side)],
    start_line = value(raw.start_line),
    in_reply_to = reply ~= nil and tostring(reply) or nil,
  }
end
M._from_rest = from_rest

---@param pr NvimDiff.GitHub.PR
---@param suffix string
---@return string
local function endpoint(pr, suffix)
  return ("repos/%s/%s/pulls/%d/comments%s"):format(pr.target.owner, pr.target.repo, pr.number, suffix)
end

---@param pr NvimDiff.GitHub.PR
---@param suffix string
---@param vars NvimDiff.GitHub.Var[]
---@return NvimDiff.GitHub.PostedComment? comment
---@return NvimDiff.GitHub.Error? err
local function post(pr, suffix, vars)
  local response, err = cmd.request(pr.target.host, endpoint(pr, suffix), { method = "POST", vars = vars })
  if not response then
    return nil, err
  end
  local data
  data, err = cmd.classify(response)
  if not data then
    -- A 422 names the field GitHub rejected in `errors`; the top message alone says only
    -- "Validation Failed".
    local body = type(response.body) == "table" and response.body or {}
    local detail = type(body.errors) == "table" and body.errors[1]
    if err and type(detail) == "table" and type(detail.message) == "string" then
      err.message = ("%s: %s"):format(err.message, detail.message)
    elseif err and type(detail) == "string" then
      err.message = ("%s: %s"):format(err.message, detail)
    end
    return nil, err
  end
  if type(data) ~= "table" or value(data.node_id) == nil then
    return nil, errors.new("api_error", "GitHub's reply to the comment did not describe a comment")
  end
  return from_rest(data)
end

---@param body any
---@return NvimDiff.GitHub.Error?
local function check_body(body)
  if type(body) ~= "string" or vim.trim(body) == "" then
    return errors.new("invalid", "the comment is empty")
  end
  return nil
end

--- Post a new comment on a line, or on a range of lines, of the PR head's diff.
---@param pr NvimDiff.GitHub.PR
---@param c NvimDiff.GitHub.NewComment
---@return NvimDiff.GitHub.PostedComment? comment
---@return NvimDiff.GitHub.Error? err `invalid` before sending; otherwise what GitHub said
---(a 422 when a line is outside the diff).
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.create(pr, c)
  local bad = check_body(c.body)
  if bad then
    return nil, bad
  end
  if not M.SIDES[c.side] or type(c.line) ~= "number" or c.line < 1 then
    return nil, errors.new("invalid", "a comment needs a side and a line")
  end
  local vars = {
    { flag = "-f", name = "body", value = c.body },
    { flag = "-f", name = "commit_id", value = pr.head.oid },
    { flag = "-f", name = "path", value = c.path },
    { flag = "-F", name = "line", value = c.line },
    { flag = "-f", name = "side", value = M.SIDES[c.side] },
  }
  local start_side = c.start_side or c.side
  if c.start_line and (c.start_line ~= c.line or start_side ~= c.side) then
    if not M.SIDES[start_side] then
      return nil, errors.new("invalid", "a range's start needs a side")
    end
    vim.list_extend(vars, {
      { flag = "-F", name = "start_line", value = c.start_line },
      { flag = "-f", name = "start_side", value = M.SIDES[start_side] },
    })
  end
  return post(pr, "", vars)
end

--- Reply to a thread.
---@param pr NvimDiff.GitHub.PR
---@param thread NvimDiff.GitHub.Thread
---@param body string
---@return NvimDiff.GitHub.PostedComment? comment
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.reply(pr, thread, body)
  local bad = check_body(body)
  if bad then
    return nil, bad
  end
  local first = thread.comments[1]
  local id = first and first.database_id
  if not id or not id:match("^%d+$") then
    return nil, errors.new("invalid", "the thread has no comment to reply to")
  end
  return post(pr, ("/%s/replies"):format(id), { { flag = "-f", name = "body", value = body } })
end

return M
