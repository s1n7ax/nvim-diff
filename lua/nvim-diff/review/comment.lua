--- What a new comment is on: the lines picked in a diff pane, turned into the file, side and
--- line range GitHub anchors a comment to — or the reason it cannot be anchored there.
---
--- Either pane may take a comment, the old one too (GitHub `LEFT`), so a deleted line can be
--- asked about. A line can take a comment only inside the diff GitHub shows: a hunk plus its
--- three lines of context (`Diff:commentable_ranges`, which matches `git diff -U3`). A range
--- on one side must stay inside one such stretch, since GitHub anchors a multi-line comment
--- to a single hunk. In unified the two ends may fall on different sides — a deleted line
--- down to an added one — which GitHub takes as `start_side` and `side`.
---
--- Also the headers the comment split shows. Pure apart from reading the fileview.

local thread_mod = require("nvim-diff.review.thread")

local M = {}

---@class NvimDiff.CommentTarget
---@field path string
---@field side NvimDiff.Side Side of `line`.
---@field line integer Last line of the range.
---@field start_side? NvimDiff.Side Present for a range.
---@field start_line? integer Present for a range.

---@param diff NvimDiff.Diff
---@param side NvimDiff.Side
---@param lnum integer
---@return [integer, integer]? range The commentable stretch holding the line.
local function stretch(diff, side, lnum)
  for _, r in ipairs(diff:commentable_ranges(side)) do
    if lnum >= r[1] and lnum <= r[2] then
      return r
    end
  end
  return nil
end

--- The comment target for buffer lines `first`..`last` of `win`, a window of `file`.
---@param file NvimDiff.FileView
---@param path string Git path of the file shown.
---@param win integer
---@param first integer Buffer line.
---@param last? integer Buffer line; defaults to `first`. May be above `first`.
---@return NvimDiff.CommentTarget? target
---@return string? reason Why there is none.
function M.target(file, path, win, first, last)
  last = last or first
  if last < first then
    first, last = last, first
  end
  local s1, l1 = file:line_at(win, first)
  local s2, l2 = file:line_at(win, last)
  if not (l1 and l2) then
    return nil, "no file line here to comment on"
  end
  ---@cast s1 NvimDiff.Side
  ---@cast s2 NvimDiff.Side
  -- Anchoring follows the line diff's hunks, which the structural diff never changes.
  local diff = file.diffs.line
  local r1, r2 = stretch(diff, s1, l1), stretch(diff, s2, l2)
  if not (r1 and r2) then
    return nil, "GitHub only takes comments on lines in the diff: a change or the 3 lines around it"
  end
  if s1 == s2 then
    if r1[1] ~= r2[1] then
      return nil, "a comment's lines must stay within one hunk"
    end
    if l1 > l2 then
      l1, l2 = l2, l1
    end
    if l1 == l2 then
      return { path = path, side = s2, line = l2 }
    end
  end
  return { path = path, side = s2, line = l2, start_side = s1, start_line = l1 }
end

---@param side NvimDiff.Side
---@param lnum integer
---@return string
local function at(side, lnum)
  return side == "old" and ("old L%d"):format(lnum) or ("L%d"):format(lnum)
end

--- `Comment on a.lua L12`, `… L12–14`, `… old L3`, `… old L3 – L5`.
---@param target NvimDiff.CommentTarget
---@return string
function M.header(target)
  local where
  if not target.start_line then
    where = at(target.side, target.line)
  elseif target.start_side == target.side then
    where = ("%s–%d"):format(at(target.side, target.start_line), target.line)
  else
    where = ("%s – %s"):format(at(target.start_side, target.start_line), at(target.side, target.line))
  end
  return ("Comment on %s %s"):format(target.path, where)
end

--- `Reply to alice on a.lua L12: why 9090?` — the thread's first comment, cut to one line.
---@param thread NvimDiff.GitHub.Thread
---@param width? integer Cells the excerpt may take; default 40.
---@return string
function M.reply_header(thread, width)
  width = width or 40
  local first = thread.comments[1]
  local who = first and first.author or "?"
  local excerpt = first and vim.trim((first.body:gsub("%s+", " "))) or ""
  if vim.fn.strdisplaywidth(excerpt) > width then
    excerpt = vim.fn.strcharpart(excerpt, 0, width - 1) .. "…"
  end
  local range = thread_mod.range_label(thread)
  local where = range and ("%s %s"):format(thread.path, range) or thread.path
  if thread.side == "old" and range then
    where = ("%s old %s"):format(thread.path, range)
  end
  return ("Reply to %s on %s: %s"):format(who, where, excerpt)
end

--- A thread built from a comment GitHub just accepted, for when the threads cannot be
--- refetched. It carries the comment's node id as its own id — which is **not** a thread id
--- — so it offers replies (they go by the comment's REST id) but not resolving.
---@param c NvimDiff.GitHub.PostedComment
---@return NvimDiff.GitHub.Thread
function M.thread_of(c)
  return {
    id = c.id,
    path = c.path,
    side = c.side,
    start_side = c.start_line and c.start_side or nil,
    line = c.line,
    start_line = c.start_line,
    resolved = false,
    outdated = false,
    collapsed = false,
    subject = "line",
    can_reply = true,
    can_resolve = false,
    can_unresolve = false,
    comments = { c },
  }
end

return M
