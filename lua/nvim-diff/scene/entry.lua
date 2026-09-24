--- File entries: one changed file in a view, and the list a file panel shows.
---
--- A `FileEntry` wraps the git layer's `FileChange` with what the view knows about it:
--- whether it is too big to load unasked, whether the user asked anyway, and (in a PR
--- review) its viewed state. Entries are keyed on `(path, oldpath)`, and a refresh
--- **morphs** the list through an edit script on that key instead of rebuilding it, so an
--- entry that did not change is the same Lua object afterwards — with its deferral, forced
--- load and viewed state intact.

local blob = require("nvim-diff.git.blob")
local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")

local M = {}

---@alias NvimDiff.Viewed "viewed"|"unviewed"|"rechanged"

---@class NvimDiff.FileEntry
---@field key string `path NUL oldpath`.
---@field change NvimDiff.Git.FileChange
---@field path string
---@field oldpath? string
---@field stamp string What the morph compares to decide whether the file changed.
--- Line count of the larger side, when it was measured. Only files that could be over the
--- threshold are measured, so nil means "within it", not "unknown".
---@field lines? integer
---@field deferred boolean Over the line threshold: listed with its stats, loaded only when asked.
---@field forced boolean The user asked to load it despite the threshold.
--- Viewed state in a PR review; nil outside one. `rechanged` is GitHub's DISMISSED: viewed,
--- then un-viewed by GitHub because a new commit touched the file.
---@field viewed? NvimDiff.Viewed

---@alias NvimDiff.EditOp
---| { op: "keep", entry: NvimDiff.FileEntry }
---| { op: "update", entry: NvimDiff.FileEntry, previous: NvimDiff.Git.FileChange }
---| { op: "insert", entry: NvimDiff.FileEntry }
---| { op: "delete", entry: NvimDiff.FileEntry }

--- The morph key.
---@param change NvimDiff.Git.FileChange
---@return string
function M.key(change)
  return change.path .. "\0" .. (change.oldpath or "")
end

local STAMP_FIELDS =
  { "status", "old_mode", "new_mode", "old_oid", "new_oid", "additions", "deletions", "similarity", "binary" }

--- The default stamp: every field of the change git reported. A worktree file's content
--- is not hashed by `git diff` (its oid is all zeros), so views over the worktree pass a
--- stamp that adds the file's stat.
---@param change NvimDiff.Git.FileChange
---@return string
function M.stamp(change)
  local parts = {}
  for i, field in ipairs(STAMP_FIELDS) do
    parts[i] = tostring(change[field])
  end
  return table.concat(parts, "\0")
end

---@param change NvimDiff.Git.FileChange
---@param stamp string
---@return NvimDiff.FileEntry
local function new_entry(change, stamp)
  return {
    key = M.key(change),
    change = change,
    path = change.path,
    oldpath = change.oldpath,
    stamp = stamp,
    deferred = false,
    forced = false,
  }
end

---@class NvimDiff.FileList
---@field entries NvimDiff.FileEntry[] In git's order.
---@field by_key table<string, NvimDiff.FileEntry>
---@field stamp fun(change: NvimDiff.Git.FileChange): string
local List = {}
List.__index = List

---@param changes NvimDiff.Git.FileChange[]
---@param stamp? fun(change: NvimDiff.Git.FileChange): string Defaults to `M.stamp`.
---@return NvimDiff.FileList
function M.list(changes, stamp)
  local self = setmetatable({ entries = {}, by_key = {}, stamp = stamp or M.stamp }, List)
  self:morph(changes)
  return self
end

--- Replace the list's contents with `changes`, reusing the entry for every key that is
--- still there. Returns the edit script: every `delete` first, then one op per new entry
--- in the new order. An `update` entry keeps its identity and its `forced`/`viewed` state;
--- its `change`, `stamp` and measurements are replaced (measurements are cleared — measure
--- the `insert` and `update` entries again).
---@param changes NvimDiff.Git.FileChange[]
---@return NvimDiff.EditOp[]
function List:morph(changes)
  local ops = {}
  local next_by_key = {}
  for _, change in ipairs(changes) do
    next_by_key[M.key(change)] = change
  end
  for _, entry in ipairs(self.entries) do
    if not next_by_key[entry.key] then
      ops[#ops + 1] = { op = "delete", entry = entry }
    end
  end

  local entries, by_key = {}, {}
  for _, change in ipairs(changes) do
    local key = M.key(change)
    if not by_key[key] then
      local stamp = self.stamp(change)
      local entry = self.by_key[key]
      if not entry then
        entry = new_entry(change, stamp)
        ops[#ops + 1] = { op = "insert", entry = entry }
      elseif entry.stamp ~= stamp then
        local previous = entry.change
        entry.change, entry.stamp = change, stamp
        entry.lines, entry.deferred = nil, false
        ops[#ops + 1] = { op = "update", entry = entry, previous = previous }
      else
        entry.change = change
        ops[#ops + 1] = { op = "keep", entry = entry }
      end
      entries[#entries + 1] = entry
      by_key[key] = entry
    end
  end
  self.entries, self.by_key = entries, by_key
  return ops
end

--- Index of `entry` in the list, or nil.
---@param entry NvimDiff.FileEntry
---@return integer?
function List:index_of(entry)
  for i, e in ipairs(self.entries) do
    if e == entry then
      return i
    end
  end
  return nil
end

---@class NvimDiff.MeasureSides
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev

--- Decide which entries are over the line threshold.
---
--- Cheap by construction: an added file's line count is its numstat additions and a
--- deleted file's is its deletions; every other side is sized in bytes — one
--- `cat-file --batch-check` for all committed and staged objects, `stat` for worktree
--- files — and only a side with more bytes than `limit` can have more than `limit` lines,
--- so only those are read and counted. A file that cannot be measured is not deferred.
---@param repo NvimDiff.Git.Repo
---@param sides NvimDiff.MeasureSides
---@param entries NvimDiff.FileEntry[]
---@param limit integer `thresholds.defer_lines`.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.measure(repo, sides, entries, limit)
  local oids = {}
  for _, entry in ipairs(entries) do
    oids[#oids + 1] = entry.change.old_oid
    oids[#oids + 1] = entry.change.new_oid
  end
  local sizes, err = blob.sizes(repo, oids)
  if not sizes then
    log.debug("measuring files failed: %s", err and err.message or "?")
    sizes = {}
  end

  ---@param entry NvimDiff.FileEntry
  ---@param side "old"|"new"
  ---@return integer
  local function side_lines(entry, side)
    local c = entry.change
    local oid = side == "old" and c.old_oid or c.new_oid
    local git_path = side == "old" and (c.oldpath or c.path) or c.path
    local at = side == "old" and sides.left or sides.right
    local bytes = sizes[oid]
    if not bytes and at.type == "worktree" then
      local stat = vim.uv.fs_stat(path.from_git(repo.toplevel, git_path))
      bytes = stat and stat.size
    end
    if not bytes or bytes <= limit then
      -- A file has at most as many lines as bytes.
      return 0
    end
    local b, read_err = blob.read(repo, at, git_path)
    if not b then
      log.debug("measuring %s failed: %s", git_path, read_err and read_err.message or "?")
      return 0
    end
    return blob.line_count(b.bytes)
  end

  for _, entry in ipairs(entries) do
    local c = entry.change
    local lines
    if c.binary then
      lines = nil
    elseif c.status == "A" and c.additions then
      lines = c.additions
    elseif c.status == "D" and c.deletions then
      lines = c.deletions
    else
      local old = (c.status == "A" or c.status == "?") and 0 or side_lines(entry, "old")
      local new = c.status == "D" and 0 or side_lines(entry, "new")
      lines = math.max(old, new)
    end
    entry.lines = lines and lines > limit and lines or nil
    entry.deferred = entry.lines ~= nil
  end
end

return M
