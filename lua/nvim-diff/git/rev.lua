--- Revisions as values.
---
--- A `Rev` names one side of a diff. There are three kinds, and every other git module
--- switches on `type` rather than on strings:
---
--- - `commit` — an object id, fully resolved. Usually a commit; the empty tree is a
---   `commit` too, because everywhere git takes a tree-ish it behaves like a root parent.
--- - `index`  — the staging area, at a stage (0 normally; 1/2/3 base/ours/theirs during a
---   conflict).
--- - `worktree` — the files on disk.
---
--- Symbolic names (`main`, `HEAD~2`) are resolved once, eagerly, so a diff never shifts
--- under the user because a branch moved while it was open. The name survives as `label`.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")

local M = {}

---@alias NvimDiff.Git.RevType "commit"|"index"|"worktree"

---@class NvimDiff.Git.Rev
---@field type NvimDiff.Git.RevType
---@field oid? string Full object id, for `commit`.
---@field stage? integer 0-3, for `index`.
---@field label? string What the user typed, for display.

---@param oid string
---@param label? string
---@return NvimDiff.Git.Rev
function M.commit(oid, label)
  return { type = "commit", oid = oid, label = label }
end

---@param stage? integer Defaults to 0.
---@return NvimDiff.Git.Rev
function M.index(stage)
  return { type = "index", stage = stage or 0 }
end

---@return NvimDiff.Git.Rev
function M.worktree()
  return { type = "worktree" }
end

--- The empty tree, as the left side of a root commit or an added file.
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Rev? rev
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.empty(repo)
  local oid, err = require("nvim-diff.git.repo").empty_tree(repo)
  if not oid then
    return nil, err
  end
  return M.commit(oid, "(empty)")
end

---@param a NvimDiff.Git.Rev
---@param b NvimDiff.Git.Rev
---@return boolean
function M.eq(a, b)
  return a.type == b.type and a.oid == b.oid and (a.stage or 0) == (b.stage or 0)
end

--- A short, stable name: an abbreviated oid, `:0`, or `worktree`. Used in buffer names.
---@param rev NvimDiff.Git.Rev
---@return string
function M.id(rev)
  if rev.type == "commit" then
    return rev.oid:sub(1, 12)
  elseif rev.type == "index" then
    return ":" .. (rev.stage or 0)
  end
  return "worktree"
end

--- What to show a person: the label when there is one.
---@param rev NvimDiff.Git.Rev
---@return string
function M.display(rev)
  if rev.label then
    return rev.label
  elseif rev.type == "index" then
    return (rev.stage or 0) == 0 and "index" or ("index stage " .. rev.stage)
  end
  return M.id(rev)
end

--- The object name `git cat-file` takes for `path` at `rev`, or nil for the work tree.
---@param rev NvimDiff.Git.Rev
---@param git_path string
---@return string?
function M.object(rev, git_path)
  if rev.type == "commit" then
    return rev.oid .. ":" .. git_path
  elseif rev.type == "index" then
    return ":" .. (rev.stage or 0) .. ":" .. git_path
  end
  return nil
end

--- Resolve a revision expression to a commit.
---@param repo NvimDiff.Git.Repo
---@param spec string Anything `git rev-parse` accepts that names a commit.
---@return NvimDiff.Git.Rev? rev A `commit` labelled with `spec`.
---@return NvimDiff.Git.Error? err `bad_revision`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.resolve(repo, spec)
  vim.validate("spec", spec, "string")
  -- `--end-of-options` is newer than the declared git floor; refusing a leading dash is
  -- the portable way to keep a revision from being read as an option.
  if spec == "" or spec:sub(1, 1) == "-" then
    return nil, errors.new("bad_revision", ("%q is not a revision"):format(spec))
  end
  local res, err = cmd.run(repo.toplevel, { "rev-parse", "--verify", "--quiet", spec .. "^{commit}" })
  if not res then
    return nil, err
  end
  local oid = vim.trim(res.stdout)
  if res.code ~= 0 or oid == "" then
    return nil, errors.new("bad_revision", ("%q does not name a commit"):format(spec), { stderr = res.stderr })
  end
  return M.commit(oid, spec)
end

--- `HEAD`, or a `bad_revision` error on an unborn branch.
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Rev? rev
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.head(repo)
  return M.resolve(repo, "HEAD")
end

return M
