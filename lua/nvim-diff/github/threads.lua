--- Reading a PR's review threads: every thread with every comment, its resolved and
--- outdated state, and where it is anchored (path, line, side).
---
--- GraphQL, not REST: only GraphQL groups comments into threads and says whether a thread
--- is resolved or outdated (REST's `/pulls/{n}/comments` is a flat list with neither). The
--- ids kept here bridge to the REST writes of later steps: a comment's `database_id`
--- (GraphQL `fullDatabaseId`) is REST's numeric comment id, which the reply endpoint takes.
---
--- Both levels paginate, each at GitHub's cap of 100: threads through the pull request's
--- `reviewThreads` connection, and a thread with more than 100 comments through a follow-up
--- `node(id:)` query for the rest of that thread. Pagination is done here with a `cursor`
--- variable rather than `gh api --paginate`, because every call runs with `-i` (headers for
--- `Retry-After`) and `--paginate` would concatenate several header blocks and bodies.
---
--- Sides are normalised to the hunk model's names: GitHub's `LEFT` is `"old"`, `RIGHT` is
--- `"new"`.

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")

local M = {}

--- GitHub's page-size cap for a connection.
M.PAGE = 100

--- Comment fields, shared by both queries. A constant, so both query texts stay static.
local COMMENTS = [[
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        fullDatabaseId
        author { login }
        body
        outdated
        createdAt
        url
        viewerDidAuthor
        replyTo { id }
      }
]]

--- Static: `owner`, `name`, `number` and `cursor` travel as variables (see `M.fetch`).
local THREADS_QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          path
          line
          startLine
          originalLine
          originalStartLine
          diffSide
          startDiffSide
          isResolved
          isOutdated
          isCollapsed
          subjectType
          viewerCanReply
          viewerCanResolve
          viewerCanUnresolve
          resolvedBy { login }
          comments(first: 100) {
]] .. COMMENTS .. [[
          }
        }
      }
    }
  }
}
]]

--- The rest of one thread's comments, after the first page.
local COMMENTS_QUERY = [[
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
]] .. COMMENTS .. [[
      }
    }
  }
}
]]

---@class NvimDiff.GitHub.Comment
---@field id string GraphQL node id.
---@field database_id? string REST's numeric id, as a string (GitHub's `BigInt`).
---@field author string Login; `ghost` for a deleted account.
---@field body string Markdown source, line endings normalised to `\n`.
---@field outdated boolean
---@field created_at string ISO 8601.
---@field url? string
---@field viewer_did_author boolean
---@field reply_to? string Node id of the comment this one replies to.

---@class NvimDiff.GitHub.Thread
---@field id string GraphQL node id — what `resolveReviewThread` takes.
---@field path string
---@field side? NvimDiff.Side Which file `line` counts in: `"old"` (GitHub `LEFT`) or `"new"` (`RIGHT`).
---@field start_side? NvimDiff.Side
---@field line? integer Last line of the commented range; nil when outdated or file-level.
---@field start_line? integer First line of a multi-line range; nil for a single line.
---@field original_line? integer Where it was when commented, for an outdated thread.
---@field original_start_line? integer
---@field resolved boolean
---@field outdated boolean
---@field collapsed boolean GitHub's own "collapsed" flag (resolved or outdated, usually).
---@field subject "line"|"file" A file-level comment has no line at all.
---@field can_reply boolean
---@field can_resolve boolean
---@field can_unresolve boolean
---@field resolved_by? string Login.
---@field comments NvimDiff.GitHub.Comment[] Oldest first; the first one opened the thread.
--- Built locally from a posted comment when the threads could not be refetched
--- (`review/comment.lua` `thread_of`): `id` is then a comment's id, not a thread's, and the
--- thread cannot be resolved until the threads are read again.
---@field local_only? boolean

local SIDES = { LEFT = "old", RIGHT = "new" }

---@param v any
---@return any
local function value(v)
  -- `vim.json.decode` turns JSON null into `vim.NIL`.
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param node table Raw GraphQL comment.
---@return NvimDiff.GitHub.Comment
local function comment_from(node)
  local author = value(node.author)
  local reply = value(node.replyTo)
  local db = value(node.fullDatabaseId)
  return {
    id = node.id,
    database_id = db ~= nil and tostring(db) or nil,
    author = author and value(author.login) or "ghost",
    body = (value(node.body) or ""):gsub("\r\n?", "\n"),
    outdated = node.outdated == true,
    created_at = value(node.createdAt) or "",
    url = value(node.url),
    viewer_did_author = node.viewerDidAuthor == true,
    reply_to = reply and value(reply.id) or nil,
  }
end

---@param node table Raw GraphQL `PullRequestReviewThread`.
---@return NvimDiff.GitHub.Thread
local function thread_from(node)
  local by = value(node.resolvedBy)
  local comments = {}
  local conn = value(node.comments)
  for _, c in ipairs(conn and value(conn.nodes) or {}) do
    comments[#comments + 1] = comment_from(c)
  end
  return {
    id = node.id,
    path = node.path,
    side = SIDES[value(node.diffSide)],
    start_side = SIDES[value(node.startDiffSide)],
    line = value(node.line),
    start_line = value(node.startLine),
    original_line = value(node.originalLine),
    original_start_line = value(node.originalStartLine),
    resolved = node.isResolved == true,
    outdated = node.isOutdated == true,
    collapsed = node.isCollapsed == true,
    subject = value(node.subjectType) == "FILE" and "file" or "line",
    can_reply = node.viewerCanReply == true,
    can_resolve = node.viewerCanResolve == true,
    can_unresolve = node.viewerCanUnresolve == true,
    resolved_by = by and value(by.login) or nil,
    comments = comments,
  }
end
M._thread_from = thread_from

---@param conn table? A connection's raw `pageInfo` holder.
---@return string? cursor The next page's cursor, when there is one.
local function next_cursor(conn)
  local info = conn and value(conn.pageInfo)
  if info and info.hasNextPage == true then
    return value(info.endCursor)
  end
  return nil
end

--- Fetch the comments of `thread` after `cursor`, appending them to it.
---@param host string
---@param thread NvimDiff.GitHub.Thread
---@param cursor string
---@return boolean? ok
---@return NvimDiff.GitHub.Error? err
local function rest_of_comments(host, thread, cursor)
  while cursor do
    local data, err = cmd.graphql(host, COMMENTS_QUERY, {
      { flag = "-f", name = "id", value = thread.id },
      { flag = "-f", name = "cursor", value = cursor },
    })
    if not data then
      return nil, err
    end
    local node = value(data.node)
    local conn = node and value(node.comments)
    if not conn then
      return nil, errors.new("not_found", ("review thread %s not found"):format(thread.id))
    end
    for _, c in ipairs(value(conn.nodes) or {}) do
      thread.comments[#thread.comments + 1] = comment_from(c)
    end
    local nxt = next_cursor(conn)
    if nxt == cursor then
      break -- a cursor that does not move would loop forever
    end
    cursor = nxt
  end
  return true
end

--- Every review thread of a PR, in GitHub's order (by creation), each with all its
--- comments, oldest first.
---@param target NvimDiff.GitHub.Target Host, owner and repo; a fetched PR's `target`.
---@param number integer
---@return NvimDiff.GitHub.Thread[]? threads
---@return NvimDiff.GitHub.Error? err `invalid`, `not_found`, `not_authenticated`, or a
---failure to reach the API.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.fetch(target, number)
  if type(number) ~= "number" or number ~= math.floor(number) or number < 1 then
    return nil, errors.new("invalid", ("not a PR number: %s"):format(vim.inspect(number)))
  end
  local threads = {}
  local cursor
  repeat
    local vars = {
      { flag = "-f", name = "owner", value = target.owner },
      { flag = "-f", name = "name", value = target.repo },
      { flag = "-F", name = "number", value = number },
    }
    if cursor then
      vars[#vars + 1] = { flag = "-f", name = "cursor", value = cursor }
    end
    local data, err = cmd.graphql(target.host, THREADS_QUERY, vars)
    if not data then
      return nil, err
    end
    local repository = value(data.repository)
    local pr = repository and value(repository.pullRequest)
    if not pr then
      return nil, errors.new("not_found", ("PR #%d not found in %s/%s"):format(number, target.owner, target.repo))
    end
    local conn = value(pr.reviewThreads) or {}
    for _, node in ipairs(value(conn.nodes) or {}) do
      local thread = thread_from(node)
      local more = next_cursor(value(node.comments))
      if more then
        local ok, cerr = rest_of_comments(target.host, thread, more)
        if not ok then
          return nil, cerr
        end
      end
      threads[#threads + 1] = thread
    end
    local nxt = next_cursor(conn)
    if nxt == cursor then
      break
    end
    cursor = nxt
  until not cursor
  return threads
end

-- Resolving -------------------------------------------------------------------------------
--
-- GraphQL-only: REST has no resolved state. Both mutations take the thread's node id, as
-- read above. `resolutionReason` is never sent — it is recent, and GHES may not know it.
-- Each mutation returns the thread's state as GitHub now has it, so the caller updates what
-- it shows from GitHub's answer rather than assuming.

local RESOLVE = [[
mutation($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved viewerCanResolve viewerCanUnresolve resolvedBy { login } }
  }
}
]]

local UNRESOLVE = [[
mutation($id: ID!) {
  unresolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved viewerCanResolve viewerCanUnresolve resolvedBy { login } }
  }
}
]]

--- A thread's resolved state, as a mutation returned it.
---@class NvimDiff.GitHub.ResolvedState
---@field resolved boolean
---@field can_resolve boolean
---@field can_unresolve boolean
---@field resolved_by? string

---@param mutation string
---@param field string The mutation's name, which keys its payload.
---@param host string
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.GitHub.ResolvedState? state
---@return NvimDiff.GitHub.Error? err
local function set_resolved(mutation, field, host, thread)
  if thread.local_only or type(thread.id) ~= "string" or thread.id == "" then
    return nil, errors.new("invalid", "this thread has no GitHub thread id yet")
  end
  local data, err = cmd.graphql(host, mutation, { { flag = "-f", name = "id", value = thread.id } })
  if not data then
    return nil, err
  end
  local payload = value(data[field])
  local node = type(payload) == "table" and value(payload.thread)
  if type(node) ~= "table" or type(node.isResolved) ~= "boolean" then
    return nil, errors.new("api_error", "GitHub's reply did not describe the thread")
  end
  local by = value(node.resolvedBy)
  return {
    resolved = node.isResolved,
    can_resolve = node.viewerCanResolve == true,
    can_unresolve = node.viewerCanUnresolve == true,
    resolved_by = type(by) == "table" and value(by.login) or nil,
  }
end

--- Resolve a thread on GitHub.
---@param host string
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.GitHub.ResolvedState? state GitHub's view of the thread afterwards.
---@return NvimDiff.GitHub.Error? err `invalid` for a thread with no GitHub id
---(`local_only`); otherwise what GitHub said.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.resolve(host, thread)
  return set_resolved(RESOLVE, "resolveReviewThread", host, thread)
end

--- Unresolve a thread on GitHub.
---@param host string
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.GitHub.ResolvedState? state
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.unresolve(host, thread)
  return set_resolved(UNRESOLVE, "unresolveReviewThread", host, thread)
end

--- Copy a mutation's answer onto the thread.
---@param thread NvimDiff.GitHub.Thread
---@param state NvimDiff.GitHub.ResolvedState
function M.apply(thread, state)
  thread.resolved = state.resolved
  thread.can_resolve = state.can_resolve
  thread.can_unresolve = state.can_unresolve
  thread.resolved_by = state.resolved_by
end

return M
