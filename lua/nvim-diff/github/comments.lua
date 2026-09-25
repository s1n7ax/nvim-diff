--- Writing review comments: a new comment on a line, a range of lines or a whole file, a
--- reply to a thread, and editing or deleting a comment of one's own. Each one goes up to
--- GitHub **immediately**, on its own — never into a pending review.
---
--- REST, not GraphQL: the GraphQL `addPullRequestReviewThread` mutation only adds to a
--- pending review, which is the batching the requirements ruled out. REST
--- `POST /repos/{o}/{r}/pulls/{n}/comments` posts at once (GitHub wraps it in an
--- auto-created `COMMENTED` review) and `POST …/comments/{id}/replies` answers a thread by
--- the REST id of its first comment — which `github/threads.lua` keeps as `database_id`.
--- A file-level comment is the same `POST` with `subject_type=file` and no line. Editing is
--- `PATCH /repos/{o}/{r}/pulls/comments/{id}` and deleting `DELETE` on the same path (a
--- `204`), both by that same REST id.
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
---@field subject "line"|"file"

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
    subject = value(raw.subject_type) == "file" and "file" or "line",
  }
end
M._from_rest = from_rest

---@param pr NvimDiff.GitHub.PR
---@param suffix string
---@return string
local function endpoint(pr, suffix)
  return ("repos/%s/%s/pulls/%d/comments%s"):format(pr.target.owner, pr.target.repo, pr.number, suffix)
end

--- A comment's own endpoint, for editing and deleting it.
---@param pr NvimDiff.GitHub.PR
---@param c NvimDiff.GitHub.Comment
---@return string? endpoint
---@return NvimDiff.GitHub.Error? err
local function comment_endpoint(pr, c)
  local id = c and c.database_id
  if type(id) ~= "string" or not id:match("^%d+$") then
    return nil, errors.new("invalid", "the comment has no REST id")
  end
  return ("repos/%s/%s/pulls/comments/%s"):format(pr.target.owner, pr.target.repo, id)
end

---@param pr NvimDiff.GitHub.PR
---@param method "POST"|"PATCH"|"DELETE"
---@param path string
---@param vars? NvimDiff.GitHub.Var[]
---@return table? data
---@return NvimDiff.GitHub.Error? err
local function send(pr, method, path, vars)
  local response, err = cmd.request(pr.target.host, path, { method = method, vars = vars })
  if not response then
    return nil, err
  end
  return cmd.classify(response)
end

--- Send, and read GitHub's answer as a comment.
---@param pr NvimDiff.GitHub.PR
---@param method "POST"|"PATCH"
---@param path string
---@param vars NvimDiff.GitHub.Var[]
---@return NvimDiff.GitHub.PostedComment? comment
---@return NvimDiff.GitHub.Error? err
local function write(pr, method, path, vars)
  local data, err = send(pr, method, path, vars)
  if not data then
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
  return write(pr, "POST", endpoint(pr, ""), vars)
end

--- Post a new comment on a whole file rather than on lines of it.
---@param pr NvimDiff.GitHub.PR
---@param path string Git path of the file.
---@param body string
---@return NvimDiff.GitHub.PostedComment? comment
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.create_file(pr, path, body)
  local bad = check_body(body)
  if bad then
    return nil, bad
  end
  if type(path) ~= "string" or path == "" then
    return nil, errors.new("invalid", "a file comment needs a path")
  end
  return write(pr, "POST", endpoint(pr, ""), {
    { flag = "-f", name = "body", value = body },
    { flag = "-f", name = "commit_id", value = pr.head.oid },
    { flag = "-f", name = "path", value = path },
    { flag = "-f", name = "subject_type", value = "file" },
  })
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
  return write(pr, "POST", endpoint(pr, ("/%s/replies"):format(id)), { { flag = "-f", name = "body", value = body } })
end

--- Replace the body of a comment. GitHub lets only its author do so.
---@param pr NvimDiff.GitHub.PR
---@param c NvimDiff.GitHub.Comment
---@param body string
---@return NvimDiff.GitHub.PostedComment? comment As edited.
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.edit(pr, c, body)
  local bad = check_body(body)
  if bad then
    return nil, bad
  end
  local path, err = comment_endpoint(pr, c)
  if not path then
    return nil, err
  end
  return write(pr, "PATCH", path, { { flag = "-f", name = "body", value = body } })
end

--- Delete a comment.
---@param pr NvimDiff.GitHub.PR
---@param c NvimDiff.GitHub.Comment
---@return boolean? ok
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.delete(pr, c)
  local path, err = comment_endpoint(pr, c)
  if not path then
    return nil, err
  end
  local data
  data, err = send(pr, "DELETE", path)
  if not data then
    return nil, err
  end
  return true
end

return M
