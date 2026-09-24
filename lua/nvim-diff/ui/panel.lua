--- The file panel: a fixed-width window on the left listing a view's file entries.
---
--- The panel draws; it decides nothing. The view (`views/diff.lua`) owns the entries, the
--- listing, which directories are collapsed and which entry is current, and hands the panel
--- a model to draw. The panel answers hit-tests — which row is on this line, which line
--- shows this entry — so every panel action is "find the row under the cursor".
---
--- Layout, top to bottom: the title, a counts line (`12 files  +340 -120`, plus
--- `3/7 viewed` in a review), a notice line when the list is summarised, then one row per
--- directory or file. The cursor is kept off the header lines.

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

---@class NvimDiff.Panel
---@field buf integer
---@field win? integer
---@field width integer
---@field rows table<integer, NvimDiff.TreeRow> Buffer line to row.
---@field first_row integer Buffer line of the first row.
---@field model? NvimDiff.PanelModel
local Panel = {}
Panel.__index = Panel

---@class NvimDiff.PanelOpts
---@field width integer

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
  local self = setmetatable({ buf = buf, width = opts.width, rows = {}, first_row = 1 }, Panel)

  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      self:clamp_cursor()
    end,
  })
  return self
end

--- Show the panel in a new window split to the left of `anchor`, `width` columns wide.
---@param anchor integer
---@return integer win
function Panel:open(anchor)
  local win = api.nvim_open_win(self.buf, false, { split = "left", win = anchor, width = self.width })
  for name, value in pairs(M.WIN_OPTIONS) do
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
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

--- Put the panel back at its width, e.g. after a window next to it was split.
function Panel:fix_width()
  if self:is_open() then
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
  self.first_row = #lines + 1
  self.rows = {}
  for _, row in ipairs(model.tree.rows) do
    lines[#lines + 1] = row_line(row, review, flat)
    self.rows[#lines] = row
  end

  local text = {}
  for i, l in ipairs(lines) do
    text[i] = table.concat(l.text)
  end
  api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  api.nvim_buf_set_lines(self.buf, 0, -1, false, text)
  api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  api.nvim_set_option_value("modified", false, { buf = self.buf })

  api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  for i, l in ipairs(lines) do
    for _, h in ipairs(l.hls) do
      api.nvim_buf_set_extmark(self.buf, M.ns, i - 1, h[1], { end_col = h[2], hl_group = h[3], priority = 150 })
    end
  end
  self:set_current(model.current)
  self:clamp_cursor()
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
---@param entry NvimDiff.FileEntry
---@return integer?
function Panel:line_of(entry)
  for lnum, row in pairs(self.rows) do
    if row.kind == "file" and row.entry == entry then
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
