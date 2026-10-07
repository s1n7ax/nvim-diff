--- The side list: every review thread, grouped by file, each expanded. `<CR>` on a
--- thread jumps to its file and line; a filter key cycles between all, unresolved and
--- resolved threads. File-level comments also appear above their file, while this list
--- keeps every thread's edit, delete and copy actions available in one place.
---
--- A split window beside the diff, not a float: it is read like the file panel, it stays
--- while the reviewer steps through files, and `q` closes it. The text is ordinary buffer
--- text (read-only), so it scrolls, searches and yanks like any buffer.

local config = require("nvim-diff.config")
local help = require("nvim-diff.ui.help")
local log = require("nvim-diff.core.log")
local thread_mod = require("nvim-diff.review.thread")

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("nvim-diff.sidelist")

M.TITLE = "Review comments"

---@alias NvimDiff.SideListFilter "all"|"unresolved"|"resolved"

--- Filter order for `SideList:cycle_filter`.
---@type NvimDiff.SideListFilter[]
M.FILTERS = { "all", "unresolved", "resolved" }

--- What a place is called in the list. A thread on a line of the diff carries no label.
---@type table<NvimDiff.ThreadPlace, string?>
local PLACE = {
  outdated = "outdated",
  file = "file comment",
  off_file = "not in this diff",
}

---@class NvimDiff.SideListItem
---@field thread NvimDiff.GitHub.Thread
---@field place NvimDiff.ThreadPlace

--- Whether `thread` shows under `filter`.
---@param thread NvimDiff.GitHub.Thread
---@param filter NvimDiff.SideListFilter
---@return boolean
local function kept(thread, filter)
  if filter == "unresolved" then
    return not thread.resolved
  elseif filter == "resolved" then
    return thread.resolved
  end
  return true
end

--- The threads of `list` under `filter`, in list order.
---@param list NvimDiff.GitHub.Thread[]
---@param filter? NvimDiff.SideListFilter Default `"all"`.
---@return NvimDiff.SideListItem[]
function M.items(list, filter)
  filter = filter or "all"
  local out = {}
  for _, t in ipairs(list) do
    if kept(t, filter) then
      local place
      if t.subject == "file" then
        place = "file"
      elseif t.outdated or not t.line then
        place = "outdated"
      else
        place = "line"
      end
      out[#out + 1] = { thread = t, place = place }
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
---@param filter? NvimDiff.SideListFilter Shown in the title when not `"all"`.
---@return NvimDiff.SideListText
function M.render(items, width, filter)
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

  local title = ("%s · %d"):format(M.TITLE, #items)
  if filter and filter ~= "all" then
    title = ("%s · %s"):format(M.TITLE, filter) .. (" · %d"):format(#items)
  end
  add({ { title, "NvimDiffPanelTitle" } })
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
--- Every review thread; the list filters it by `filter`.
---@field threads NvimDiff.GitHub.Thread[]
--- Window to split beside (to its right). Default: the current window.
---@field win? integer
---@field width? integer Columns; default 50.
--- The buffer is hidden, not wiped, when another one takes its window for a moment (a PR
--- review gives back what is opened there, `scene/catch.lua`); it goes when its window
--- closes.
---@field hold? boolean
---@field filter? NvimDiff.SideListFilter Default `"all"`.
--- Called with the thread under `<CR>`.
---@field on_select? fun(thread: NvimDiff.GitHub.Thread)

---@class NvimDiff.SideList
---@field buf integer
---@field win integer
---@field source NvimDiff.GitHub.Thread[] Every thread, unfiltered.
---@field filter NvimDiff.SideListFilter
---@field items NvimDiff.SideListItem[] What the list shows: `source` under `filter`.
---@field threads? table<integer, NvimDiff.GitHub.Thread> Buffer line to the thread drawn there.
---@field on_select? fun(thread: NvimDiff.GitHub.Thread)
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
  local self = setmetatable(
    { buf = buf, win = win, source = {}, filter = spec.filter or "all", on_select = spec.on_select },
    SideList
  )
  if spec.hold then
    vim.bo[buf].bufhidden = "hide"
    api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      callback = function()
        -- After the event: a buffer cannot go while its window closes.
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
            pcall(api.nvim_buf_delete, buf, { force = true })
          end
        end)
      end,
    })
  end
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = buf, nowait = true, desc = "nvim-diff: General: Close list" })
  vim.keymap.set("n", "<CR>", function()
    self:select_cursor()
  end, { buffer = buf, nowait = true, desc = "nvim-diff: Threads: Go to thread" })
  local lhs = config.get().keymaps.threads.toggle_resolved
  if type(lhs) == "string" and lhs ~= "<CR>" then
    vim.keymap.set("n", lhs, function()
      self:cycle_filter()
    end, { buffer = buf, nowait = true, desc = "nvim-diff: Threads: Filter all / unresolved / resolved" })
  end
  help.attach(buf)
  self:set(spec.threads or {})
  return self
end

--- Redraw the list from the threads given.
function SideList:draw()
  if not api.nvim_buf_is_valid(self.buf) then
    return
  end
  local width = self:is_open() and api.nvim_win_get_width(self.win) - 1 or 50
  local items = M.items(self.source, self.filter)
  local text = M.render(items, math.max(20, width), self.filter)
  self.items = items
  self.threads = text.threads
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, text.lines)
  vim.bo[self.buf].modifiable = false
  api.nvim_buf_clear_namespace(self.buf, M.ns, 0, -1)
  for _, m in ipairs(text.marks) do
    api.nvim_buf_set_extmark(self.buf, M.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.group })
  end
end

--- Replace what the list shows. Keeps the filter, unless `filter` says otherwise.
---@param threads NvimDiff.GitHub.Thread[] Every review thread.
---@param filter? NvimDiff.SideListFilter
function SideList:set(threads, filter)
  self.source = threads
  if filter then
    self.filter = filter
  end
  self:draw()
end

--- Show only `filter`'s threads.
---@param filter NvimDiff.SideListFilter
function SideList:set_filter(filter)
  self.filter = filter
  self:draw()
  log.info("review comments: %s", filter == "all" and "all threads" or (filter .. " threads"))
end

--- Cycle the filter between all, unresolved and resolved threads.
---@return NvimDiff.SideListFilter filter The new filter.
function SideList:cycle_filter()
  local next_filter = M.FILTERS[1]
  for i, f in ipairs(M.FILTERS) do
    if f == self.filter then
      next_filter = M.FILTERS[i % #M.FILTERS + 1]
      break
    end
  end
  self:set_filter(next_filter)
  return next_filter
end

--- Jump to the thread under the cursor through `on_select`.
---@return boolean jumped False when there is no thread there, or nobody jumps.
function SideList:select_cursor()
  local thread = self:thread_at_cursor()
  if not thread then
    log.warn("no comment thread here")
    return false
  end
  if not self.on_select then
    return false
  end
  self.on_select(thread)
  return true
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
