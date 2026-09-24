--- File contents at a revision.
---
--- Committed and staged content comes from `git cat-file --batch`, which answers
--- "missing" and "this is a tree" in its header line instead of on stderr, and returns
--- the exact bytes — no textconv, no CRLF rewriting. Worktree content is read from disk;
--- a symlink yields its target, as git stores it.
---
--- Binary is decided the way git decides it: a NUL byte in the first 8000 bytes.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local path = require("nvim-diff.core.path")
local rev = require("nvim-diff.git.rev")

local M = {}

--- How far git looks for a NUL byte before calling a file text.
local BINARY_PROBE_BYTES = 8000

---@class NvimDiff.Git.Blob
---@field bytes string
---@field binary boolean

---@param bytes string
---@return NvimDiff.Git.Blob
local function blob(bytes)
  return { bytes = bytes, binary = bytes:sub(1, BINARY_PROBE_BYTES):find("\0", 1, true) ~= nil }
end

---@param repo NvimDiff.Git.Repo
---@param git_path string
---@return NvimDiff.Git.Blob? blob
---@return NvimDiff.Git.Error? err
local function read_worktree(repo, git_path)
  local file = path.from_git(repo.toplevel, git_path)
  local stat = vim.uv.fs_lstat(file)
  if not stat then
    return nil, errors.new("not_found", git_path .. " does not exist in the worktree")
  end
  if stat.type == "link" then
    local target = vim.uv.fs_readlink(file)
    return blob(target or "")
  end
  if stat.type ~= "file" then
    return nil, errors.new("not_a_blob", git_path .. " is not a file in the worktree")
  end
  local fd, open_err = vim.uv.fs_open(file, "r", 0)
  if not fd then
    return nil, errors.new("failed", ("cannot read %s: %s"):format(file, open_err))
  end
  local bytes = vim.uv.fs_read(fd, stat.size, 0) or ""
  vim.uv.fs_close(fd)
  return blob(bytes)
end

--- The contents of `git_path` at `rev`.
---@param repo NvimDiff.Git.Repo
---@param at NvimDiff.Git.Rev
---@param git_path string
---@return NvimDiff.Git.Blob? blob
---@return NvimDiff.Git.Error? err `not_found`, `not_a_blob`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.read(repo, at, git_path)
  git_path = path.to_git(git_path)
  local object = rev.object(at, git_path)
  if not object then
    return read_worktree(repo, git_path)
  end
  if object:find("\n", 1, true) then
    return nil, errors.new("invalid", "a path containing a newline cannot be read through cat-file --batch")
  end

  local out, err = cmd.output(repo.toplevel, { "cat-file", "--batch" }, { stdin = object .. "\n" })
  if not out then
    return nil, err
  end
  local header_end = out:find("\n", 1, true) or (#out + 1)
  local header = out:sub(1, header_end - 1)
  local kind, size = header:match("^%x+ (%a+) (%d+)$")
  if not kind then
    -- `<object> missing` or `<object> ambiguous`.
    return nil, errors.new("not_found", ("%s does not exist at %s"):format(git_path, rev.display(at)))
  end
  if kind ~= "blob" then
    return nil, errors.new("not_a_blob", ("%s is a %s at %s"):format(git_path, kind, rev.display(at)))
  end
  return blob(out:sub(header_end + 1, header_end + tonumber(size)))
end

--- Byte sizes of objects, from one `git cat-file --batch-check`. Headers only: no content
--- is read, so this is cheap enough to run over every file in a list.
---@param repo NvimDiff.Git.Repo
---@param oids string[] Full object ids. All-zero ids are skipped.
---@return table<string, integer>? sizes Oid to size; an oid git does not have is absent.
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.sizes(repo, oids)
  local wanted = {}
  for _, oid in ipairs(oids) do
    if not oid:match("^0+$") then
      wanted[#wanted + 1] = oid
    end
  end
  if #wanted == 0 then
    return {}
  end
  local out, err = cmd.output(
    repo.toplevel,
    { "cat-file", "--batch-check" },
    { stdin = table.concat(wanted, "\n") .. "\n" }
  )
  if not out then
    return nil, err
  end
  local sizes = {}
  for line in out:gmatch("[^\n]+") do
    local oid, size = line:match("^(%x+) %a+ (%d+)$")
    if oid then
      sizes[oid] = tonumber(size)
    end
  end
  return sizes
end

--- How many lines `bytes` holds, counted the way `M.lines` splits them.
---@param bytes string
---@return integer
function M.line_count(bytes)
  if bytes == "" then
    return 0
  end
  local _, newlines = bytes:gsub("\n", "")
  return bytes:sub(-1) == "\n" and newlines or newlines + 1
end

--- Split blob bytes into lines the way a buffer holds them.
---@param bytes string
---@return string[] lines No trailing empty line for a final newline; `{}` for empty content.
---@return boolean eol Whether the content ends with a newline (false for empty content).
function M.lines(bytes)
  if bytes == "" then
    return {}, false
  end
  local lines = vim.split(bytes, "\n", { plain = true })
  local eol = lines[#lines] == ""
  if eol then
    lines[#lines] = nil
  end
  return lines, eol
end

return M
