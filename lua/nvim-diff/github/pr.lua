--- Fetching a PR's identifying data: SHAs, base/head refs, fork ownership — the facts later
--- PR-review steps (worktree checkout, viewed marks, comment threads) key off.
---
--- Never the diff itself. Per the research result, `/pulls/{n}/files` paginates, truncates
--- large patches and caps at 3000 files, so the diff is always computed locally with git
--- from a worktree once one exists — this module asks GitHub only for the PR's own fields,
--- over GraphQL, the read half of "reads go over GraphQL, writes over REST". The one REST
--- read is `for_branch`'s, finding the PRs from a branch (it says why).

local branch_mod = require("nvim-diff.git.branch")
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

---@class NvimDiff.GitHub.PRSummary
---@field number integer
---@field title string
---@field state "OPEN"|"CLOSED"|"MERGED"
---@field draft boolean
---@field base string The base branch.

---@class NvimDiff.GitHub.BranchPRs
---@field branch string The branch checked out.
---@field head? string What was looked for, `owner:branch`. Nil when `number` is set.
--- The branch tracks `refs/pull/<n>/head` of the PR's own repository, as `gh pr checkout`
--- sets up for a PR it cannot push to: PR `n`, nothing looked up.
---@field number? integer
---@field prs NvimDiff.GitHub.PRSummary[] Every PR from `head`, open or not, newest first.

---@param owner? string
---@param name? string
---@param target NvimDiff.GitHub.Target
---@return boolean
local function is_target(owner, name, target)
  return owner ~= nil and name ~= nil and owner:lower() == target.owner:lower() and name:lower() == target.repo:lower()
end

--- The PRs from the branch checked out in `repo`. The head looked for is the branch on the
--- repository a push sends it to — `pushRemote`, `remote.pushDefault`, `branch.<b>.remote`,
--- else `opts.remote` — under the name the push gives it (`@{push}`), else its own name:
--- the rule `gh pr view` follows.
---
--- Over REST, not GraphQL: `GET /pulls?head=owner:branch` matches the head's owner on
--- GitHub's side, where GraphQL's `pullRequests(headRefName:)` takes only the branch — on
--- `main` that pages through every fork's `main`. One page of 100 is plenty for one head.
---@param repo NvimDiff.Git.Repo
---@param opts? NvimDiff.GitHub.ResolveOpts
---@return NvimDiff.GitHub.BranchPRs? found
---@return NvimDiff.GitHub.Error|NvimDiff.Git.Error|nil err `invalid` on a detached `HEAD`,
---`no_remote`, `bad_remote`, `not_authenticated`, or a failure to reach the API.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.for_branch(repo, opts)
  local remote = opts and opts.remote or "origin"
  local target, err = host_mod.resolve(repo, opts)
  if not target then
    return nil, err
  end
  local branch, git_err = branch_mod.current(repo)
  if not branch then
    return nil, git_err
  end

  local number = tonumber(branch.merge and branch.merge:match("^refs/pull/(%d+)/head$"))
  if number then
    local owner, name = host_mod.repository(repo, branch.remote or remote)
    if is_target(owner, name, target) then
      return { branch = branch.name, number = number, prs = {} }
    end
  end

  local push_remote = branch.push_remote or remote
  local owner = host_mod.repository(repo, push_remote) or target.owner
  local name = branch.push_ref and branch.push_ref:match("^refs/remotes/" .. vim.pesc(push_remote) .. "/(.+)$")
  local head = ("%s:%s"):format(owner, name or branch.name)

  local response
  response, err = cmd.request(target.host, ("repos/%s/%s/pulls"):format(target.owner, target.repo), {
    method = "GET",
    vars = {
      { flag = "-f", name = "head", value = head },
      { flag = "-f", name = "state", value = "all" },
      { flag = "-F", name = "per_page", value = 100 },
    },
  })
  if not response then
    return nil, err
  end
  local data
  data, err = cmd.classify(response)
  if not data then
    return nil, err
  end

  local prs = {}
  for _, node in ipairs(data) do
    if type(node) == "table" and type(node.number) == "number" then
      local state = type(node.merged_at) == "string" and "MERGED" or node.state == "open" and "OPEN" or "CLOSED"
      prs[#prs + 1] = {
        number = node.number,
        title = type(node.title) == "string" and node.title or "",
        state = state,
        draft = node.draft == true,
        base = type(node.base) == "table" and node.base.ref or "?",
      }
    end
  end
  return { branch = branch.name, head = head, prs = prs }
end

return M
