--- Per-file viewed state of a PR: the "Viewed" checkbox on GitHub's Files tab.
---
--- GraphQL-only, both ways: REST has no viewed state at all. The read is
--- `pullRequest.files { path viewerViewedState }`, paginated 100 at a time; the writes are
--- `markFileAsViewed` / `unmarkFileAsViewed`, which take the PR's **node id**
--- (`NvimDiff.GitHub.PR.id`), not its number.
---
--- GitHub's `FileViewedState` maps onto the file panel's `NvimDiff.Viewed`:
---
--- | GitHub      | panel       |
--- | ----------- | ----------- |
--- | `VIEWED`    | `viewed`    |
--- | `UNVIEWED`  | `unviewed`  |
--- | `DISMISSED` | `rechanged` — marked viewed, then a new commit touched the file |
---
--- Nothing is cached: GitHub is the only source of truth, and a review refetches on open.

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")

local M = {}

--- Static; `owner`, `name`, `number` and the page cursor travel as variables.
local FILES_QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      files(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { path viewerViewedState }
      }
    }
  }
}
]]

local MARK = [[
mutation($id: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $id, path: $path }) { clientMutationId }
}
]]

local UNMARK = [[
mutation($id: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $id, path: $path }) { clientMutationId }
}
]]

--- GitHub's state to the panel's.
---@type table<string, NvimDiff.Viewed>
M.STATE = {
  VIEWED = "viewed",
  UNVIEWED = "unviewed",
  DISMISSED = "rechanged",
}

--- A runaway-pagination guard: 100 pages is 10,000 files, over GitHub's own 3,000 cap.
local MAX_PAGES = 100

--- Every file's viewed state, by path.
---@param pr NvimDiff.GitHub.PR
---@return table<string, NvimDiff.Viewed>? states Paths GitHub does not list are absent.
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.fetch(pr)
  local target = pr.target
  local states = {}
  local after
  for _ = 1, MAX_PAGES do
    local vars = {
      { flag = "-f", name = "owner", value = target.owner },
      { flag = "-f", name = "name", value = target.repo },
      { flag = "-F", name = "number", value = pr.number },
    }
    if after then
      vars[#vars + 1] = { flag = "-f", name = "after", value = after }
    end
    local data, err = cmd.graphql(target.host, FILES_QUERY, vars)
    if not data then
      return nil, err
    end
    -- A JSON null decodes to `vim.NIL`, which is truthy: check for tables, not for nil.
    local repository = type(data.repository) == "table" and data.repository or {}
    local node = type(repository.pullRequest) == "table" and repository.pullRequest or {}
    local files = node.files
    if type(files) ~= "table" then
      return nil, errors.new("not_found", ("PR #%d has no file list"):format(pr.number))
    end
    for _, file in ipairs(type(files.nodes) == "table" and files.nodes or {}) do
      if type(file) == "table" and type(file.path) == "string" then
        states[file.path] = M.STATE[file.viewerViewedState] or "unviewed"
      end
    end
    local info = type(files.pageInfo) == "table" and files.pageInfo or {}
    if info.hasNextPage ~= true or type(info.endCursor) ~= "string" then
      return states
    end
    after = info.endCursor
  end
  return nil, errors.new("api_error", ("PR #%d: file list did not end after %d pages"):format(pr.number, MAX_PAGES))
end

---@param mutation string
---@param pr NvimDiff.GitHub.PR
---@param git_path string
---@return boolean? ok
---@return NvimDiff.GitHub.Error? err
local function send(mutation, pr, git_path)
  local data, err = cmd.graphql(pr.target.host, mutation, {
    { flag = "-f", name = "id", value = pr.id },
    { flag = "-f", name = "path", value = git_path },
  })
  if not data then
    return nil, err
  end
  return true
end

--- Mark a file viewed on GitHub.
---@param pr NvimDiff.GitHub.PR
---@param git_path string
---@return boolean? ok
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.mark(pr, git_path)
  return send(MARK, pr, git_path)
end

--- Clear a file's viewed mark on GitHub.
---@param pr NvimDiff.GitHub.PR
---@param git_path string
---@return boolean? ok
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.unmark(pr, git_path)
  return send(UNMARK, pr, git_path)
end

return M
