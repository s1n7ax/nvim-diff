--- PR worktrees: `<common git dir>/nvim-diff/pr-<n>`.
---
--- A PR is checked out into its own detached worktree so LSP, tests and debugging see
--- the PR's code while the user's branch and uncommitted changes are never touched.
---
--- Ownership is recorded in git itself, not in a state file: a worktree is locked with
--- the reason `nvim-diff pid <pid>` while a review has it open. The orphan prune — at
--- startup, and before every `add` — removes `pr-*` worktrees that are unlocked or whose
--- owning Neovim is gone, and leaves a second running Neovim's review alone. The matcher
--- is `health.parse_orphans`, shared with `:checkhealth`.
---
--- Removing discards anything in the worktree: ending a review ends its checkout.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local path = require("nvim-diff.core.path")

local M = {}

--- Where PR `number`'s worktree lives. It is inside the common git directory, so it is
--- invisible to `git status` and shared by every worktree of the repository.
---@param repo NvimDiff.Git.Repo
---@param number integer
---@return string
function M.path(repo, number)
  vim.validate("number", number, "number")
  return path.join(repo.common_dir, "nvim-diff", ("pr-%d"):format(number))
end

---@param repo NvimDiff.Git.Repo
---@return string? porcelain
---@return NvimDiff.Git.Error? err
local function list_porcelain(repo)
  return cmd.output(repo.toplevel, { "worktree", "list", "--porcelain" })
end

---@param repo NvimDiff.Git.Repo
---@param wt_path string
---@return boolean
local function is_registered(repo, wt_path)
  local porcelain = list_porcelain(repo)
  for listed in (porcelain or ""):gmatch("worktree ([^\n]+)") do
    if path.real(listed) == path.real(wt_path) then
      return true
    end
  end
  return false
end

--- Remove a worktree by path, locked or not, and whatever state its directory is in.
---@param repo NvimDiff.Git.Repo
---@param wt_path string
---@return boolean? ok
---@return NvimDiff.Git.Error? err
local function remove_path(repo, wt_path)
  local managed = path.join(repo.common_dir, "nvim-diff")
  if not path.is_under(path.real(wt_path), path.real(managed)) then
    return nil, errors.new("invalid", wt_path .. " is not a nvim-diff worktree")
  end
  if is_registered(repo, wt_path) then
    if path.exists(wt_path) then
      -- `--force` twice: once for local modifications, once for our own lock.
      local _, err = cmd.output(repo.toplevel, { "worktree", "remove", "--force", "--force", wt_path })
      if err then
        return nil, err
      end
    else
      -- The directory is gone but git still has it; a locked entry survives `prune`.
      cmd.output(repo.toplevel, { "worktree", "unlock", wt_path })
    end
  end
  local _, err = cmd.output(repo.toplevel, { "worktree", "prune" })
  if err then
    return nil, err
  end
  if path.exists(wt_path) then
    vim.fn.delete(wt_path, "rf")
  end
  return true
end

--- Remove every orphaned PR worktree in `repo`.
---@param repo NvimDiff.Git.Repo
---@return string[]? removed Paths that were removed.
---@return NvimDiff.Git.Error? err The first failure; earlier removals stand.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.prune_orphans(repo)
  local porcelain, err = list_porcelain(repo)
  if not porcelain then
    return nil, err
  end
  local removed = {}
  for _, orphan in ipairs(require("nvim-diff.health").parse_orphans(porcelain)) do
    local ok, rm_err = remove_path(repo, path.normalize(orphan))
    if not ok then
      return nil, rm_err
    end
    removed[#removed + 1] = orphan
  end
  return removed
end

--- Check out `commit` into PR `number`'s worktree, detached, and lock it to this Neovim.
--- A worktree already there is replaced: the review starts from a clean checkout.
---@param repo NvimDiff.Git.Repo
---@param number integer
---@param commit NvimDiff.Git.Rev A `commit`; the PR head must already be fetched.
---@return string? path
---@return NvimDiff.Git.Error? err `invalid` for a non-commit, or git's failure (unknown commit, disk full, stale lock).
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.add(repo, number, commit)
  if commit.type ~= "commit" then
    return nil, errors.new("invalid", "a PR worktree needs a commit, not the " .. commit.type)
  end
  local _, err = M.prune_orphans(repo)
  if err then
    return nil, err
  end
  local wt_path = M.path(repo, number)
  local ok
  ok, err = remove_path(repo, wt_path)
  if not ok then
    return nil, err
  end

  vim.fn.mkdir(vim.fs.dirname(wt_path), "p")
  _, err = cmd.output(repo.toplevel, { "worktree", "add", "--detach", wt_path, commit.oid })
  if err then
    return nil, err
  end
  -- `worktree add --reason` is newer than the declared git floor, hence a second call. A
  -- concurrent prune in the gap would see an unlocked worktree; the window is one process.
  local reason = require("nvim-diff.health").WORKTREE_LOCK_REASON:format(vim.fn.getpid())
  _, err = cmd.output(repo.toplevel, { "worktree", "lock", "--reason", reason, wt_path })
  if err then
    remove_path(repo, wt_path)
    return nil, err
  end
  return wt_path
end

--- Remove PR `number`'s worktree. Removing one that does not exist is not an error.
---@param repo NvimDiff.Git.Repo
---@param number integer
---@return boolean? ok
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.remove(repo, number)
  return remove_path(repo, M.path(repo, number))
end

--- Whether the startup prune has run this session. Tests reset it.
M.startup_pruned = false

--- Prune orphans in the repository at the cwd, once per session, in the background.
--- Outside a repository it does nothing. Called from `setup()`.
---@return NvimDiff.Job.Task? task Nil when it already ran.
function M.prune_on_startup()
  if M.startup_pruned then
    return nil
  end
  M.startup_pruned = true
  local job = require("nvim-diff.core.job")
  local log = require("nvim-diff.core.log")
  return job.task(function()
    local repo = require("nvim-diff.git.repo").discover()
    if not repo then
      return {}
    end
    local removed, err = M.prune_orphans(repo)
    if not removed then
      log.warn("could not remove leftover PR worktrees: %s", tostring(err))
      return {}
    end
    if #removed > 0 then
      log.info("removed %d leftover PR worktree(s)", #removed)
    end
    return removed
  end, function() end)
end

return M
