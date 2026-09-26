--- Finding the repository a path belongs to.
---
--- A `Repo` is a plain value — three absolute paths — not a cached object: the plugin
--- keeps no state, and discovery is one `rev-parse`. Every git function takes a `Repo`
--- and runs in its `toplevel`, so a repo-relative git path means the same thing to all
--- of them.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local path = require("nvim-diff.core.path")

local M = {}

---@class NvimDiff.Git.Repo
---@field toplevel string Root of the work tree.
---@field gitdir string This work tree's git directory (`.git`, or `.git/worktrees/<id>` in a linked worktree).
---@field common_dir string The git directory shared by all worktrees; its path keys the repository's review slots.

--- The repository containing `p` (a file or directory; the cwd when omitted).
---@param p? string
---@return NvimDiff.Git.Repo? repo
---@return NvimDiff.Git.Error? err `not_a_repository`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.discover(p)
  local dir = path.dir_of(p or vim.uv.cwd())
  if not path.is_dir(dir) then
    return nil, errors.new("not_a_repository", dir .. " does not exist")
  end
  -- `--git-common-dir` is relative to `dir` on git older than 2.31, and
  -- `--path-format=absolute` is newer than the declared floor, so resolve it here.
  local res, err = cmd.run(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir" })
  if not res then
    return nil, err
  end
  local lines = vim.split(vim.trim(res.stdout), "\n", { plain = true })
  if res.code ~= 0 or #lines ~= 3 or lines[1] == "" then
    return nil, errors.new("not_a_repository", dir .. " is not inside a git work tree", { stderr = res.stderr })
  end
  return {
    toplevel = path.normalize(lines[1]),
    gitdir = path.normalize(lines[2]),
    common_dir = path.normalize(lines[3], dir),
  }
end

--- The empty tree's object id for this repository — the left side of a root commit.
--- Not a constant: a SHA-256 repository has a different one.
---@param repo NvimDiff.Git.Repo
---@return string? oid
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.empty_tree(repo)
  local out, err = cmd.output(repo.toplevel, { "hash-object", "-t", "tree", "--stdin" }, { stdin = "" })
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

return M
