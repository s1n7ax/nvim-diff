--- Child processes, and the coroutines that wait on them.
---
--- A thin wrapper over `vim.system` with three opinions:
---
--- 1. **A run always produces a result.** `vim.system` raises when the binary or the
---    working directory is missing, and a timeout looks like any other non-zero exit.
---    Both come back as a `Result` with `spawned = false` or `timed_out = true`, so
---    callers classify failures in one place.
--- 2. **Output is bytes.** `text = true` rewrites `\r\n` to `\n`, which silently corrupts
---    a blob from a repository that stores CRLF. Callers split lines themselves.
--- 3. **`await` is the one way to wait.** Code that runs git is written straight-line
---    with `M.await`. Inside a task started by `M.task` it yields to the event loop;
---    called from the main thread it blocks. The same git function therefore serves an
---    async view and a synchronous test.
---
--- Cancellation: `task:cancel()` kills the process the task is waiting on, and that
--- `await` (or the next one) raises a `job.Cancelled` error that unwinds the task. This is
--- a hand-rolled shim rather than `vim.async`, which is not in the declared 0.12 floor.

local M = {}

M.DEFAULT_TIMEOUT_MS = 15000

--- Exit code for a process that never started.
M.SPAWN_FAILED_CODE = -1

---@class NvimDiff.Job.Result
---@field cmd string[]
---@field code integer Exit status; `M.SPAWN_FAILED_CODE` when it never ran.
---@field signal integer
---@field stdout string Raw bytes.
---@field stderr string For a failed spawn, the reason.
---@field spawned boolean
---@field timed_out boolean
---@field duration_ms number

---@class NvimDiff.Job.Opts
---@field cwd? string
---@field env? table<string, string|false> Merged over the inherited environment; `false` removes a name.
---@field stdin? string
---@field timeout_ms? integer

--- The error a cancelled task unwinds with. Compare with `M.is_cancelled`.
---@class NvimDiff.Job.Cancelled
---@field kind "cancelled"
---@field message string
local Cancelled = {}
Cancelled.__index = Cancelled
Cancelled.__tostring = function(self)
  return self.message
end
M.Cancelled = Cancelled

---@param err any
---@return boolean
function M.is_cancelled(err)
  return getmetatable(err) == Cancelled
end

--- A command rendered for a human, for log lines and error messages.
---@param cmd string[]
---@return string
function M.describe(cmd)
  local parts = {}
  for _, arg in ipairs(cmd) do
    parts[#parts + 1] = arg:find("[%s'\"]") and ("%q"):format(arg) or arg
  end
  return table.concat(parts, " ")
end

---@param env table<string, string|false>?
---@return table<string, string>?
local function build_env(env)
  if not env then
    return nil
  end
  local out = vim.uv.os_environ()
  for name, value in pairs(env) do
    out[name] = value or nil
  end
  return out
end

---@param opts NvimDiff.Job.Opts?
---@return vim.SystemOpts
local function system_opts(opts)
  opts = opts or {}
  return {
    cwd = opts.cwd,
    env = build_env(opts.env),
    clear_env = opts.env ~= nil,
    stdin = opts.stdin,
    timeout = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS,
  }
end

---@param cmd string[]
---@param started integer
---@param completed vim.SystemCompleted?
---@param spawn_err string?
---@return NvimDiff.Job.Result
local function result(cmd, started, completed, spawn_err)
  local duration = (vim.uv.hrtime() - started) / 1e6
  if not completed then
    return {
      cmd = cmd,
      code = M.SPAWN_FAILED_CODE,
      signal = 0,
      stdout = "",
      stderr = spawn_err or "failed to start",
      spawned = false,
      timed_out = false,
      duration_ms = duration,
    }
  end
  return {
    cmd = cmd,
    code = completed.code,
    signal = completed.signal or 0,
    stdout = completed.stdout or "",
    stderr = completed.stderr or "",
    spawned = true,
    -- `vim.system` reports a timeout as exit 124 after killing the child with a signal.
    -- A process that exits 124 by itself has no signal. (Elapsed time is no test: libuv
    -- timers run on cached loop time and can fire a few ms early by the wall clock.)
    timed_out = completed.code == 124 and (completed.signal or 0) ~= 0,
    duration_ms = duration,
  }
end

---@class NvimDiff.Job.Handle
---@field kill fun()
---@field is_active fun(): boolean

--- Start a command. `on_exit` runs on the main loop exactly once, even when the process
--- never started.
---@param cmd string[]
---@param opts NvimDiff.Job.Opts?
---@param on_exit fun(result: NvimDiff.Job.Result)
---@return NvimDiff.Job.Handle
function M.spawn(cmd, opts, on_exit)
  local started = vim.uv.hrtime()
  local done = false
  local ok, obj = pcall(vim.system, cmd, system_opts(opts), function(completed)
    done = true
    local res = result(cmd, started, completed)
    vim.schedule(function()
      on_exit(res)
    end)
  end)

  if not ok then
    done = true
    local res = result(cmd, started, nil, tostring(obj))
    vim.schedule(function()
      on_exit(res)
    end)
  end

  return {
    kill = function()
      if not done and ok then
        pcall(obj.kill, obj, "sigterm")
      end
    end,
    is_active = function()
      return not done
    end,
  }
end

--- Run a command to completion, blocking. Prefer `await`, which blocks only when it has to.
---@param cmd string[]
---@param opts NvimDiff.Job.Opts?
---@return NvimDiff.Job.Result
function M.run(cmd, opts)
  local started = vim.uv.hrtime()
  local ok, obj = pcall(vim.system, cmd, system_opts(opts))
  if not ok then
    return result(cmd, started, nil, tostring(obj))
  end
  return result(cmd, started, obj:wait())
end

---@class NvimDiff.Job.Task
---@field private co thread
---@field private handle NvimDiff.Job.Handle?
---@field private cancelled boolean
---@field done boolean
---@field err any The error the task ended with; a `Cancelled` when it was cancelled.
---@field values any[]? What the task function returned, when it succeeded.
local Task = {}
Task.__index = Task

---@type table<thread, NvimDiff.Job.Task>
local tasks = setmetatable({}, { __mode = "k" })

--- Stop the task. The process it is waiting on is killed and the task unwinds with a
--- `Cancelled` error; its `on_done` still runs. A finished task ignores this.
function Task:cancel()
  if self.done or self.cancelled then
    return
  end
  self.cancelled = true
  if self.handle then
    self.handle.kill()
  end
end

---@return boolean
function Task:is_cancelled()
  return self.cancelled
end

--- Block until the task finishes. For tests and for the rare caller that truly must.
---@param timeout_ms? integer
---@return boolean finished False when the wait timed out.
function Task:wait(timeout_ms)
  return vim.wait(timeout_ms or M.DEFAULT_TIMEOUT_MS, function()
    return self.done
  end, 5)
end

---@param task NvimDiff.Job.Task
---@param ... any Values from `coroutine.resume`.
local function step(task, ...)
  -- The task body is wrapped in `xpcall`, so a failed resume means `on_done` itself threw.
  local ok, err = coroutine.resume(task.co, ...)
  if not ok then
    task.done = true
    require("nvim-diff.core.log").error("nvim-diff: task callback failed: %s", tostring(err))
  end
end

--- Run `fn` as a task. `on_done(err, ...)` is called on the main loop with the error the
--- task raised (a `Cancelled` when it was cancelled) or nil and the function's returns.
---@param fn fun(): ...
---@param on_done? fun(err: any, ...: any)
---@return NvimDiff.Job.Task
function M.task(fn, on_done)
  local task = setmetatable({ done = false, cancelled = false }, Task)
  task.co = coroutine.create(function()
    local packed = vim.F.pack_len(xpcall(fn, function(err)
      if M.is_cancelled(err) or type(err) == "table" then
        return err
      end
      return debug.traceback(tostring(err), 2)
    end))
    task.done = true
    if packed[1] then
      task.values = { unpack(packed, 2, packed.n) }
    else
      task.err = packed[2]
      if not M.is_cancelled(task.err) and not on_done then
        require("nvim-diff.core.log").error("nvim-diff: %s", tostring(task.err))
      end
    end
    if on_done then
      if packed[1] then
        on_done(nil, unpack(packed, 2, packed.n))
      else
        on_done(task.err)
      end
    end
  end)
  tasks[task.co] = task
  step(task)
  return task
end

--- The task the calling code runs in, or nil on the main thread.
---@return NvimDiff.Job.Task?
function M.current()
  local co = coroutine.running()
  return co and tasks[co] or nil
end

---@param task NvimDiff.Job.Task
local function check_cancelled(task)
  if task.cancelled then
    error(setmetatable({ kind = "cancelled", message = "nvim-diff: task cancelled" }, Cancelled), 0)
  end
end

--- Run a command and wait for it. Inside a task this yields; on the main thread it blocks.
---@param cmd string[]
---@param opts NvimDiff.Job.Opts?
---@return NvimDiff.Job.Result
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.await(cmd, opts)
  local task = M.current()
  if not task then
    return M.run(cmd, opts)
  end
  check_cancelled(task)
  local co = task.co
  local finished, res = false, nil
  task.handle = M.spawn(cmd, opts, function(r)
    finished, res = true, r
    if coroutine.status(co) == "suspended" then
      step(task, r)
    end
  end)
  if not finished then
    res = coroutine.yield()
  end
  task.handle = nil
  check_cancelled(task)
  return res
end

---@param res NvimDiff.Job.Result
---@return boolean
function M.ok(res)
  return res.spawned and res.code == 0
end

--- Why a result is not a success, in one line. Empty for a success.
---@param res NvimDiff.Job.Result
---@return string
function M.reason(res)
  if M.ok(res) then
    return ""
  end
  if not res.spawned then
    return res.stderr
  end
  if res.timed_out then
    return ("timed out after %.0f ms"):format(res.duration_ms)
  end
  local first = vim.trim(res.stderr):match("^[^\n]*")
  if first and first ~= "" then
    return first
  end
  return ("exited with status %d"):format(res.code)
end

return M
