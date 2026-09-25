--- Fetching a PR's identifying data: SHAs, base/head refs, fork ownership — the facts later
--- PR-review steps (worktree checkout, viewed marks, comment threads) key off.
---
--- Never the diff itself. Per the research result, `/pulls/{n}/files` paginates, truncates
--- large patches and caps at 3000 files, so the diff is always computed locally with git
--- from a worktree once one exists — this module asks GitHub only for the PR's own fields,
--- over GraphQL, the read half of "reads go over GraphQL, writes over REST".

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")
local host_mod = require("nvim-diff.github.host")

local M = {}

--- Static: no value from a caller is ever interpolated into this text. `owner`, `name` and
--- `number` travel as GraphQL variables instead (see `M.fetch`).
local QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      number
      title
      url
      state
      isDraft
      isCrossRepository
      maintainerCanModify
      headRefName
      headRefOid
      headRepository {
        name
        owner { login }
        url
      }
      baseRefName
      baseRefOid
      baseRepository {
        name
        owner { login }
        url
      }
    }
  }
}
]]

---@class NvimDiff.GitHub.PRSide
---@field ref string Branch name.
---@field oid string Commit SHA.
---@field owner? string Nil when the side's repository was deleted or renamed away.
---@field repo? string
---@field url? string

---@class NvimDiff.GitHub.PR
---@field id string GraphQL node id — what `markFileAsViewed` and thread mutations key on.
---@field number integer
---@field title string
---@field url string
---@field state "OPEN"|"CLOSED"|"MERGED"
---@field draft boolean
---@field cross_repository boolean Head is a fork of base; worktree checkout needs a second remote.
---@field maintainer_can_modify boolean Whether a maintainer of the base repo may push to the head branch.
---@field base NvimDiff.GitHub.PRSide
---@field head NvimDiff.GitHub.PRSide
---@field target NvimDiff.GitHub.Target Host, owner and repo the PR was fetched from.

---@param ref string
---@param oid string
---@param repository table?
---@return NvimDiff.GitHub.PRSide
local function side(ref, oid, repository)
  return {
    ref = ref,
    oid = oid,
    owner = repository and repository.owner and repository.owner.login or nil,
    repo = repository and repository.name or nil,
    url = repository and repository.url or nil,
  }
end

---@param node table Raw GraphQL `pullRequest` object.
---@param target NvimDiff.GitHub.Target
---@return NvimDiff.GitHub.PR
local function from_graphql(node, target)
  return {
    id = node.id,
    number = node.number,
    title = node.title,
    url = node.url,
    state = node.state,
    draft = node.isDraft == true,
    cross_repository = node.isCrossRepository == true,
    maintainer_can_modify = node.maintainerCanModify == true,
    base = side(node.baseRefName, node.baseRefOid, node.baseRepository),
    head = side(node.headRefName, node.headRefOid, node.headRepository),
    target = target,
  }
end
M._from_graphql = from_graphql

--- The PR's identifying data.
---@param repo NvimDiff.Git.Repo Repository to resolve the GitHub host/owner/repo from.
---@param number integer
---@param opts? NvimDiff.GitHub.ResolveOpts
---@return NvimDiff.GitHub.PR? pr
---@return NvimDiff.GitHub.Error? err `invalid`, `no_remote`, `bad_remote`, `not_found`,
---`not_authenticated`, or a failure to reach the API.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.fetch(repo, number, opts)
  if type(number) ~= "number" or number ~= math.floor(number) or number < 1 then
    return nil, errors.new("invalid", ("not a PR number: %s"):format(vim.inspect(number)))
  end

  local target, err = host_mod.resolve(repo, opts)
  if not target then
    return nil, err
  end

  local data
  data, err = cmd.graphql(target.host, QUERY, {
    { flag = "-f", name = "owner", value = target.owner },
    { flag = "-f", name = "name", value = target.repo },
    { flag = "-F", name = "number", value = number },
  })
  if not data then
    return nil, err
  end

  local node = data.repository and data.repository.pullRequest
  if not node then
    return nil, errors.new("not_found", ("PR #%d not found in %s/%s"):format(number, target.owner, target.repo))
  end
  return from_graphql(node, target)
end

return M
