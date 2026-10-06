--- Getting a PR's commits into the local object store.
---
--- A PR's head usually is not in the user's clone — a fork's branch never is — so before
--- the worktree can be checked out the commits are fetched from the remote the PR was
--- looked up on. GitHub publishes every PR's head as `refs/pull/<n>/head` on the base
--- repository, forks included, so one remote serves every PR.
---
--- Nothing is written to the user's ref namespace: the fetch has no destination, so it
--- lands in `FETCH_HEAD` only, and the plugin keeps no local state. The head commit stays
--- reachable through the review slot's own `HEAD` until the slot holds another PR; the base
--- commit is only needed for the merge-base, which is computed straight after.
---
--- No fetch happens when every commit is already present.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")

local M = {}

--- A network call, so far longer than a local command's `git.timeout_ms`.
M.TIMEOUT_MS = 120000

--- Whether `oid` names a commit present locally.
---@param repo NvimDiff.Git.Repo
---@param oid string
---@return boolean
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.has_commit(repo, oid)
  if oid == "" or oid:sub(1, 1) == "-" then
    return false
  end
  local res = cmd.run(repo.toplevel, { "cat-file", "-e", oid .. "^{commit}" })
  return res ~= nil and res.code == 0
end

---@param repo NvimDiff.Git.Repo
---@param oids string[]
---@return string[] missing
local function missing(repo, oids)
  local out = {}
  for _, oid in ipairs(oids) do
    if not M.has_commit(repo, oid) then
      out[#out + 1] = oid
    end
  end
  return out
end

---@param repo NvimDiff.Git.Repo
---@param remote string
---@param refspecs string[]
---@return boolean? ok
---@return NvimDiff.Git.Error? err
local function fetch(repo, remote, refspecs)
  -- An empty `--refmap` stops the opportunistic update of `refs/remotes/<remote>/*` that a
  -- configured remote would otherwise get when a branch is fetched by name.
  local args = { "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--refmap=", remote }
  vim.list_extend(args, refspecs)
  -- `log` only adds `-c gc.auto=0`: a fetch must not kick off an auto-gc either.
  local _, err = cmd.output(repo.toplevel, args, { log = true, timeout_ms = M.TIMEOUT_MS })
  if err then
    return nil, err
  end
  return true
end

--- Make every commit in `oids` present locally. When any is missing, `refs` are fetched
--- from `remote`; a commit still missing after that (the branch moved on since GitHub
--- answered) is fetched by its id, which GitHub serves for any reachable commit.
---@param repo NvimDiff.Git.Repo
---@param remote string A configured remote's name.
---@param refs string[] Full ref names on the remote, e.g. `refs/pull/7/head`.
---@param oids string[] Full commit ids.
---@return boolean? ok
---@return NvimDiff.Git.Error? err `not_found` naming the commits that could not be had,
---or git's failure to fetch (no network, no credentials, no such ref).
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.commits(repo, remote, refs, oids)
  if remote == "" or remote:sub(1, 1) == "-" then
    return nil, errors.new("invalid", ("%q is not a remote"):format(remote))
  end
  local want = missing(repo, oids)
  if #want == 0 then
    return true
  end
  local ok, err = fetch(repo, remote, refs)
  if not ok then
    return nil, err
  end
  want = missing(repo, want)
  if #want == 0 then
    return true
  end
  -- Best effort: an older server refuses an unadvertised id, and the error below says why.
  fetch(repo, remote, want)
  want = missing(repo, want)
  if #want > 0 then
    return nil, errors.new("not_found", ("could not fetch %s from %s"):format(table.concat(want, ", "), remote))
  end
  return true
end

return M
