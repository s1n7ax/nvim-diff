--- The git layer's error values.
---
--- Git functions return `value, err` and never raise for a git-level failure — a bad
--- revision or a missing path is ordinary input, not a bug. The one thing that *is*
--- raised through them is `job.Cancelled`, so a cancelled task unwinds without every
--- caller checking for it.
---
--- `kind` is the named type a caller branches on; `message` is for people.
---
--- | kind               | expected? | meaning                                            |
--- | ------------------ | --------- | -------------------------------------------------- |
--- | `not_a_repository` | yes       | the directory is not inside a work tree            |
--- | `bad_revision`     | yes       | a revision does not resolve to a commit            |
--- | `no_merge_base`    | yes       | the two sides share no history                     |
--- | `not_found`        | yes       | the path does not exist at that revision           |
--- | `not_a_blob`       | yes       | the path names a tree or a submodule               |
--- | `invalid`          | yes       | the caller asked for something git cannot answer   |
--- | `spawn_failed`     | no        | git could not be started                           |
--- | `timeout`          | no        | git was killed after `git.timeout_ms`              |
--- | `failed`           | no        | any other non-zero exit                            |

local M = {}

---@alias NvimDiff.Git.ErrorKind
---| "not_a_repository"
---| "bad_revision"
---| "no_merge_base"
---| "not_found"
---| "not_a_blob"
---| "invalid"
---| "spawn_failed"
---| "timeout"
---| "failed"

---@class NvimDiff.Git.Error
---@field kind NvimDiff.Git.ErrorKind
---@field message string
---@field cmd? string The git command, rendered for a human.
---@field stderr? string
local Error = {}
Error.__index = Error
Error.__tostring = function(self)
  return self.message
end

--- Build an error and log it at debug level: the caller decides whether the user sees it.
---@param kind NvimDiff.Git.ErrorKind
---@param message string
---@param extra? { cmd?: string, stderr?: string }
---@return NvimDiff.Git.Error
function M.new(kind, message, extra)
  local err = setmetatable({ kind = kind, message = message }, Error)
  if extra then
    err.cmd, err.stderr = extra.cmd, extra.stderr
  end
  require("nvim-diff.core.log").debug("git %s: %s%s", kind, message, err.cmd and (" (" .. err.cmd .. ")") or "")
  return err
end

--- Whether `err` is a git error, optionally of one kind.
---@param err any
---@param kind? NvimDiff.Git.ErrorKind
---@return boolean
function M.is(err, kind)
  return getmetatable(err) == Error and (kind == nil or err.kind == kind)
end

return M
