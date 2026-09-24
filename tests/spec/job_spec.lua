local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local job = require("nvim-diff.core.job")

describe("job", function()
  describe("run", function()
    it("returns raw bytes, CRLF and NUL intact", function()
      local res = job.run({ "printf", "a\\r\\nb\\000c" })
      expect.truthy(job.ok(res))
      expect.eq("a\r\nb\0c", res.stdout)
    end)

    it("passes stdin through", function()
      local res = job.run({ "cat" }, { stdin = "hello" })
      expect.eq("hello", res.stdout)
    end)

    it("reports a missing binary as a result, not an error", function()
      local res = job.run({ "nvim-diff-no-such-binary" })
      expect.falsy(res.spawned)
      expect.eq(job.SPAWN_FAILED_CODE, res.code)
      expect.ne("", job.reason(res))
    end)

    it("marks a killed-on-timeout process as timed out", function()
      local res = job.run({ "sleep", "5" }, { timeout_ms = 50 })
      expect.truthy(res.timed_out)
      expect.matches("timed out", job.reason(res))
    end)

    it("does not mistake a genuine exit 124 for a timeout", function()
      local res = job.run({ "sh", "-c", "exit 124" })
      expect.eq(124, res.code)
      expect.falsy(res.timed_out)
    end)

    it("uses the first stderr line as the reason", function()
      local res = job.run({ "sh", "-c", "echo 'first\nsecond' >&2; exit 3" })
      expect.eq("first", job.reason(res))
    end)

    it("merges env over the inherited environment and can remove names", function()
      vim.env.NVIM_DIFF_JOB_SPEC = "inherited"
      local res = job.run({ "sh", "-c", 'printf "%s|%s|%s" "$NVIM_DIFF_JOB_SPEC" "$ADDED" "${HOME:+home}"' }, {
        env = { ADDED = "yes", NVIM_DIFF_JOB_SPEC = false },
      })
      vim.env.NVIM_DIFF_JOB_SPEC = nil
      expect.eq("|yes|home", res.stdout)
    end)
  end)

  describe("await", function()
    it("blocks on the main thread", function()
      expect.eq(nil, job.current())
      local res = job.await({ "echo", "sync" })
      expect.eq("sync\n", res.stdout)
    end)

    it("yields inside a task, letting the event loop run", function()
      local ticks = 0
      local timer = vim.uv.new_timer()
      timer:start(0, 5, function()
        ticks = ticks + 1
      end)
      local seen
      local task = job.task(function()
        local res = job.await({ "sh", "-c", "sleep 0.1; echo async" })
        return res.stdout
      end, function(err, out)
        seen = { err = err, out = out }
      end)
      expect.falsy(task.done, "the task is suspended on the process")
      expect.truthy(task:wait(2000))
      timer:stop()
      timer:close()
      expect.eq({ out = "async\n" }, seen)
      expect.truthy(ticks > 2, "timers fired while the task waited: " .. ticks)
    end)

    it("runs several awaits in sequence", function()
      local task = job.task(function()
        local a = job.await({ "echo", "a" }).stdout
        local b = job.await({ "echo", "b" }).stdout
        return a .. b
      end)
      task:wait(2000)
      expect.eq({ "a\nb\n" }, task.values)
    end)

    it("hands a task's error to on_done", function()
      local got
      local task = job.task(function()
        job.await({ "true" })
        error("boom")
      end, function(err)
        got = err
      end)
      task:wait(2000)
      expect.matches("boom", tostring(got))
      expect.matches("boom", tostring(task.err))
    end)
  end)

  describe("cancel", function()
    it("kills the running process and unwinds with Cancelled", function()
      local got, after = nil, false
      local started = vim.uv.hrtime()
      local task = job.task(function()
        job.await({ "sleep", "5" })
        after = true
      end, function(err)
        got = err
      end)
      task:cancel()
      expect.truthy(task:wait(2000))
      expect.truthy((vim.uv.hrtime() - started) / 1e6 < 2000, "the sleep was killed")
      expect.falsy(after, "code after the cancelled await never ran")
      expect.truthy(job.is_cancelled(got))
      expect.truthy(task:is_cancelled())
    end)

    it("stops a task before its next await", function()
      local second = false
      local task
      task = job.task(function()
        job.await({ "true" })
        task:cancel()
        job.await({ "true" })
        second = true
      end)
      task:wait(2000)
      expect.falsy(second)
      expect.truthy(job.is_cancelled(task.err))
    end)

    it("is a no-op on a finished task", function()
      local task = job.task(function()
        return 1
      end)
      task:wait(1000)
      task:cancel()
      expect.eq({ 1 }, task.values)
      expect.falsy(task:is_cancelled())
    end)
  end)

  describe("stream", function()
    ---@param s NvimDiff.Job.Stream
    ---@return string
    local function drain(s)
      local out = {}
      for chunk in
        function()
          return s:read()
        end
      do
        out[#out + 1] = chunk
      end
      return table.concat(out)
    end

    it("reads output as it arrives, blocking on the main thread", function()
      local s = job.stream({ "sh", "-c", "printf 'a\\0b'; sleep 0.05; printf 'c'; echo err >&2; exit 3" })
      expect.eq("a\0bc", drain(s))
      local res = s:result()
      expect.eq(3, res.code)
      expect.eq("err\n", res.stderr)
      expect.eq(nil, s:read())
    end)

    it("yields inside a task, chunk by chunk", function()
      local chunks, ticked = {}, false
      local task = job.task(function()
        local s = job.stream({ "sh", "-c", "echo one; sleep 0.1; echo two" })
        for chunk in
          function()
            return s:read()
          end
        do
          chunks[#chunks + 1] = chunk
        end
        return s:result().code
      end)
      vim.schedule(function()
        ticked = true
      end)
      expect.truthy(task:wait(2000))
      expect.truthy(ticked)
      expect.eq({ 0 }, task.values)
      expect.eq({ "one\n", "two\n" }, chunks)
    end)

    it("reports a missing binary as an unspawned result", function()
      local s = job.stream({ "nvim-diff-no-such-binary" })
      expect.eq(nil, s:read())
      expect.falsy(s:result().spawned)
    end)

    it("is killed when its task is cancelled", function()
      local task = job.task(function()
        local s = job.stream({ "sleep", "5" })
        s:read()
      end)
      local started = vim.uv.hrtime()
      task:cancel()
      expect.truthy(task:wait(2000))
      expect.truthy(job.is_cancelled(task.err))
      expect.truthy((vim.uv.hrtime() - started) / 1e6 < 2000)
    end)
  end)
end)
