--- The editor split: a bottom split holding a real buffer the user writes review text in —
--- a new comment, a reply, an edit of their own comment, or the review verdict's summary —
--- multi-line markdown, spell, undo, under a header naming what it answers. The diff panes
--- stay read-only; this is the only place review text is typed.
---
---     local c = require("nvim-diff.review.compose").open({
---       header = "Comment on src/a.lua:12",
---       on_submit = function(text) return post(text) end, -- ok, or false and an error
---       on_done = function(how) end,
---     })
---
--- Typed text is never lost by accident, and never touches the disk:
---
--- * The buffer is `buftype=acwrite`, so `:w` posts rather than writes — or, where a
---   reflexive write must not post (the verdict), only says which key does.
--- * Only the cancel key throws text away, and it asks first when there is anything to lose
---   (text typed, or an edited comment changed).
--- * Closing the window any other way (`:q`, `:tabclose`) keeps a draft with changes, hidden,
---   and `show` brings it back; an unchanged one just goes.
--- * A failed post leaves the split open with the text as typed and the error drawn under it.
--- * When the review ends under an unsent draft, the buffer is kept — listed, with nothing
---   left to post to — and the user is told its name (`orphan`).
---
--- In a comment, `keymaps.comment.suggest` inserts a GitHub ```` ```suggestion ```` block
--- holding the commented lines as they are, for the reviewer to edit into the fix.
---
--- Knows nothing about GitHub: the caller's `on_submit` does the posting.

local config = require("nvim-diff.config")
local log = require("nvim-diff.core.log")

local api = vim.api

local M = {}

--- Namespace of the error drawn under the text.
M.ns = api.nvim_create_namespace("nvim-diff.compose")

--- Asks whether to throw away a draft. Replaceable, so specs can answer without a prompt.
---@param prompt string
---@return boolean discard
function M.confirm(prompt)
  return vim.fn.confirm(prompt, "&Discard\n&Keep", 2) == 1
end

---@alias NvimDiff.ComposeDone "posted"|"cancelled"|"closed"

--- The lines a suggestion block starts from, or why there are none here.
---@class NvimDiff.ComposeSuggestion
---@field lines? string[]
---@field reason? string

---@class NvimDiff.ComposeOpts
---@field header string What the text is on, or which thread it answers.
--- Posts the text. Returns true, or false with the reason shown in the split.
---@field on_submit fun(text: string): boolean, string?
--- Called once when the split goes: posted, cancelled with the key, or its buffer wiped
--- some other way (`:q!`).
---@field on_done? fun(how: NvimDiff.ComposeDone)
---@field lines? string[] Initial text: an edited comment's body. Unchanged, it is not a draft.
--- What the text is, in messages and key descriptions. Default `"comment"`.
---@field noun? string
--- Buffer name kind: `nvim-diff://<kind>/<n>`. Default `"comment"`.
---@field kind? string
--- The submit and cancel keys. Default `keymaps.comment`.
---@field keys? { submit?: NvimDiff.Config.Key, cancel?: NvimDiff.Config.Key }
--- `:w` posts (the default), or only says which key does.
---@field write_posts? boolean
--- Post empty text too (an approval needs no summary). Default false.
---@field allow_empty? boolean
--- Start in insert mode. Default true.
---@field insert? boolean
--- How a hidden draft is brought back, for the warning when its window closes.
---@field resume_hint? string
--- The commented lines, for `keymaps.comment.suggest`. Without it the key is not mapped.
---@field suggestion? NvimDiff.ComposeSuggestion

---@class NvimDiff.Compose
---@field buf integer
---@field win? integer
---@field header string
---@field return_win integer The window the split was opened from; focus goes back there.
---@field error? string The last failed post's reason, while it shows.
---@field done boolean `on_done` has been called.
---@field closed? boolean The split is gone.
---@field orphaned boolean Its review ended; the text is kept, posting is off.
---@field private opts NvimDiff.ComposeOpts
---@field private initial string The text it opened with.
---@field private group integer
local Compose = {}
Compose.__index = Compose

local counter = 0

---@param s string
---@return string
local function statusline_escape(s)
  return (s:gsub("%%", "%%%%"))
end

--- Lines with blank lines trimmed off both ends, joined.
---@param lines string[]
---@return string
local function join(lines)
  local first, last = 1, #lines
  while first <= last and vim.trim(lines[first]) == "" do
    first = first + 1
  end
  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  return table.concat(lines, "\n", first, last)
end

--- Open the split under every window of the tabpage and focus it.
---@param opts NvimDiff.ComposeOpts
---@return NvimDiff.Compose
function M.open(opts)
  counter = counter + 1
  local buf = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(buf, ("nvim-diff://%s/%d"):format(opts.kind or "comment", counter))
  local bo = vim.bo[buf]
  bo.buftype = "acwrite"
  -- Not `wipe`: whatever closes the window (`:q`, `:tabclose`, the review ending), the
  -- text must outlive it. `on_window_closed` decides what happens to the buffer.
  bo.bufhidden = "hide"
  bo.swapfile = false
  bo.filetype = "markdown"
  if opts.lines then
    api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    bo.modified = false
  end

  local self = setmetatable({
    buf = buf,
    header = opts.header,
    return_win = api.nvim_get_current_win(),
    done = false,
    orphaned = false,
    opts = opts,
    initial = join(opts.lines or {}),
  }, Compose)
  self:map_keys()

  self.group = api.nvim_create_augroup(("nvim-diff.compose.%d"):format(buf), { clear = true })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = self.group,
    buffer = buf,
    callback = function()
      if opts.write_posts == false then
        local key = self:keys().submit
        log.warn(":w does not post the %s%s", self:noun(), type(key) == "string" and ("; press " .. key) or "")
        return
      end
      self:submit()
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = self.group,
    buffer = buf,
    callback = function()
      pcall(api.nvim_del_augroup_by_id, self.group)
      self.closed = true
      self:finish("closed")
    end,
  })
  self:show()
  if opts.insert ~= false then
    vim.cmd.startinsert()
  end
  return self
end

---@return string
function Compose:noun()
  return self.opts.noun or "comment"
end

---@return { submit?: NvimDiff.Config.Key, cancel?: NvimDiff.Config.Key }
function Compose:keys()
  return self.opts.keys or config.get().keymaps.comment
end

--- Open the split window on the buffer — again, when something closed it — and focus it.
function Compose:show()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_set_current_win(self.win)
    return
  end
  -- `win = -1`: a split of the whole tabpage, under the panel and the diff alike.
  self.win = api.nvim_open_win(self.buf, true, {
    split = "below",
    win = -1,
    height = config.get().comment.height,
  })
  local wo = vim.wo[self.win]
  wo.spell = true
  wo.wrap = true
  wo.linebreak = true
  wo.winfixheight = true
  wo.winfixbuf = true
  self:draw_header()
  local win = self.win
  api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(win),
    once = true,
    callback = function()
      -- After the close: wiping a buffer inside `WinClosed` is not safe.
      vim.schedule(function()
        self:on_window_closed(win)
      end)
    end,
  })
end

--- The split's window went some way other than `close` (`:q`, `:tabclose`). A draft with
--- nothing to lose goes with it; one with changes is kept, hidden, for `show` to bring back.
---@param win integer
function Compose:on_window_closed(win)
  if self.closed or self.win ~= win or not api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.win = nil
  if not self:is_changed() then
    self:close("closed", { focus = false })
    return
  end
  if not self.orphaned then
    log.warn("the unsent %s is kept; %s", self:noun(), self.opts.resume_hint or "the comment key brings it back")
  end
end

--- Change the header, say when the split now posts something else.
---@param header string
function Compose:set_header(header)
  self.header = header
  self:draw_header()
end

--- The winbar: the header, then the keys.
function Compose:draw_header()
  if not self.win or not api.nvim_win_is_valid(self.win) then
    return
  end
  local keys = self:keys()
  local hints = {}
  if self.orphaned then
    hints[#hints + 1] = "review ended — not posted"
  else
    local submit = type(keys.submit) == "string" and keys.submit or nil
    if self.opts.write_posts ~= false then
      hints[#hints + 1] = submit and (submit .. " or :w post") or ":w post"
    elseif submit then
      hints[#hints + 1] = submit .. " post"
    end
    local suggest = config.get().keymaps.comment.suggest
    -- Mapped wherever there is a suggestion spec, so the key can say why there is none;
    -- offered in the header only where it works.
    if self.opts.suggestion and self.opts.suggestion.lines and type(suggest) == "string" then
      hints[#hints + 1] = suggest .. " suggestion"
    end
  end
  if type(keys.cancel) == "string" then
    hints[#hints + 1] = keys.cancel .. " cancel"
  end
  vim.wo[self.win].winbar = ("%%#NvimDiffCommentHeader# %s %%#NvimDiffCommentHint#  %s"):format(
    statusline_escape(self.header),
    statusline_escape(table.concat(hints, " · "))
  )
end

function Compose:map_keys()
  local keys = self:keys()
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = self.buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.submit, function()
    vim.cmd.stopinsert()
    self:submit()
  end, "post the " .. self:noun())
  map(keys.cancel, function()
    vim.cmd.stopinsert()
    self:cancel()
  end, "cancel the " .. self:noun())
  if self.opts.suggestion then
    map(config.get().keymaps.comment.suggest, function()
      self:insert_suggestion()
    end, "insert a suggestion of the commented lines")
  end
end

--- Whether the split is still up.
---@return boolean
function Compose:is_open()
  return not self.closed and api.nvim_buf_is_valid(self.buf)
end

--- The text as typed, blank lines at either end dropped.
---@return string
function Compose:text()
  if not api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return join(api.nvim_buf_get_lines(self.buf, 0, -1, false))
end

--- Whether there is any text.
---@return boolean
function Compose:has_text()
  return vim.trim(self:text()) ~= ""
end

--- Whether closing would lose anything: text typed into an empty split, or an edited
--- comment changed from what it was.
---@return boolean
function Compose:is_changed()
  local text = self:text()
  if self.initial == "" then
    return vim.trim(text) ~= ""
  end
  return text ~= self.initial
end

--- Show `message` under the text (nil clears it).
---@param message? string
function Compose:set_error(message)
  self.error = message
  if not api.nvim_buf_is_valid(self.buf) then
    return
  end
  api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  if not message then
    return
  end
  local virt = {}
  for i, line in ipairs(vim.split(message, "\n", { plain = true })) do
    virt[#virt + 1] = { { (i == 1 and "✗ not posted: " or "  ") .. line, "NvimDiffCommentError" } }
  end
  local last = api.nvim_buf_line_count(self.buf) - 1
  api.nvim_buf_set_extmark(self.buf, M.ns, last, 0, { virt_lines = virt })
end

--- The fence for a block holding `lines`: three backticks, or one more than the longest
--- run starting any of its lines, so a code fence inside the suggestion cannot close it.
---@param lines string[]
---@return string
function M.fence(lines)
  local n = 3
  for _, l in ipairs(lines) do
    local run = l:match("^%s*(`+)")
    if run and #run >= n then
      n = #run + 1
    end
  end
  return ("`"):rep(n)
end

--- Insert a suggestion block holding the commented lines, on the cursor's line when it is
--- blank, else under it, with the cursor on the block's first line of code.
---@return boolean inserted False when this split has no lines to suggest on.
function Compose:insert_suggestion()
  local s = self.opts.suggestion
  if not self:is_open() or not s then
    return false
  end
  if not s.lines then
    log.warn("no suggestion here: %s", s.reason or "no lines")
    return false
  end
  local fence = M.fence(s.lines)
  local block = { fence .. "suggestion" }
  vim.list_extend(block, s.lines)
  block[#block + 1] = fence

  local win = self.win and api.nvim_win_is_valid(self.win) and self.win or nil
  local row = win and api.nvim_win_get_cursor(win)[1] or api.nvim_buf_line_count(self.buf)
  local here = api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
  local at
  if vim.trim(here) == "" then
    api.nvim_buf_set_lines(self.buf, row - 1, row, false, block)
    at = row
  else
    api.nvim_buf_set_lines(self.buf, row, row, false, block)
    at = row + 1
  end
  if win then
    api.nvim_win_set_cursor(win, { at + 1, 0 })
  end
  return true
end

--- Post the text. On success the split closes; on failure it stays, with the error.
---@return boolean posted
function Compose:submit()
  if not self:is_open() then
    return false
  end
  if self.orphaned then
    self:set_error("the review has ended; copy the text before closing this buffer")
    return false
  end
  local text = self:text()
  if vim.trim(text) == "" and not self.opts.allow_empty then
    self:set_error(("the %s is empty"):format(self:noun()))
    return false
  end
  self:set_error(nil)
  local ok, message = self.opts.on_submit(text)
  if not ok then
    message = message or "unknown error"
    self:set_error(message)
    log.error("%s not posted: %s", self:noun(), message)
    return false
  end
  if api.nvim_buf_is_valid(self.buf) then
    vim.bo[self.buf].modified = false
  end
  self:close("posted")
  return true
end

--- Cancel: close the split, asking first when there is anything to lose.
---@return boolean cancelled False when the user chose to keep the text.
function Compose:cancel()
  if not self:is_open() then
    return true
  end
  if self:is_changed() and not M.confirm(("Discard this %s?"):format(self:noun())) then
    return false
  end
  self:close("cancelled")
  return true
end

---@param how NvimDiff.ComposeDone
function Compose:finish(how)
  if self.done then
    return
  end
  self.done = true
  if self.opts.on_done then
    self.opts.on_done(how)
  end
end

--- Close the split and wipe its buffer, without asking. Focus returns to the window it was
--- opened from.
---@param how? NvimDiff.ComposeDone Default `"cancelled"`.
---@param opts? { focus?: boolean } `focus = false` leaves the cursor where it is.
function Compose:close(how, opts)
  self.closed = true
  self:finish(how or "cancelled")
  local back = self.return_win
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
  if not (opts and opts.focus == false) and api.nvim_win_is_valid(back) then
    api.nvim_set_current_win(back)
  end
end

--- The review this split posts to is ending. A split with nothing to lose just closes; one
--- with changes is kept as a listed buffer, with posting turned off, so the text can still
--- be copied out.
---@return string? name The kept buffer's name, when there was text to keep.
function Compose:orphan()
  if not self:is_open() then
    return nil
  end
  if not self:is_changed() then
    self:close("closed", { focus = false })
    return nil
  end
  self.orphaned = true
  self:finish("closed")
  vim.bo[self.buf].buflisted = true
  self:set_error(nil)
  self:draw_header()
  return api.nvim_buf_get_name(self.buf)
end

return M
