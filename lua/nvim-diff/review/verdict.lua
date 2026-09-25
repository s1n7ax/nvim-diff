--- The review verdict: `:NvimDiffVerdict [approve|request-changes|comment]` in a PR review's
--- tab opens a summary buffer in the editor split (`review/compose.lua`, the same split
--- comments are written in); `keymaps.verdict.post` submits the verdict
--- (`github/review.lua`), `keymaps.verdict.cancel` closes the split.
---
--- Only ever submitted by that key, in that split, after that command: nothing else in the
--- plugin calls `post`, and `:w` in the split does not post (a reflexive write must not
--- approve a PR). The summary buffer is a real buffer — markdown, spell, undo — and is never
--- written to disk.
---
--- Typed text is never lost by accident, as in every editor split: a failed post keeps the
--- split open with the text and GitHub's error under it; cancelling with text asks first;
--- `:q` hides a summary with text, and the command brings it back; a review that ends under
--- one leaves it in a listed buffer.

local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")
local gh_review = require("nvim-diff.github.review")

local api = vim.api

local M = {}

--- The words the command takes, to GitHub's event names.
---@type table<string, NvimDiff.GitHub.ReviewEvent>
M.ARGS = {
  approve = "APPROVE",
  ["request-changes"] = "REQUEST_CHANGES",
  comment = "COMMENT",
}

---@class NvimDiff.Verdict
---@field review NvimDiff.Review
---@field event NvimDiff.GitHub.ReviewEvent
---@field compose NvimDiff.Compose The split.
---@field buf integer
---@field result? NvimDiff.GitHub.Review What GitHub answered to the post.
local Verdict = {}
Verdict.__index = Verdict

--- The verdict split of each review.
---@type table<NvimDiff.Review, NvimDiff.Verdict>
local by_review = setmetatable({}, { __mode = "k" })

--- The verdict split open for `review` (shown or hidden), if any.
---@param review NvimDiff.Review
---@return NvimDiff.Verdict?
function M.get(review)
  local v = by_review[review]
  if v and v.compose:is_open() and not v.compose.orphaned then
    return v
  end
  return nil
end

--- The header: the verdict, the PR, whether a summary is needed.
---@return string
function Verdict:header()
  local info = assert(gh_review.info(self.event))
  return ("%s PR #%d — summary %s"):format(
    info.label,
    self.review.pr.number,
    info.needs_body and "required" or "optional"
  )
end

--- The split's window, while it shows.
---@return integer?
function Verdict:win()
  local win = self.compose.win
  return win and api.nvim_win_is_valid(win) and win or nil
end

--- Switch the verdict the split will post.
---@param event NvimDiff.GitHub.ReviewEvent
function Verdict:set_event(event)
  self.event = event
  self.compose:set_error(nil)
  self.compose:set_header(self:header())
end

--- The summary as typed, blank lines at either end dropped.
---@return string
function Verdict:text()
  return self.compose:text()
end

--- Cancel: close the split, asking first when there is text to lose.
---@return boolean closed False when the user chose to keep the text.
function Verdict:cancel()
  return self.compose:cancel()
end

--- Close the split, dropping the text. Idempotent.
function Verdict:close()
  if self.compose:is_open() then
    self.compose:close("cancelled")
  end
end

--- Submit the verdict. On success the split closes; on failure it stays with the text and
--- the error under it.
---@return boolean posted
function Verdict:post()
  return self.compose:submit()
end

--- What the split's submit does: post the verdict with `text` as its summary.
---@param text string
---@return boolean ok
---@return string? err
function Verdict:send(text)
  local info = assert(gh_review.info(self.event))
  if not self.review:is_valid() then
    return false, "the review has ended"
  end
  if info.needs_body and vim.trim(text) == "" then
    return false, info.label .. " needs a summary"
  end
  vim.notify(("nvim-diff: posting %s on PR #%d…"):format(info.label, self.review.number), vim.log.levels.INFO)
  vim.cmd.redraw()
  local result, err = gh_review.submit(self.review.pr, self.event, text)
  if not result then
    ---@cast err NvimDiff.GitHub.Error
    return false, err.message
  end
  self.result = result
  vim.notify(("nvim-diff: %s posted on PR #%d"):format(info.label, self.review.number), vim.log.levels.INFO)
  return true
end

--- Open the verdict split for `review`, or bring back the one already open and switch it
--- to `event`, keeping its text.
---@param review NvimDiff.Review
---@param event NvimDiff.GitHub.ReviewEvent
---@return NvimDiff.Verdict
function M.open(review, event)
  assert(gh_review.info(event), "not a review verdict")
  local existing = M.get(review)
  if existing then
    existing.compose:show()
    existing:set_event(event)
    return existing
  end

  local self = setmetatable({ review = review, event = event }, Verdict)
  local keys = config.get().keymaps.verdict
  self.compose = compose.open({
    header = self:header(),
    noun = "review verdict",
    kind = "verdict",
    keys = { submit = keys.post, cancel = keys.cancel },
    write_posts = false,
    allow_empty = true,
    insert = false,
    resume_hint = ":NvimDiffVerdict brings it back",
    on_submit = function(text)
      return self:send(text)
    end,
    on_done = function()
      if by_review[review] == self then
        by_review[review] = nil
      end
    end,
  })
  self.buf = self.compose.buf
  by_review[review] = self
  return self
end

--- The review is ending: keep a summary with text in a listed buffer, drop an empty one.
---@param review NvimDiff.Review
---@return string? name The kept buffer's name.
function M.orphan(review)
  local v = by_review[review]
  by_review[review] = nil
  return v and v.compose:orphan() or nil
end

--- `:NvimDiffVerdict [approve|request-changes|comment]`. With no argument, a picker asks.
---@param arg string
function M.command(arg)
  local review = require("nvim-diff.views.review").get()
  if not review then
    vim.notify("nvim-diff: :NvimDiffVerdict works in a PR review's tab (:NvimDiffPR)", vim.log.levels.ERROR)
    return
  end
  arg = vim.trim(arg or ""):lower()
  if arg ~= "" then
    local event = M.ARGS[arg]
    if not event then
      vim.notify(
        ("nvim-diff: :NvimDiffVerdict takes approve, request-changes or comment, not %q"):format(arg),
        vim.log.levels.ERROR
      )
      return
    end
    M.open(review, event)
    return
  end
  vim.ui.select(gh_review.EVENTS, {
    prompt = ("Verdict on PR #%d"):format(review.number),
    format_item = function(row)
      return row.label
    end,
  }, function(row)
    if row and review:is_valid() then
      M.open(review, row.event)
    end
  end)
end

--- Completion for the command's one argument.
---@param arglead string
---@return string[]
function M.complete(arglead)
  local out = {}
  for _, word in ipairs({ "approve", "request-changes", "comment" }) do
    if vim.startswith(word, arglead) then
      out[#out + 1] = word
    end
  end
  return out
end

return M
