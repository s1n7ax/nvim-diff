--- The GitHub layer's error values.
---
--- Mirrors `git/error.lua`: functions return `value, err` and never raise for a GitHub-level
--- failure — a 404, an unauthenticated host or a PR number that does not exist is ordinary
--- input, not a bug. The one thing that *is* raised through them is `job.Cancelled`, so a
--- cancelled task unwinds without every caller checking for it.
---
--- `kind` is the named type a caller branches on; `message` is for people.
---
--- | kind               | expected? | meaning                                                |
--- | ------------------ | --------- | ------------------------------------------------------ |
--- | `not_installed`    | yes       | `gh` is not on PATH                                    |
--- | `not_authenticated`| yes       | `gh` has no working credentials for the host           |
--- | `forbidden`        | yes       | authenticated, but not permitted (403, not a rate limit)|
--- | `rate_limited`     | yes       | a primary or secondary rate limit was hit (403/429, or GraphQL `RATE_LIMITED`) |
--- | `not_found`        | yes       | the repository, PR or resource does not exist or is not visible |
--- | `no_remote`        | yes       | the repository has no remote to resolve a host/owner/repo from |
--- | `bad_remote`       | yes       | the remote URL did not parse into a host and owner/repo |
--- | `api_error`        | yes       | GitHub returned an error with no more specific kind (e.g. GHES schema drift) |
--- | `invalid`          | yes       | the caller asked for something invalid (e.g. a bad PR number) |
--- | `request_failed`   | no        | `gh` ran but could not complete the HTTP request (DNS, TLS, network) |
--- | `spawn_failed`     | no        | `gh` could not be started                              |
--- | `timeout`          | no        | `gh` was killed after `github.timeout_ms`              |

local M = {}

---@alias NvimDiff.GitHub.ErrorKind
---| "not_installed"
---| "not_authenticated"
---| "forbidden"
---| "rate_limited"
---| "not_found"
---| "no_remote"
---| "bad_remote"
---| "api_error"
---| "invalid"
---| "request_failed"
---| "spawn_failed"
---| "timeout"

---@class NvimDiff.GitHub.Error
---@field kind NvimDiff.GitHub.ErrorKind
---@field message string
---@field cmd? string The `gh` command, rendered for a human.
---@field stderr? string
---@field status? integer HTTP status, when the error came from a response.
---@field retry_after? integer Seconds, for `rate_limited`.
local Error = {}
Error.__index = Error
Error.__tostring = function(self)
  return self.message
end

--- Build an error and log it at debug level: the caller decides whether the user sees it.
---@param kind NvimDiff.GitHub.ErrorKind
---@param message string
---@param extra? { cmd?: string, stderr?: string, status?: integer, retry_after?: integer }
---@return NvimDiff.GitHub.Error
function M.new(kind, message, extra)
  local err = setmetatable({ kind = kind, message = message }, Error)
  if extra then
    err.cmd, err.stderr, err.status, err.retry_after = extra.cmd, extra.stderr, extra.status, extra.retry_after
  end
  require("nvim-diff.core.log").debug("github %s: %s%s", kind, message, err.cmd and (" (" .. err.cmd .. ")") or "")
  return err
end

--- Whether `err` is a GitHub error, optionally of one kind.
---@param err any
---@param kind? NvimDiff.GitHub.ErrorKind
---@return boolean
function M.is(err, kind)
  return getmetatable(err) == Error and (kind == nil or err.kind == kind)
end

return M
