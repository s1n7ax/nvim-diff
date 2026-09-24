--- The one place a git process is built.
---
--- Every invocation carries `--no-optional-locks` (a read must never contend with the
--- user's own `git` for `index.lock`) and `-c core.quotePath=false` (paths come back as
--- raw bytes, never octal-escaped). `log = true` adds `-c gc.auto=0`, so a long history
--- walk never triggers an auto-gc.
---
--- The child inherits Neovim's environment — deliberately, since a dotfiles setup runs
--- Neovim with `GIT_DIR`/`GIT_WORK_TREE` set — plus `GIT_TERMINAL_PROMPT=0` so a fetch
--- that wants credentials fails instead of hanging on a prompt nobody can see.

local errors = require("nvim-diff.git.error")
local job = require("nvim-diff.core.job")

local M = {}

---@class NvimDiff.Git.CmdOpts
---@field stdin? string
---@field log? boolean Add `-c gc.auto=0`.
---@field ok_codes? integer[] Exit statuses that count as success besides 0.

---@param args string[]
---@param opts NvimDiff.Git.CmdOpts
---@return string[]
function M.argv(args, opts)
  local config = require("nvim-diff.config").get()
  local argv = { config.git.bin, "--no-optional-locks", "-c", "core.quotePath=false" }
  if opts.log then
    vim.list_extend(argv, { "-c", "gc.auto=0" })
  end
  return vim.list_extend(argv, args)
end

--- Run git in `cwd` and return the raw result. Only a failure to run at all is an error
--- here; the exit status is the caller's to interpret.
---@param cwd string
---@param args string[]
---@param opts? NvimDiff.Git.CmdOpts
---@return NvimDiff.Job.Result? result
---@return NvimDiff.Git.Error? err `spawn_failed` or `timeout`.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.run(cwd, args, opts)
  opts = opts or {}
  local argv = M.argv(args, opts)
  local res = job.await(argv, {
    cwd = cwd,
    stdin = opts.stdin,
    env = { GIT_TERMINAL_PROMPT = "0" },
    timeout_ms = require("nvim-diff.config").get().git.timeout_ms,
  })
  local extra = { cmd = job.describe(argv), stderr = res.stderr }
  if not res.spawned then
    return nil, errors.new("spawn_failed", "could not run git: " .. res.stderr, extra)
  end
  if res.timed_out then
    return nil, errors.new("timeout", "git " .. job.reason(res), extra)
  end
  return res
end

--- Run git and return its stdout, treating any other exit status as `failed`.
---@param cwd string
---@param args string[]
---@param opts? NvimDiff.Git.CmdOpts
---@return string? stdout Raw bytes.
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.output(cwd, args, opts)
  opts = opts or {}
  local res, err = M.run(cwd, args, opts)
  if not res then
    return nil, err
  end
  if res.code ~= 0 and not vim.tbl_contains(opts.ok_codes or {}, res.code) then
    return nil,
      errors.new("failed", job.reason(res), {
        cmd = job.describe(res.cmd),
        stderr = res.stderr,
      })
  end
  return res.stdout
end

--- Start git in `cwd` and read its stdout as it arrives. No timeout: a history walk over a
--- big repository legitimately runs for longer than `git.timeout_ms`, and is stopped by
--- killing the stream (or cancelling the task reading it) instead.
---@param cwd string
---@param args string[]
---@param opts? NvimDiff.Git.CmdOpts
---@return NvimDiff.Job.Stream
function M.stream(cwd, args, opts)
  return job.stream(M.argv(args, opts or {}), { cwd = cwd, env = { GIT_TERMINAL_PROMPT = "0" } })
end

--- Split NUL-terminated output (`-z`) into fields.
---@param out string
---@return string[]
function M.split_z(out)
  local fields = vim.split(out, "\0", { plain = true })
  if fields[#fields] == "" then
    fields[#fields] = nil
  end
  return fields
end

return M
