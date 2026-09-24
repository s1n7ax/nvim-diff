--- Revision ranges: what `main...feature`, `main..feature` and `HEAD~3` mean as a diff.
---
--- Git's own `diff` semantics, resolved eagerly to two `Rev`s:
---
--- | expression    | mode         | left                        | right        |
--- | ------------- | ------------ | --------------------------- | ------------ |
--- | `a...b`       | `merge_base` | `git merge-base a b`        | `b`          |
--- | `a..b`        | `tip`        | `a`                         | `b`          |
--- | `a`           | `single`     | `a`                         | the worktree |
---
--- An empty side means `HEAD`, as in git. `merge_base` is what a GitHub PR shows;
--- `tip` is what a rebase will bring in, and `toggle` flips between them. Two bare
--- revisions (`pair`) take their mode from `revs.merge_base` in the config.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local rev = require("nvim-diff.git.rev")

local M = {}

---@alias NvimDiff.Git.RangeMode "merge_base"|"tip"|"single"

---@class NvimDiff.Git.RangeSpec
---@field mode NvimDiff.Git.RangeMode
---@field left string
---@field right? string Absent for `single`.

---@class NvimDiff.Git.Range
---@field spec NvimDiff.Git.RangeSpec What was asked for; `toggle` re-resolves from it.
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev

--- Split a range expression. Pure: nothing is resolved.
---@param expr string
---@return NvimDiff.Git.RangeSpec? spec
---@return NvimDiff.Git.Error? err `invalid` for an empty expression.
function M.parse(expr)
  vim.validate("expr", expr, "string")
  expr = vim.trim(expr)
  if expr == "" then
    return nil, errors.new("invalid", "empty revision range")
  end
  -- A ref name cannot contain `..`, so the first `...` or `..` is the operator.
  local a, b = expr:match("^(.-)%.%.%.(.*)$")
  if a then
    return { mode = "merge_base", left = a ~= "" and a or "HEAD", right = b ~= "" and b or "HEAD" }
  end
  a, b = expr:match("^(.-)%.%.(.*)$")
  if a then
    return { mode = "tip", left = a ~= "" and a or "HEAD", right = b ~= "" and b or "HEAD" }
  end
  return { mode = "single", left = expr }
end

--- Two bare revisions, compared the way `revs.merge_base` says.
---@param a string
---@param b string
---@return NvimDiff.Git.RangeSpec
function M.pair(a, b)
  local merge_base = require("nvim-diff.config").get().revs.merge_base
  return { mode = merge_base and "merge_base" or "tip", left = a, right = b }
end

--- The best common ancestor of two commits.
---@param repo NvimDiff.Git.Repo
---@param a NvimDiff.Git.Rev A `commit`.
---@param b NvimDiff.Git.Rev A `commit`.
---@return NvimDiff.Git.Rev? base Labelled `merge-base(a, b)`.
---@return NvimDiff.Git.Error? err `no_merge_base` for unrelated histories.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.merge_base(repo, a, b)
  local res, err = cmd.run(repo.toplevel, { "merge-base", a.oid, b.oid })
  if not res then
    return nil, err
  end
  local oid = vim.trim(res.stdout)
  if res.code ~= 0 or oid == "" then
    return nil,
      errors.new(
        "no_merge_base",
        ("%s and %s have no common ancestor"):format(rev.display(a), rev.display(b)),
        { stderr = res.stderr }
      )
  end
  return rev.commit(oid, ("merge-base(%s, %s)"):format(rev.display(a), rev.display(b)))
end

--- `imply_local`: when the right side is `HEAD`'s commit, diff the worktree instead, so
--- the pane is the live, editable file. Off by default, because it also pulls
--- uncommitted changes into a branch diff.
---@class NvimDiff.Git.ResolveOpts
---@field imply_local? boolean

--- Resolve a range to two revisions.
---@param repo NvimDiff.Git.Repo
---@param spec string|NvimDiff.Git.RangeSpec An expression for `parse`, or its result.
---@param opts? NvimDiff.Git.ResolveOpts
---@return NvimDiff.Git.Range? range
---@return NvimDiff.Git.Error? err `invalid`, `bad_revision`, `no_merge_base`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.resolve(repo, spec, opts)
  opts = opts or {}
  if type(spec) == "string" then
    local parsed, perr = M.parse(spec)
    if not parsed then
      return nil, perr
    end
    spec = parsed
  end

  local left, err = rev.resolve(repo, spec.left)
  if not left then
    return nil, err
  end
  if spec.mode == "single" then
    return { spec = spec, left = left, right = rev.worktree() }
  end

  local right
  right, err = rev.resolve(repo, spec.right)
  if not right then
    return nil, err
  end
  if spec.mode == "merge_base" then
    left, err = M.merge_base(repo, left, right)
    if not left then
      return nil, err
    end
  end

  if opts.imply_local then
    local head = rev.head(repo)
    if head and head.oid == right.oid then
      right = rev.worktree()
    end
  end
  return { spec = spec, left = left, right = right }
end

--- The same two revisions under the other mode: `a...b` becomes `a..b` and back.
---@param repo NvimDiff.Git.Repo
---@param range NvimDiff.Git.Range
---@param opts? NvimDiff.Git.ResolveOpts
---@return NvimDiff.Git.Range? range
---@return NvimDiff.Git.Error? err `invalid` for a single-revision range.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.toggle(repo, range, opts)
  local spec = range.spec
  if spec.mode == "single" then
    return nil, errors.new("invalid", "a single-revision diff has no merge-base to toggle")
  end
  local flipped = { mode = spec.mode == "merge_base" and "tip" or "merge_base", left = spec.left, right = spec.right }
  return M.resolve(repo, flipped, opts)
end

return M
