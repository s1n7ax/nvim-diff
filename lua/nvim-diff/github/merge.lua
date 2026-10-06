--- Merging a PR: merge, squash-and-merge or rebase-and-merge, over REST.
---
--- One call, `PUT /repos/{owner}/{repo}/pulls/{n}/merge`, carrying `merge_method` and the
--- head the review shows (`NvimDiff.GitHub.PR.head.oid`) as `sha`: when someone pushes
--- between the review opening and the merge, GitHub refuses with a 409 instead of merging
--- code the reviewer never saw. Which methods the PR's repository allows (its
--- `Allow merge commits / squash merging / rebase merging` settings) is GitHub's to
--- enforce — a disallowed method comes back as a 405, shown as the error's message.

local cmd = require("nvim-diff.github.cmd")
local errors = require("nvim-diff.github.error")

local M = {}

---@alias NvimDiff.GitHub.MergeMethod "merge"|"squash"|"rebase"

--- Every merge method, in the order a picker offers them, with its name for people.
---@type { method: NvimDiff.GitHub.MergeMethod, label: string }[]
M.METHODS = {
  { method = "merge", label = "Merge" },
  { method = "squash", label = "Squash and merge" },
  { method = "rebase", label = "Rebase and merge" },
}

--- The `M.METHODS` row for `method`.
---@param method string
---@return { method: NvimDiff.GitHub.MergeMethod, label: string }?
function M.info(method)
  for _, row in ipairs(M.METHODS) do
    if row.method == method then
      return row
    end
  end
  return nil
end

---@class NvimDiff.GitHub.Merge
---@field merged boolean Always true; GitHub only answers 200 on a merge.
---@field sha? string The merge commit SHA.
---@field message? string What GitHub said (`Pull Request successfully merged`).

--- Merge `pr` with `method`.
---@param pr NvimDiff.GitHub.PR
---@param method NvimDiff.GitHub.MergeMethod
---@return NvimDiff.GitHub.Merge? merge
---@return NvimDiff.GitHub.Error? err `invalid` for an unknown method (nothing is sent);
---otherwise whatever GitHub answered (405 for a disallowed method or a PR that is not
---mergeable, 409 when the head moved on).
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.merge(pr, method)
  local info = M.info(method)
  if not info then
    return nil, errors.new("invalid", ("not a merge method: %s"):format(vim.inspect(method)))
  end

  local target = pr.target
  local response, err =
    cmd.request(target.host, ("repos/%s/%s/pulls/%d/merge"):format(target.owner, target.repo, pr.number), {
      method = "PUT",
      vars = {
        { flag = "-f", name = "merge_method", value = method },
        { flag = "-f", name = "sha", value = pr.head.oid },
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
  return {
    merged = true,
    sha = type(data.sha) == "string" and data.sha or nil,
    message = type(data.message) == "string" and data.message or nil,
  }
end

return M
