--- Live threads: GitHub's comment threads, read again while a review is open, fitted to the
--- head the review shows. Pure: no windows, no buffers, no GitHub.
---
--- A thread's `line` counts in GitHub's head as it was when the threads were read. While
--- that is the head the review shows (and the base branch is the same), the threads are
--- drawn as read, and where each one hangs is recorded (`anchors`). Once GitHub has code the
--- review does not show yet, each thread is fitted instead:
---
--- 1. A thread recorded before keeps its recorded place; only its comments, resolved state
---    and permissions are taken from what was read, so new replies, edits and resolves on
---    the code shown still show at once.
--- 2. A thread whose line still counts in the shown head (GitHub has not moved it yet) is
---    drawn as read.
--- 3. A thread written on the shown head is drawn where it was written (`original_line`) —
---    a comment posted from this review while it is behind, for one.
--- 4. An outdated thread goes to the side list as outdated, as it would on the new code.
--- 5. Any other thread is on code newer than the review shows. It is held back, and counted
---    as waiting, until that code is applied (the review then shows GitHub's head, and every
---    thread is drawn as read).
---
--- Fitting records the place of every thread it draws, so a thread keeps its place however
--- GitHub moves it later. The record is for one shown head: a new head starts a new one.
---
---     local anchors = live.anchors(review.pr.head.oid)
---     local shown, held = live.fit(snap.threads, anchors, snap.head.oid == anchors.head)

local M = {}

--- Where a thread hangs, as `NvimDiff.GitHub.Thread` has it: the fields fitting keeps.
local PLACE = { "path", "side", "start_side", "line", "start_line", "original_line", "original_start_line", "outdated" }

---@class NvimDiff.ThreadAnchors
---@field head string The shown head the places count in.
---@field by_id table<string, table> Thread id to its `PLACE` fields.

--- A fresh record of thread places, for a review showing `head`.
---@param head string
---@return NvimDiff.ThreadAnchors
function M.anchors(head)
  return { head = head, by_id = {} }
end

---@param t NvimDiff.GitHub.Thread
---@return table
local function place_of(t)
  local p = {}
  for _, k in ipairs(PLACE) do
    p[k] = t[k]
  end
  return p
end

--- `t` with its place replaced by `place`: a copy, with its own comment list.
---@param t NvimDiff.GitHub.Thread
---@param place table
---@return NvimDiff.GitHub.Thread
local function placed(t, place)
  local c = {}
  for k, v in pairs(t) do
    c[k] = v
  end
  for _, k in ipairs(PLACE) do
    c[k] = place[k]
  end
  c.comments = { unpack(t.comments) }
  return c
end

--- Fit threads read from GitHub to the head `anchors` is for.
---@param threads NvimDiff.GitHub.Thread[] As read, in GitHub's order.
---@param anchors NvimDiff.ThreadAnchors Updated with the place of every thread drawn.
---@param current boolean They were read while GitHub's head and base branch were the ones shown.
---@return NvimDiff.GitHub.Thread[] shown To draw, in GitHub's order.
---@return NvimDiff.GitHub.Thread[] held On code newer than the head shown.
function M.fit(threads, anchors, current)
  local shown, held = {}, {}
  for _, t in ipairs(threads) do
    local known = anchors.by_id[t.id]
    local first = t.comments[1]
    local out
    if current then
      out = t
    elseif known then
      out = placed(t, known)
    elseif t.line and first and first.commit_oid == anchors.head then
      out = t
    elseif first and first.original_commit_oid == anchors.head then
      local p = place_of(t)
      p.line, p.start_line, p.outdated = t.original_line, t.original_start_line, false
      out = placed(t, p)
    elseif t.outdated then
      out = t
    end
    if out then
      anchors.by_id[t.id] = place_of(out)
      shown[#shown + 1] = out
    else
      held[#held + 1] = t
    end
  end
  return shown, held
end

--- Thread fields a drawing shows, or a key acts on.
local THREAD_KEYS = {
  "id",
  "path",
  "side",
  "start_side",
  "line",
  "start_line",
  "original_line",
  "original_start_line",
  "resolved",
  "resolved_by",
  "outdated",
  "subject",
  "can_reply",
  "can_resolve",
  "can_unresolve",
  "local_only",
}

--- Comment fields a drawing shows, or a key acts on.
local COMMENT_KEYS = { "id", "database_id", "author", "body", "created_at", "last_edited_at", "viewer_did_author" }

---@param t table
---@param keys string[]
---@return any[]
local function project(t, keys)
  local out = {}
  for i, k in ipairs(keys) do
    local v = t[k]
    if v == nil then
      v = vim.NIL
    end
    out[i] = v
  end
  return out
end

--- A key that changes when anything drawn about `threads` does, and only then: a sync that
--- reads the same threads again skips redrawing. A comment's commit is not in it, as every
--- push moves it.
---@param threads NvimDiff.GitHub.Thread[]
---@return string
function M.fingerprint(threads)
  local all = {}
  for i, t in ipairs(threads) do
    local comments = {}
    for j, c in ipairs(t.comments) do
      comments[j] = project(c, COMMENT_KEYS)
    end
    local row = project(t, THREAD_KEYS)
    row[#row + 1] = comments
    all[i] = row
  end
  return vim.json.encode(all)
end

return M
