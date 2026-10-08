--- The branch checked out, and where a push sends it: what `:NvimDiffPR` with no number
--- looks for a PR from (`github/pr.lua` `for_branch`).

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")

local M = {}

---@class NvimDiff.Git.Branch
---@field name string `feature` for `refs/heads/feature`.
---@field remote? string `branch.<name>.remote`: the remote it tracks, a name or a URL.
--- `branch.<name>.merge`: the ref it tracks there, `refs/heads/main` — or
--- `refs/pull/42/head` for a branch `gh pr checkout` made.
---@field merge? string
--- The remote `git push` sends it to — `branch.<name>.pushRemote`, else `remote.pushDefault`,
--- else `branch.<name>.remote` — a name or a URL. Nil when none is set.
---@field push_remote? string
--- `@{push}`, the remote-tracking ref of what a push updates: `refs/remotes/origin/feature`.
--- Nil when git cannot say — no such tracking ref yet, or `push.default=simple` refusing a
--- branch that tracks a ref of another name.
---@field push_ref? string

---@param s string
---@return string?
local function non_empty(s)
  return s ~= "" and s or nil
end

--- The branch checked out in `repo`.
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Branch? branch
---@return NvimDiff.Git.Error? err `invalid` on a detached `HEAD`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.current(repo)
  -- The full ref, not `--short`: that one turns `feature` into `heads/feature` when a tag
  -- of the same name exists.
  local res, err = cmd.run(repo.toplevel, { "symbolic-ref", "--quiet", "HEAD" })
  if not res then
    return nil, err
  end
  local ref = vim.trim(res.stdout)
  local name = ref:match("^refs/heads/(.+)$")
  if res.code ~= 0 or not name then
    return nil, errors.new("invalid", "HEAD is detached: no branch is checked out", { stderr = res.stderr })
  end

  -- No line on an unborn branch: nothing to push yet.
  local out
  out, err = cmd.output(repo.toplevel, { "for-each-ref", "--format=%(push:remotename)%00%(push)", ref })
  if not out then
    return nil, err
  end
  local push = vim.split(out:match("^[^\n]*"), "\0", { plain = true })

  -- Every branch's settings, matched here: a branch name is not a safe regular expression.
  out, err = cmd.output(repo.toplevel, { "config", "-z", "--get-regexp", [[^branch\.]] }, { ok_codes = { 1 } })
  if not out then
    return nil, err
  end
  local settings = {}
  for _, entry in ipairs(cmd.split_z(out)) do
    local key, value = entry:match("^([^\n]*)\n(.*)$")
    if key then
      settings[key] = value
    end
  end
  local prefix = "branch." .. name .. "."
  return {
    name = name,
    remote = non_empty(settings[prefix .. "remote"] or ""),
    merge = non_empty(settings[prefix .. "merge"] or ""),
    push_remote = non_empty(push[1] or ""),
    push_ref = non_empty(push[2] or ""),
  }
end

return M
