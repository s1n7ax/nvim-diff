--- A PR review keeping in step with GitHub: every `github.sync_interval_ms`, and at once on
--- `keymaps.review.sync`, one GraphQL query (`github/threads.lua` `snapshot`) reads the PR's
--- state, head commit, base branch and threads.
---
--- Detection and signalling only. What GitHub has now is kept on the review as
--- `review.latest`; what the review shows (`review.pr`, the diff, the threads drawn) never
--- changes here.
---
--- * New code — a new head commit, or the PR retargeted to another base branch — is
---   announced once per change and marked in the panel until the review shows it. A push to
---   the base branch alone is not new code: GitHub's `baseRefOid` is the merge-base, which
---   it does not move.
--- * Merged or closed: announced, marked in the panel, and syncing stops. The review stays
---   usable; the key still checks, and a PR found open again syncs again.
---
--- Failures: a network error, a timeout or an unexpected GitHub error is retried quietly at
--- the next tick and reported once after `WARN_AFTER` in a row (at once for the key); a
--- rate limit pauses syncing until GitHub says it lifts; lost credentials, a PR no longer
--- visible or a refusal stop syncing, with a warning.
---
--- Every check runs as a `job.task`, so `gh` never blocks the editor. The timer is one-shot
--- and re-armed when a check ends, so checks never overlap and a slow one pushes the next
--- back. It keeps running while Neovim is unfocused or the review's tab is in the background.

local config = require("nvim-diff.config")
local job = require("nvim-diff.core.job")
local log = require("nvim-diff.core.log")
local threads_mod = require("nvim-diff.github.threads")

local api = vim.api

local M = {}

--- Failed checks in a row before the user hears of them.
M.WARN_AFTER = 3

--- Seconds a rate limit pauses syncing when GitHub does not say how long: its own advice.
M.RATE_LIMIT_WAIT = 60

--- What the panel says for an error that stops syncing.
local STOPPED_BY = {
  not_authenticated = "gh is logged out",
  not_found = "PR not found",
  forbidden = "access refused",
}

---@class NvimDiff.ReviewSync
---@field review NvimDiff.Review
---@field interval? integer Milliseconds between checks; nil when only the key checks.
---@field timer? uv.uv_timer_t
---@field task? NvimDiff.Job.Task The check running now, or the last one.
---@field manual? boolean The key was pressed while a check ran: report its answer.
---@field generation integer Bumped by `cancel`; a check started before is dropped.
---@field failures integer Failed checks in a row.
---@field problem? string Why checks fail, once the user has been told.
---@field paused_until? integer `os.time()` a rate limit lifts.
---@field stopped? string Why syncing stopped: `merged`, `closed`, or a `STOPPED_BY` text.
---@field noticed { head?: string, base?: string, state?: string } What was announced last.
---@field shown? string The panel lines last set, to skip redrawing the same.
---@field closed boolean
local Sync = {}
Sync.__index = Sync

--- The syncing of `review`, not started yet.
---@param review NvimDiff.Review
---@return NvimDiff.ReviewSync
function M.new(review)
  local interval = config.get().github.sync_interval_ms
  return setmetatable({
    review = review,
    interval = interval or nil,
    generation = 0,
    failures = 0,
    -- A PR already merged when the review opened is shown as such, not announced.
    noticed = { state = review.pr.state },
    closed = false,
  }, Sync)
end

---@param text string
local function echo(text)
  api.nvim_echo({ { "nvim-diff: " .. text } }, false, {})
end

--- The notice for new code on GitHub.
---@param review NvimDiff.Review
---@param stale { head?: string, base?: string }
---@return string
local function stale_notice(review, stale)
  local what = {}
  if stale.head then
    what[#what + 1] = ("has new commits (head %s)"):format(stale.head:sub(1, 7))
  end
  if stale.base then
    what[#what + 1] = ("now targets %s (was %s)"):format(stale.base, review.pr.base.ref or "?")
  end
  return ("PR #%d %s on GitHub; the review shows the old diff until reopened"):format(
    review.number,
    table.concat(what, " and ")
  )
end

--- Start syncing: take what the review opened on (a PR already merged, or a head that moved
--- while it opened), then arm the timer.
function Sync:start()
  if self.review.latest then
    self:take(self.review.latest, false)
  else
    self:schedule()
  end
end

--- Arm the timer for the next check, unless syncing is off, stopped or over.
---@param ms? integer Defaults to the interval; never sooner than it.
function Sync:schedule(ms)
  if self.closed or self.stopped or not self.interval then
    return
  end
  self.timer = self.timer or assert(vim.uv.new_timer())
  self.timer:stop()
  self.timer:start(
    math.max(ms or 0, self.interval),
    0,
    vim.schedule_wrap(function()
      self:check(false)
    end)
  )
end

--- Check GitHub now. A check already running is left to finish.
---@param manual boolean From the key: the answer is reported even when nothing changed.
function Sync:check(manual)
  if self.closed then
    return
  end
  if self.task and not self.task.done then
    self.manual = self.manual or manual
    return
  end
  if self.timer then
    self.timer:stop()
  end
  self.manual = manual
  local review, generation = self.review, self.generation
  self.task = job.task(function()
    return threads_mod.snapshot(review.pr.target, review.number)
  end, function(err, snap, gh_err)
    if self.closed or generation ~= self.generation or job.is_cancelled(err) then
      return
    end
    local reported = self.manual
    self.manual = nil
    if err then
      -- A bug, not an answer from GitHub: reported like a failed check, and retried.
      gh_err = { kind = "api_error", message = tostring(err) }
    end
    if snap then
      self:take(snap, reported)
    else
      self:fail(gh_err, reported)
    end
  end)
end

--- The key: check at once, unless a rate limit says to wait.
function Sync:now()
  if self.closed then
    return
  end
  local number = self.review.number
  if self.paused_until and os.time() < self.paused_until then
    log.warn(
      "GitHub rate limit reached; PR #%d can be checked again at %s",
      number,
      os.date("%H:%M:%S", self.paused_until)
    )
    return
  end
  echo(("checking PR #%d on GitHub…"):format(number))
  self:check(true)
end

--- Take a snapshot GitHub answered with: keep it on the review, announce what is new, stop
--- on a merged or closed PR, arm the next check.
---@param snap NvimDiff.GitHub.Snapshot
---@param manual boolean
function Sync:take(snap, manual)
  local review = self.review
  review.latest = snap
  self.failures, self.problem, self.paused_until = 0, nil, nil

  local said = false
  local stale = review:stale()
  local head, base = stale and stale.head, stale and stale.base
  if stale and (head ~= self.noticed.head or base ~= self.noticed.base) then
    log.warn("%s", stale_notice(review, stale))
    said = true
  end
  self.noticed.head, self.noticed.base = head, base

  if snap.state == "MERGED" or snap.state == "CLOSED" then
    local how = snap.state == "MERGED" and "merged" or "closed"
    if self.noticed.state ~= snap.state then
      log.warn("PR #%d was %s on GitHub; syncing stopped", review.number, how)
      said = true
    end
    self.noticed.state = snap.state
    self:stop(how)
  else
    self.noticed.state = snap.state
    self.stopped = nil
    local rate = snap.rate
    local wait = rate and rate.remaining == 0 and rate.reset and rate.reset - os.time()
    if wait and wait > 0 then
      -- That was the last point of the window: wait for the next one rather than be refused.
      self.paused_until = rate.reset
      self:schedule(wait * 1000)
    else
      self:schedule()
    end
  end

  if manual and not said then
    if stale then
      echo(("PR #%d has new code on GitHub that this review does not show"):format(review.number))
    elseif self.stopped then
      echo(("PR #%d is %s; not syncing"):format(review.number, self.stopped))
    else
      echo(("PR #%d is up to date with GitHub"):format(review.number))
    end
  end
  self:show()
end

--- A check failed: pause, stop or retry by what went wrong.
---@param err NvimDiff.GitHub.Error|{ kind: string, message: string }
---@param manual boolean
function Sync:fail(err, manual)
  local number = self.review.number
  local why = err and err.message or "unknown error"
  local kind = err and err.kind
  if kind == "rate_limited" then
    local wait = err.retry_after or M.RATE_LIMIT_WAIT
    self.paused_until = os.time() + wait
    log.warn("GitHub rate limit reached; PR #%d syncs again at %s", number, os.date("%H:%M:%S", self.paused_until))
    self:schedule(wait * 1000)
  elseif STOPPED_BY[kind] then
    log.warn("PR #%d stopped syncing: %s", number, why)
    self.problem = why
    self:stop(STOPPED_BY[kind])
  else
    self.failures = self.failures + 1
    if manual or self.failures == M.WARN_AFTER then
      self.problem = why
      local tries = self.failures == 1 and "" or (" (%d tries in a row)"):format(self.failures)
      log.warn("PR #%d cannot sync with GitHub%s: %s; still trying", number, tries, why)
    end
    self:schedule()
  end
  self:show()
end

--- Stop syncing: no more checks by themselves. The key still checks.
---@param why string
function Sync:stop(why)
  self.stopped = why
  if self.timer then
    self.timer:stop()
  end
end

--- Drop the check running now, if any: its answer is never used. For a caller about to
--- change what the review shows; the next check is at the next tick, or on the key.
function Sync:cancel()
  self.generation = self.generation + 1
  if self.task and not self.task.done then
    self.task:cancel()
  end
  self.task, self.manual = nil, nil
end

--- The panel's sync lines: what is new on GitHub, then why syncing is stopped, paused or
--- failing.
---@return NvimDiff.PanelStatus[]
function Sync:status()
  local out = {}
  local stale = self.review:stale()
  if stale then
    local what = {}
    if stale.head then
      what[#what + 1] = "new commits"
    end
    if stale.base then
      what[#what + 1] = "base → " .. stale.base
    end
    out[#out + 1] = { text = "● " .. table.concat(what, ", ") .. " on GitHub", hl = "NvimDiffPanelStale" }
  end
  local text
  if self.stopped == "merged" or self.stopped == "closed" then
    text = self.stopped .. " on GitHub; not syncing"
  elseif self.stopped then
    text = "not syncing: " .. self.stopped
  elseif self.paused_until and os.time() < self.paused_until then
    text = "rate limited; next sync " .. os.date("%H:%M", self.paused_until)
  elseif self.problem then
    text = "cannot reach GitHub; retrying"
  end
  if text then
    out[#out + 1] = { text = text, hl = "NvimDiffPanelSync" }
  end
  return out
end

--- Put the sync lines in the panel, when they changed.
function Sync:show()
  local lines = self:status()
  local key = table.concat(
    vim.tbl_map(function(l)
      return l.hl .. "\0" .. l.text
    end, lines),
    "\n"
  )
  if key == self.shown or not self.review.view:is_valid() then
    return
  end
  self.shown = key
  self.review.view:set_status(lines)
end

--- Stop for good: the timer is freed and a running check dropped. Idempotent.
function Sync:close()
  if self.closed then
    return
  end
  self:cancel()
  self.closed = true
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
end

return M
