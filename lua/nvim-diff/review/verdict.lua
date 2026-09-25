--- The review verdict: `:NvimDiffVerdict [approve|request-changes|comment]` in a PR review's
--- tab opens a summary buffer in a bottom split; `keymaps.verdict.post` submits the verdict
--- (`github/review.lua`), `keymaps.verdict.cancel` closes the split.
---
--- Only ever submitted by that key, in that split, after that command: nothing else in the
--- plugin calls `post`, and `:w` in the split does not post (a reflexive write must not
--- approve a PR). The summary buffer is a real buffer — markdown, spell, undo — and is never
--- written to disk.
---
--- Typed text is never lost by accident: a failed post keeps the split open with the text
--- and shows GitHub's error in the header; cancelling with text asks first; the buffer is
--- `buftype=acwrite`, so `:q` on unsent text refuses like any modified buffer (`:q!` is the
--- explicit discard).
---
--- The comment split (new comments and replies) is the same kind of buffer; this module
--- keeps its own small editor so the two could be built in parallel. They should share one.

local config = require("nvim-diff.config")
local gh_review = require("nvim-diff.github.review")

local api = vim.api

local M = {}

--- Rows of the split.
M.HEIGHT = 10

--- The words the command takes, to GitHub's event names.
---@type table<string, NvimDiff.GitHub.ReviewEvent>
M.ARGS = {
  approve = "APPROVE",
  ["request-changes"] = "REQUEST_CHANGES",
  comment = "COMMENT",
}

--- Ask whether to throw typed text away. Replaced in specs, where no one can answer.
---@param message string
---@return boolean discard
function M.confirm(message)
  return vim.fn.confirm(message, "&Discard\n&Keep", 2) == 1
end

---@class NvimDiff.Verdict
---@field review NvimDiff.Review
---@field event NvimDiff.GitHub.ReviewEvent
---@field buf integer
---@field win integer
---@field error? string The last failed post's message, shown in the header.
---@field closed boolean
local Verdict = {}
Verdict.__index = Verdict

--- The open verdict split of each review.
---@type table<NvimDiff.Review, NvimDiff.Verdict>
local by_review = setmetatable({}, { __mode = "k" })

--- The verdict split open for `review`, if any.
---@param review NvimDiff.Review
---@return NvimDiff.Verdict?
function M.get(review)
  local v = by_review[review]
  if v and not v.closed and api.nvim_buf_is_valid(v.buf) then
    return v
  end
  return nil
end

--- `%` is special in a winbar.
---@param s string
---@return string
local function escape(s)
  return (s:gsub("%%", "%%%%"))
end

--- The summary as typed, with blank lines trimmed off both ends.
---@return string
function Verdict:text()
  local lines = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

--- Redraw the header: the verdict, the PR, the keys — or the last error.
function Verdict:header()
  if not api.nvim_win_is_valid(self.win) then
    return
  end
  local info = assert(gh_review.info(self.event))
  local keys = config.get().keymaps.verdict
  local hints = {}
  if keys.post then
    hints[#hints + 1] = keys.post .. " post"
  end
  if keys.cancel then
    hints[#hints + 1] = keys.cancel .. " cancel"
  end
  local pr = self.review.pr
  local parts = {
    "%#NvimDiffHeader# ",
    escape(("%s PR #%d"):format(info.label, pr.number)),
    info.needs_body and " — summary required" or " — summary optional",
    " %*",
  }
  if self.error then
    parts[#parts + 1] = "%#ErrorMsg# " .. escape(self.error) .. " %*"
  end
  parts[#parts + 1] = "%=" .. escape(table.concat(hints, " · "))
  vim.wo[self.win].winbar = table.concat(parts)
end

--- Switch the verdict the split will post.
---@param event NvimDiff.GitHub.ReviewEvent
function Verdict:set_event(event)
  self.event = event
  self.error = nil
  self:header()
end

--- Close the split, dropping the text. Idempotent.
function Verdict:close()
  if self.closed then
    return
  end
  self.closed = true
  if by_review[self.review] == self then
    by_review[self.review] = nil
  end
  if api.nvim_buf_is_valid(self.buf) then
    vim.bo[self.buf].modified = false
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

--- Cancel: close the split, asking first when there is text to lose.
---@return boolean closed False when the user chose to keep the text.
function Verdict:cancel()
  if self:text() ~= "" and not M.confirm("Discard the review summary?") then
    return false
  end
  self:close()
  return true
end

--- Submit the verdict. On success the split closes; on failure it stays with the text and
--- the error in its header.
---@return NvimDiff.GitHub.Review? review
---@return NvimDiff.GitHub.Error? err
function Verdict:post()
  local info = assert(gh_review.info(self.event))
  if not self.review:is_valid() then
    self.error = "the review has ended"
    self:header()
    return nil
  end
  local text = self:text()
  if info.needs_body and text == "" then
    self.error = info.label .. " needs a summary"
    self:header()
    return nil
  end
  vim.notify(("nvim-diff: posting %s on PR #%d…"):format(info.label, self.review.number), vim.log.levels.INFO)
  vim.cmd.redraw()
  local result, err = gh_review.submit(self.review.pr, self.event, text)
  if not result then
    ---@cast err NvimDiff.GitHub.Error
    self.error = err.message
    self:header()
    vim.notify(("nvim-diff: cannot post %s: %s"):format(info.label, err.message), vim.log.levels.ERROR)
    return nil, err
  end
  self:close()
  vim.notify(("nvim-diff: %s posted on PR #%d"):format(info.label, self.review.number), vim.log.levels.INFO)
  return result
end

---@param self NvimDiff.Verdict
local function map_keys(self)
  local keys = config.get().keymaps.verdict
  local function map(modes, lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set(modes, lhs, fn, { buffer = self.buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map({ "n", "i" }, keys.post, function()
    vim.cmd.stopinsert()
    self:post()
  end, "post the review verdict to GitHub")
  map("n", keys.cancel, function()
    self:cancel()
  end, "cancel the review verdict")
end

--- Open the verdict split for `review`, or focus the one already open and switch it to
--- `event`.
---@param review NvimDiff.Review
---@param event NvimDiff.GitHub.ReviewEvent
---@return NvimDiff.Verdict
function M.open(review, event)
  assert(gh_review.info(event), "not a review verdict")
  local existing = M.get(review)
  if existing then
    existing:set_event(event)
    if api.nvim_win_is_valid(existing.win) then
      api.nvim_set_current_win(existing.win)
    else
      existing.win = api.nvim_open_win(existing.buf, true, { split = "below", win = -1, height = M.HEIGHT })
      existing:header()
    end
    return existing
  end

  local buf = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(buf, ("nvim-diff://verdict/%d"):format(review.number))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"

  -- Full width, under the panel and the diff alike.
  local win = api.nvim_open_win(buf, true, { split = "below", win = -1, height = M.HEIGHT })
  vim.wo[win].spell = true
  vim.wo[win].winfixheight = true
  vim.wo[win].winfixbuf = true

  local self = setmetatable({ review = review, event = event, buf = buf, win = win, closed = false }, Verdict)
  by_review[review] = self
  map_keys(self)
  self:header()

  local group = api.nvim_create_augroup(("nvim-diff.verdict.%d"):format(buf), { clear = true })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local key = config.get().keymaps.verdict.post
      vim.notify(
        ("nvim-diff: :w does not post the verdict%s"):format(type(key) == "string" and ("; press " .. key) or ""),
        vim.log.levels.WARN
      )
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      self.closed = true
      if by_review[review] == self then
        by_review[review] = nil
      end
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  return self
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
