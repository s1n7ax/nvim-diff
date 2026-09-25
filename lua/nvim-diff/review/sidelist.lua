--- The side list: comment threads that have no line in the diff to hang from — outdated
--- threads (the code they were on has changed, and GitHub returns no line), file-level
--- comments, and threads whose line is not in the file shown — each drawn in full.
---
--- A split window beside the diff, not a float: it is read like the file panel, it stays
--- while the reviewer steps through files, and `q` closes it. The text is ordinary buffer
--- text (read-only), so it scrolls, searches and yanks like any buffer.

local help = require("nvim-diff.ui.help")
local thread_mod = require("nvim-diff.review.thread")

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("nvim-diff.sidelist")

M.TITLE = "Outdated and file-level comments"

--- What a place is called in the list.
---@type table<NvimDiff.ThreadPlace, string>
local PLACE = {
  outdated = "outdated",
  file = "file comment",
  off_file = "not in this diff",
}

---@class NvimDiff.SideListItem
---@field thread NvimDiff.GitHub.Thread
---@field place NvimDiff.ThreadPlace

--- The threads of `list` that never hang under a line: outdated and file-level ones, in
--- list order.
---@param list NvimDiff.GitHub.Thread[]
---@return NvimDiff.SideListItem[]
function M.items(list)
  local out = {}
  for _, t in ipairs(list) do
    if t.subject == "file" then
      out[#out + 1] = { thread = t, place = "file" }
    elseif t.outdated or not t.line then
      out[#out + 1] = { thread = t, place = "outdated" }
    end
  end
  return out
end

---@class NvimDiff.SideListText
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, group: string }[] 0-based rows, byte columns.
---@field threads table<integer, NvimDiff.GitHub.Thread> 1-based line to the thread drawn there.

--- The list's text, grouped by path (in order of first appearance), each thread expanded.
---@param items NvimDiff.SideListItem[]
---@param width integer Display cells to wrap bodies to.
---@return NvimDiff.SideListText
function M.render(items, width)
  local lines, marks, threads = {}, {}, {}
  local function add(chunks)
    local col = 0
    local parts = {}
    for _, chunk in ipairs(chunks) do
      local text, group = chunk[1], chunk[2]
      parts[#parts + 1] = text
      if group and group ~= "" and #text > 0 then
        marks[#marks + 1] = { row = #lines, col = col, end_col = col + #text, group = group }
      end
      col = col + #text
    end
    lines[#lines + 1] = table.concat(parts)
  end

  add({ { ("%s · %d"):format(M.TITLE, #items), "NvimDiffPanelTitle" } })
  if #items == 0 then
    add({})
    add({ { "  None.", "NvimDiffThreadMeta" } })
    return { lines = lines, marks = marks, threads = threads }
  end

  local order, groups = {}, {}
  for _, item in ipairs(items) do
    local p = item.thread.path
    if not groups[p] then
      groups[p] = {}
      order[#order + 1] = p
    end
    table.insert(groups[p], item)
  end
  for _, p in ipairs(order) do
    add({})
    add({ { p, "NvimDiffPanelDir" } })
    for i, item in ipairs(groups[p]) do
      if i > 1 then
        add({})
      end
      local vls = thread_mod.expanded_lines(item.thread, { width = width, label = PLACE[item.place] })
      for _, vl in ipairs(vls) do
        add(vl)
        threads[#lines] = item.thread
      end
    end
  end
  return { lines = lines, marks = marks, threads = threads }
end

---@class NvimDiff.SideListSpec
---@field items NvimDiff.SideListItem[]
--- Window to split beside (to its right). Default: the current window.
---@field win? integer
---@field width? integer Columns; default 50.

---@class NvimDiff.SideList
---@field buf integer
---@field win integer
---@field items NvimDiff.SideListItem[]
---@field threads? table<integer, NvimDiff.GitHub.Thread> Buffer line to the thread drawn there.
local SideList = {}
SideList.__index = SideList

--- Open the list in a split right of `spec.win`. The cursor stays where it was.
---@param spec NvimDiff.SideListSpec
---@return NvimDiff.SideList
function M.open(spec)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "nvim-diff-threads"
  pcall(api.nvim_buf_set_name, buf, ("nvim-diff://threads/%d"):format(buf))
  local win = api.nvim_open_win(buf, false, {
    split = "right",
    win = spec.win or api.nvim_get_current_win(),
    width = spec.width or 50,
  })
  for opt, v in pairs({
    winfixwidth = true,
    winfixbuf = true,
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    spell = false,
    cursorline = true,
  }) do
    api.nvim_set_option_value(opt, v, { win = win, scope = "local" })
  end
  local self = setmetatable({ buf = buf, win = win, items = spec.items }, SideList)
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = buf, nowait = true, desc = "nvim-diff: close the comment list" })
  help.attach(buf)
  self:set(spec.items)
  return self
end

--- Replace what the list shows.
---@param items NvimDiff.SideListItem[]
function SideList:set(items)
  self.items = items
  if not api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width = self:is_open() and api.nvim_win_get_width(self.win) - 1 or 50
  local text = M.render(items, math.max(20, width))
  self.threads = text.threads
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, text.lines)
  vim.bo[self.buf].modifiable = false
  api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  for _, m in ipairs(text.marks) do
    api.nvim_buf_set_extmark(self.buf, M.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.group })
  end
end

--- The thread drawn on the cursor's line of the list, if any.
---@return NvimDiff.GitHub.Thread?
function SideList:thread_at_cursor()
  if not self:is_open() then
    return nil
  end
  return (self.threads or {})[api.nvim_win_get_cursor(self.win)[1]]
end

---@return boolean
function SideList:is_open()
  return api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

--- Close the window (the buffer goes with it). Idempotent.
function SideList:close()
  if api.nvim_win_is_valid(self.win) then
    api.nvim_set_option_value("winfixbuf", false, { win = self.win, scope = "local" })
    pcall(api.nvim_win_close, self.win, true)
  end
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

return M
