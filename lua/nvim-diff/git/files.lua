--- Which files changed between two revisions, with stats and renames.
---
--- One `git diff --raw --numstat -z` per list: the raw records carry status, modes,
--- object ids and rename pairs; the numstat records that follow carry line counts. Both
--- are NUL-delimited, so no path is ever quoted or split on whitespace.
---
--- Rename detection is always on (`-M`), whatever `diff.renames` says, so a moved file is
--- one entry rather than a delete and an add. `--no-textconv` keeps the counts about the
--- bytes the blob layer will actually return.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local rev = require("nvim-diff.git.rev")

local M = {}

---@alias NvimDiff.Git.Status "A"|"C"|"D"|"M"|"R"|"T"|"U"|"X"|"?"

---@class NvimDiff.Git.FileChange
---@field path string Repo-relative git path on the right side.
---@field oldpath? string Path on the left side, for a rename or copy.
---@field status NvimDiff.Git.Status `?` is untracked.
---@field similarity? integer 0-100, for a rename or copy.
---@field additions? integer Nil for a binary or untracked file.
---@field deletions? integer
---@field binary boolean
---@field old_mode string `000000` when the file is new.
---@field new_mode string `000000` when the file is gone.
---@field old_oid string All zeros when the file is new.
---@field new_oid string All zeros when new, gone, or not yet hashed from the worktree.

---@class NvimDiff.Git.FilesOpts
---@field paths? string[] Limit to these git paths (pathspecs, literal).
---@field untracked? boolean With a `worktree` right side, list untracked files as `?`. Default true.

local ZERO_OID_PATTERN = "^0+$"

--- Parse `git diff --raw --numstat -z` output.
---@param out string
---@return NvimDiff.Git.FileChange[]
function M.parse(out)
  local fields = cmd.split_z(out)
  ---@type NvimDiff.Git.FileChange[]
  local entries = {}
  ---@type table<string, NvimDiff.Git.FileChange>
  local by_path = {}

  local i = 1
  while i <= #fields and fields[i]:sub(1, 1) == ":" do
    local old_mode, new_mode, old_oid, new_oid, status, score = fields[i]:match("^:(%d+) (%d+) (%x+) (%x+) (%u)(%d*)$")
    local entry
    if status == "R" or status == "C" then
      entry = { oldpath = fields[i + 1], path = fields[i + 2], similarity = tonumber(score) }
      i = i + 3
    else
      entry = { path = fields[i + 1] }
      i = i + 2
    end
    entry.status = status
    entry.old_mode, entry.new_mode, entry.old_oid, entry.new_oid = old_mode, new_mode, old_oid, new_oid
    entry.binary = false

    -- During a conflict `git diff` reports a path both as `U` and as a change against
    -- stage 2. It is one file, and `U` is the fact that matters.
    local seen = by_path[entry.path]
    if seen then
      if status == "U" then
        seen.status = "U"
      end
    else
      entries[#entries + 1] = entry
      by_path[entry.path] = entry
    end
  end

  while i <= #fields do
    local added, deleted, p = fields[i]:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
    if not added then
      break
    end
    if p == "" then
      -- A rename: the two paths follow as their own fields.
      p = fields[i + 2]
      i = i + 3
    else
      i = i + 1
    end
    local entry = by_path[p]
    if entry then
      if added == "-" then
        entry.binary = true
      else
        entry.additions, entry.deletions = tonumber(added), tonumber(deleted)
      end
    end
  end
  return entries
end

---@param left NvimDiff.Git.Rev
---@param right NvimDiff.Git.Rev
---@return string[]? args
---@return NvimDiff.Git.Error? err
local function diff_args(left, right)
  local args = { "diff", "--raw", "--numstat", "-z", "--no-abbrev", "-M", "--no-ext-diff", "--no-textconv" }
  if left.type == "commit" and right.type == "commit" then
    vim.list_extend(args, { left.oid, right.oid })
  elseif left.type == "commit" and right.type == "index" then
    vim.list_extend(args, { "--cached", left.oid })
  elseif left.type == "commit" and right.type == "worktree" then
    args[#args + 1] = left.oid
  elseif not (left.type == "index" and right.type == "worktree") then
    -- (index -> worktree is plain `git diff` and needs no revision argument.)
    return nil,
      errors.new(
        "invalid",
        ("cannot list changes from %s to %s; the left side must be older"):format(rev.display(left), rev.display(right))
      )
  end
  return args
end

---@param opts NvimDiff.Git.FilesOpts
---@param args string[]
local function add_paths(opts, args)
  if opts.paths and #opts.paths > 0 then
    args[#args + 1] = "--"
    for _, p in ipairs(opts.paths) do
      args[#args + 1] = ":(literal)" .. p
    end
  end
end

--- Untracked, non-ignored files, as `?` entries.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.FilesOpts
---@return NvimDiff.Git.FileChange[]? entries
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.untracked(repo, opts)
  opts = opts or {}
  local args = { "ls-files", "--others", "--exclude-standard", "-z" }
  add_paths(opts, args)
  local out, err = cmd.output(repo.toplevel, args)
  if not out then
    return nil, err
  end
  local zero = string.rep("0", 40)
  local entries = {}
  for _, p in ipairs(cmd.split_z(out)) do
    entries[#entries + 1] = {
      path = p,
      status = "?",
      binary = false,
      old_mode = "000000",
      new_mode = "000000",
      old_oid = zero,
      new_oid = zero,
    }
  end
  return entries
end

--- The files that differ from `left` to `right`, in git's path order, untracked last.
---
--- Supported pairs: commit→commit, commit→index, commit→worktree, index→worktree. Use
--- `rev.empty(repo)` as the left side for a root commit or an unborn branch.
---@param repo NvimDiff.Git.Repo
---@param left NvimDiff.Git.Rev
---@param right NvimDiff.Git.Rev
---@param opts? NvimDiff.Git.FilesOpts
---@return NvimDiff.Git.FileChange[]? entries
---@return NvimDiff.Git.Error? err `invalid` for an unsupported pair, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.diff(repo, left, right, opts)
  opts = opts or {}
  local args, err = diff_args(left, right)
  if not args then
    return nil, err
  end
  add_paths(opts, args)
  local out
  out, err = cmd.output(repo.toplevel, args)
  if not out then
    return nil, err
  end
  local entries = M.parse(out)

  if right.type == "worktree" and opts.untracked ~= false then
    local extra
    extra, err = M.untracked(repo, opts)
    if not extra then
      return nil, err
    end
    vim.list_extend(entries, extra)
  end
  return entries
end

---@class NvimDiff.Git.WorkingStatus
---@field staged NvimDiff.Git.FileChange[] HEAD (or the empty tree) to the index.
---@field unstaged NvimDiff.Git.FileChange[] The index to the worktree, untracked included.
---@field conflicted string[] Paths with unmerged entries.

--- Everything `git status` would show, as two lists — including on an unborn branch.
---@param repo NvimDiff.Git.Repo
---@param opts? NvimDiff.Git.FilesOpts
---@return NvimDiff.Git.WorkingStatus? status
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.status(repo, opts)
  local head = rev.head(repo)
  local err
  if not head then
    head, err = rev.empty(repo)
    if not head then
      return nil, err
    end
  end
  local staged, unstaged
  staged, err = M.diff(repo, head, rev.index(), opts)
  if not staged then
    return nil, err
  end
  unstaged, err = M.diff(repo, rev.index(), rev.worktree(), opts)
  if not unstaged then
    return nil, err
  end

  local conflicted, seen = {}, {}
  for _, list in ipairs({ unstaged, staged }) do
    for _, entry in ipairs(list) do
      if entry.status == "U" and not seen[entry.path] then
        seen[entry.path] = true
        conflicted[#conflicted + 1] = entry.path
      end
    end
  end
  return { staged = staged, unstaged = unstaged, conflicted = conflicted }
end

--- Whether an object id is the all-zeros placeholder git uses for "no object".
---@param oid string
---@return boolean
function M.is_zero_oid(oid)
  return oid:match(ZERO_OID_PATTERN) ~= nil
end

return M
