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
--- Also the headers the comment split shows, which of a thread's comments are the user's
--- own (to edit or delete), and the lines a suggestion block starts from. Pure apart from
--- reading the fileview.

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

--- A comment's body on one line, cut to `width` cells.
---@param c? NvimDiff.GitHub.Comment
---@param width integer
---@return string
function M.excerpt(c, width)
  local text = c and vim.trim((c.body:gsub("%s+", " "))) or ""
  if vim.fn.strdisplaywidth(text) > width then
    text = vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

--- Where a thread is: `a.lua L12`, `a.lua old L3`, `the file a.lua`.
---@param thread NvimDiff.GitHub.Thread
---@return string
function M.where(thread)
  if thread.subject == "file" then
    return "the file " .. thread.path
  end
  local range = thread_mod.range_label(thread)
  if not range then
    return thread.path
  end
  if thread.side == "old" then
    return ("%s old %s"):format(thread.path, range)
  end
  return ("%s %s"):format(thread.path, range)
end

--- `Reply to alice on a.lua L12: why 9090?` — the thread's first comment, cut to one line.
---@param thread NvimDiff.GitHub.Thread
---@param width? integer Cells the excerpt may take; default 40.
---@return string
function M.reply_header(thread, width)
  local first = thread.comments[1]
  local who = first and first.author or "?"
  return ("Reply to %s on %s: %s"):format(who, M.where(thread), M.excerpt(first, width or 40))
end

--- `Edit your comment on a.lua L12`.
---@param thread NvimDiff.GitHub.Thread
---@return string
function M.edit_header(thread)
  return ("Edit your comment on %s"):format(M.where(thread))
end

--- `Comment on the file a.lua`.
---@param path string
---@return string
function M.file_header(path)
  return ("Comment on the file %s"):format(path)
end

--- One of the user's comments, for a picker: `a.lua L12: the text`.
---@param thread NvimDiff.GitHub.Thread
---@param c NvimDiff.GitHub.Comment
---@param width? integer Default 50.
---@return string
function M.label(thread, c, width)
  return ("%s: %s"):format(M.where(thread), M.excerpt(c, width or 50))
end

--- The user's own comments in `threads`, in order, each with its thread.
---@param threads NvimDiff.GitHub.Thread[]
---@return { thread: NvimDiff.GitHub.Thread, comment: NvimDiff.GitHub.Comment }[]
function M.own(threads)
  local out = {}
  for _, t in ipairs(threads) do
    for _, c in ipairs(t.comments) do
      if c.viewer_did_author then
        out[#out + 1] = { thread = t, comment = c }
      end
    end
  end
  return out
end

--- The new side's lines `first`..`last` of `file`, for a suggestion — GitHub applies one to
--- the PR head only, so the old side has none.
---@param file? NvimDiff.FileView
---@param side? NvimDiff.Side
---@param first? integer
---@param last? integer
---@param start_side? NvimDiff.Side
---@return NvimDiff.ComposeSuggestion
local function suggestion(file, side, first, last, start_side)
  if not file or file:is_closed() then
    return { reason = "the file is not showing" }
  end
  if side ~= "new" or (start_side and start_side ~= "new") then
    return { reason = "a suggestion replaces lines of the new side only" }
  end
  if not (first and last) then
    return { reason = "no lines to suggest on" }
  end
  local lines = file:lines("new")
  if first < 1 or last > #lines or first > last then
    return { reason = "the lines are not in the file shown" }
  end
  return { lines = { unpack(lines, first, last) } }
end

--- The suggestion for a new comment on `target`.
---@param file NvimDiff.FileView
---@param target NvimDiff.CommentTarget
---@return NvimDiff.ComposeSuggestion
function M.suggestion_for_target(file, target)
  return suggestion(file, target.side, target.start_line or target.line, target.line, target.start_side)
end

--- The suggestion for a reply to (or an edit in) `thread`, drawn from `file` when it shows
--- the thread's file.
---@param file? NvimDiff.FileView
---@param path? string The path `file` shows.
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.ComposeSuggestion
function M.suggestion_for_thread(file, path, thread)
  if thread.subject == "file" then
    return { reason = "a file comment has no lines" }
  end
  if thread.outdated or not thread.line then
    return { reason = "the thread's lines are no longer in the diff" }
  end
  if path ~= thread.path then
    return { reason = "the thread's file is not showing" }
  end
  return suggestion(file, thread.side or "new", thread.start_line or thread.line, thread.line, thread.start_side)
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
    subject = c.subject or "line",
    can_reply = true,
    can_resolve = false,
    can_unresolve = false,
    comments = { c },
  }
end

return M
