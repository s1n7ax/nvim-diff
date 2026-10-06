--- The file panel: a fixed-width window on the left listing a view's file entries.
---
--- The panel draws; it decides nothing. The view (`views/diff.lua`) owns the entries, the
--- listing, which directories are collapsed and which entry is current, and hands the panel
--- a model to draw. The panel answers hit-tests — which row is on this line, which line
--- shows this entry — so every panel action is "find the row under the cursor".
---
--- Layout, top to bottom: the title, a counts line (`12 files  +340 -120`, plus
--- `3/7 viewed` in a review), a review's sync status lines (new commits on GitHub, merged),
--- a notice line when the list is summarised, then one row per directory or file. The
--- cursor is kept off the header lines.
---
--- The history view reuses the window and buffer with its own rows: a panel along the
--- bottom (`position = "bottom"`), drawn through `draw` and grown or patched through
--- `splice` so a long history never costs a full redraw per batch.

local hl = require("nvim-diff.ui.hl")

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("nvim-diff.panel")
--- The current-entry mark lives apart, so moving it does not repaint the text.
M.current_ns = api.nvim_create_namespace("nvim-diff.panel.current")

local STATUS_HL = {
  A = "NvimDiffPanelStatusAdded",
  C = "NvimDiffPanelStatusAdded",
  ["?"] = "NvimDiffPanelStatusAdded",
  D = "NvimDiffPanelStatusDeleted",
  M = "NvimDiffPanelStatusModified",
  R = "NvimDiffPanelStatusModified",
  T = "NvimDiffPanelStatusModified",
  U = "NvimDiffPanelStatusConflicted",
  X = "NvimDiffPanelStatusConflicted",
}

--- Viewed-state marks, one cell each. Shown only in a review.
local VIEWED_MARK = {
  viewed = { "✓", "NvimDiffPanelViewed" },
  rechanged = { "↻", "NvimDiffPanelRechanged" },
  unviewed = { " ", nil },
}

--- Options on the panel window, all window-local.
M.WIN_OPTIONS = {
  winfixwidth = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  wrap = false,
  list = false,
  spell = false,
  cursorline = true,
}

--- `12345` as `12,345`.
---@param n integer
---@return string
function M.thousands(n)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

---@class NvimDiff.PanelModel
---@field title string
---@field tree NvimDiff.Tree
---@field listing NvimDiff.Listing
---@field entries NvimDiff.FileEntry[] Every entry, for the counts.
---@field current? NvimDiff.FileEntry
---@field notice? string Shown under the counts, e.g. why the list is summarised.
---@field status? NvimDiff.PanelStatus[] Shown under the counts, above `notice`.

--- A header line of its own, in its own highlight: a PR review's sync state.
---@class NvimDiff.PanelStatus
---@field text string
---@field hl string

---@class NvimDiff.Panel
---@field buf integer
---@field win? integer
---@field width integer
---@field height? integer For a panel at the bottom.
---@field position "left"|"bottom"
---@field rows table<integer, NvimDiff.TreeRow> Buffer line to row.
---@field first_row integer Buffer line of the first row.
---@field model? NvimDiff.PanelModel
local Panel = {}
Panel.__index = Panel

---@class NvimDiff.PanelOpts
---@field width integer Columns, for a panel on the left.
---@field height? integer Rows, for a panel at the bottom.
---@field position? "left"|"bottom" Defaults to `"left"`.

--- Create the panel's buffer. No window yet; see `open`.
---@param opts NvimDiff.PanelOpts
---@return NvimDiff.Panel
function M.new(opts)
  hl.setup()
  local buf = api.nvim_create_buf(false, true)
  for name, value in pairs({
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    buflisted = false,
    undolevels = -1,
    modifiable = false,
  }) do
    api.nvim_set_option_value(name, value, { buf = buf })
  end
  api.nvim_buf_set_name(buf, "nvim-diff://panel/" .. buf)
  api.nvim_set_option_value("filetype", "nvim-diff-panel", { buf = buf })
  local self = setmetatable({
    buf = buf,
    width = opts.width,
    height = opts.height,
    position = opts.position or "left",
    rows = {},
    first_row = 1,
  }, Panel)

  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      self:clamp_cursor()
    end,
  })
  return self
end

--- Show the panel in a new window split to the left of `anchor`, `width` columns wide — or,
--- for a bottom panel, below it, `height` rows high.
---@param anchor integer
---@return integer win
function Panel:open(anchor)
  local win
  if self.position == "bottom" then
    win = api.nvim_open_win(self.buf, false, { split = "below", win = anchor, height = self.height })
  else
    win = api.nvim_open_win(self.buf, false, { split = "left", win = anchor, width = self.width })
  end
  for name, value in pairs(M.WIN_OPTIONS) do
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  if self.position == "bottom" then
    api.nvim_set_option_value("winfixwidth", false, { win = win, scope = "local" })
    api.nvim_set_option_value("winfixheight", true, { win = win, scope = "local" })
  end
  api.nvim_set_option_value("winfixbuf", true, { win = win, scope = "local" })
  hl.apply_window(win)
  self.win = win
  return win
end

---@return boolean
function Panel:is_open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

--- Put the panel back at its width (a bottom panel: its height), e.g. after a window next
--- to it was split.
function Panel:fix_width()
  if not self:is_open() then
    return
  end
  if self.position == "bottom" then
    api.nvim_win_set_height(self.win, self.height)
  else
    api.nvim_win_set_width(self.win, self.width)
  end
end

--- A line being built from highlighted chunks.
---@class NvimDiff.PanelLine
---@field text string[]
---@field len integer
---@field hls { [1]: integer, [2]: integer, [3]: string }[]

---@return NvimDiff.PanelLine
local function line()
  return { text = {}, len = 0, hls = {} }
end

---@param l NvimDiff.PanelLine
---@param text string
---@param group? string
local function put(l, text, group)
  if group and #text > 0 then
    l.hls[#l.hls + 1] = { l.len, l.len + #text, group }
  end
  l.text[#l.text + 1] = text
  l.len = l.len + #text
end

---@param l NvimDiff.PanelLine
---@param additions? integer
---@param deletions? integer
local function put_stats(l, additions, deletions)
  put(l, " ")
  put(l, "+" .. M.thousands(additions or 0), "NvimDiffPanelInsertions")
  put(l, " ")
  put(l, "-" .. M.thousands(deletions or 0), "NvimDiffPanelDeletions")
end

-- The line builders, for other panels drawing through `Panel:draw`.
M.line, M.put, M.put_stats, M.STATUS_HL = line, put, put_stats, STATUS_HL

---@param entries NvimDiff.FileEntry[]
---@return boolean
local function in_review(entries)
  for _, e in ipairs(entries) do
    if e.viewed ~= nil then
      return true
    end
  end
  return false
end

---@param model NvimDiff.PanelModel
---@return NvimDiff.PanelLine[]
local function header(model)
  local title = line()
  put(title, model.title, "NvimDiffPanelTitle")

  local counts = line()
  local adds, dels, viewed = 0, 0, 0
  for _, e in ipairs(model.entries) do
    adds = adds + (e.change.additions or 0)
    dels = dels + (e.change.deletions or 0)
    if e.viewed == "viewed" then
      viewed = viewed + 1
    end
  end
  local n = #model.entries
  put(counts, ("%s %s"):format(M.thousands(n), n == 1 and "file" or "files"))
  put(counts, " ")
  put_stats(counts, adds, dels)
  if in_review(model.entries) then
    put(counts, "  ")
    put(counts, ("%d/%d viewed"):format(viewed, n), "NvimDiffPanelViewed")
  end

  local out = { title, counts }
  for _, status in ipairs(model.status or {}) do
    local l = line()
    put(l, status.text, status.hl)
    out[#out + 1] = l
  end
  if model.notice then
    local notice = line()
    put(notice, model.notice, "NvimDiffPanelDeferred")
    out[#out + 1] = notice
  end
  return out
end

---@param row NvimDiff.TreeRow
---@param review boolean
---@param flat boolean
---@return NvimDiff.PanelLine
local function row_line(row, review, flat)
  local l = line()
  put(l, string.rep("  ", row.depth))
  if row.kind == "dir" then
    put(l, row.collapsed and "▸ " or "▾ ", "NvimDiffPanelDir")
    put(l, row.name .. "/", "NvimDiffPanelDir")
    if row.collapsed then
      put(l, ("  %s %s"):format(M.thousands(row.files), row.files == 1 and "file" or "files"))
      put_stats(l, row.additions, row.deletions)
    end
    return l
  end

  local entry = row.entry
  local c = entry.change
  if review then
    local mark = VIEWED_MARK[entry.viewed or "unviewed"]
    put(l, mark[1], mark[2])
    put(l, " ")
  end
  put(l, c.status, STATUS_HL[c.status])
  put(l, " ")
  local name_hl = entry.viewed == "viewed" and "NvimDiffPanelViewed" or "NvimDiffPanelPath"
  if flat and row.dir ~= "" then
    put(l, row.dir .. "/", "NvimDiffPanelDir")
    put(l, row.name:sub(#row.dir + 2), name_hl)
  else
    put(l, row.name, name_hl)
  end
  if entry.oldpath then
    local old_dir = entry.oldpath:match("^(.*)/[^/]*$") or ""
    local shown = (not flat and old_dir == row.dir) and entry.oldpath:match("[^/]*$") or entry.oldpath
    put(l, " ← " .. shown, "NvimDiffPanelOldPath")
  end
  if c.binary then
    put(l, " bin", "NvimDiffPanelDeferred")
  elseif c.additions then
    put_stats(l, c.additions, c.deletions)
  end
  if entry.deferred and not entry.forced then
    put(l, (" [deferred: %s lines]"):format(M.thousands(entry.lines or 0)), "NvimDiffPanelDeferred")
  end
  return l
end

--- Draw `model`.
---@param model NvimDiff.PanelModel
function Panel:render(model)
  self.model = model
  local review = in_review(model.entries)
  local flat = model.listing == "flat"

  local lines = header(model)
  local first_row = #lines + 1
  local rows = {}
  for _, row in ipairs(model.tree.rows) do
    lines[#lines + 1] = row_line(row, review, flat)
    rows[#lines] = row
  end
  self:draw(lines, rows, first_row, model.current)
end

--- Write built lines into the buffer. `rows` maps a buffer line to the row it shows; a row
--- with an `entry` is what `line_of`/`set_current` find. Lines above `first_row` are header
--- the cursor is kept off.
---@param lines NvimDiff.PanelLine[]
---@param rows table<integer, { entry?: table }>
---@param first_row integer
---@param current? table
function Panel:draw(lines, rows, first_row, current)
  self.rows, self.first_row = rows, first_row
  self:write(0, -1, lines)
  self:set_current(current)
  self:clamp_cursor()
end

--- Replace buffer lines `first` up to (not including) `last` with `lines` — `first == last`
--- inserts — keeping every other line's row and highlights. For a panel that grows or
--- changes in one place (a history streaming in, one commit folding) without paying for a
--- full redraw. `rows[i]` is the row `lines[i]` shows, if any. The current mark is left to
--- the caller (`set_current`).
---@param first integer 1-based.
---@param last integer
---@param lines NvimDiff.PanelLine[] At least one.
---@param rows table<integer, table>
function Panel:splice(first, last, lines, rows)
  local shift = #lines - (last - first)
  local moved = {}
  for lnum, row in pairs(self.rows) do
    if lnum < first then
      moved[lnum] = row
    elseif lnum >= last then
      moved[lnum + shift] = row
    end
  end
  for i = 1, #lines do
    moved[first + i - 1] = rows[i]
  end
  self.rows = moved
  self:write(first - 1, last - 1, lines)
  self:clamp_cursor()
end

--- Set buffer lines `start..end_` (0-based, end-exclusive, -1 = to the end) to `lines`,
--- with their highlights.
---@private
---@param start integer
---@param end_ integer
---@param lines NvimDiff.PanelLine[]
function Panel:write(start, end_, lines)
  local text = {}
  for i, l in ipairs(lines) do
    text[i] = table.concat(l.text)
  end
  api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  api.nvim_buf_set_lines(self.buf, start, end_, false, text)
  api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  api.nvim_set_option_value("modified", false, { buf = self.buf })

  -- Marks on replaced lines collapse onto the first new one; clear them with the rest.
  api.nvim_buf_clear_namespace(self.buf, M.ns, start, start + #lines)
  for i, l in ipairs(lines) do
    for _, h in ipairs(l.hls) do
      api.nvim_buf_set_extmark(self.buf, M.ns, start + i - 1, h[1], { end_col = h[2], hl_group = h[3], priority = 150 })
    end
  end
end

--- The row shown on buffer line `lnum`.
---@param lnum integer
---@return NvimDiff.TreeRow?
function Panel:row_at(lnum)
  return self.rows[lnum]
end

--- The row under the panel's cursor.
---@return NvimDiff.TreeRow?
function Panel:cursor_row()
  if not self:is_open() then
    return nil
  end
  return self.rows[api.nvim_win_get_cursor(self.win)[1]]
end

--- Buffer line showing `entry`, or nil when it is not visible.
---@param entry table A `FileEntry`, or whatever another panel's rows carry as `entry`.
---@return integer?
function Panel:line_of(entry)
  for lnum, row in pairs(self.rows) do
    if row.entry == entry then
      return lnum
    end
  end
  return nil
end

--- Buffer line showing the directory `dir_path`, or nil.
---@param dir_path string
---@return integer?
function Panel:line_of_dir(dir_path)
  for lnum, row in pairs(self.rows) do
    if row.kind == "dir" and row.path == dir_path then
      return lnum
    end
  end
  return nil
end

--- Mark `entry` as the one showing in the diff; nil clears the mark.
---@param entry? NvimDiff.FileEntry
function Panel:set_current(entry)
  if self.model then
    self.model.current = entry
  end
  api.nvim_buf_clear_namespace(self.buf, M.current_ns, 0, -1)
  local lnum = entry and self:line_of(entry)
  if lnum then
    api.nvim_buf_set_extmark(self.buf, M.current_ns, lnum - 1, 0, {
      line_hl_group = "NvimDiffPanelSelected",
      priority = 100,
    })
  end
end

--- Move the panel's cursor to line `lnum`.
---@param lnum integer
function Panel:set_cursor(lnum)
  if self:is_open() then
    api.nvim_win_set_cursor(self.win, { math.min(lnum, api.nvim_buf_line_count(self.buf)), 0 })
  end
end

--- Keep the cursor off the header lines.
function Panel:clamp_cursor()
  if not self:is_open() then
    return
  end
  local cur = api.nvim_win_get_cursor(self.win)
  local last = api.nvim_buf_line_count(self.buf)
  if cur[1] < self.first_row and self.first_row <= last then
    api.nvim_win_set_cursor(self.win, { self.first_row, cur[2] })
  end
end

--- Close the window and wipe the buffer. Idempotent.
function Panel:close()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_set_option_value("winfixbuf", false, { win = self.win, scope = "local" })
    pcall(api.nvim_win_close, self.win, true)
  end
  self.win = nil
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

return M
