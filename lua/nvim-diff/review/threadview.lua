--- Comment threads on one file's diff: each anchored thread drawn under its line as
--- virtual lines, expanded in place when unresolved and collapsed to one line when
--- resolved, until toggled. Never a float.
---
--- Built on the fileview's block API (`scene/fileview.lua` `set_block`), so everything the
--- block machinery guarantees holds here for free, in both layouts and across the toggle:
--- side-by-side pads the opposite pane with **blank** rows (never the `┈` filler, which
--- keeps its one meaning), unified hangs a thread under its own side's line, the row maps
--- count the inserted rows so scroll sync stays exact, and a thread inside a context fold
--- splits the fold, since a block must hang off a visible line.
---
--- Every thread on one display row goes into **one** block: old-side threads in its `old`,
--- new-side threads in its `new`. The pair pads the shorter side to the taller, so a
--- changed line with a thread on each side costs `max(left, right)` rows, not the sum — the
--- composition rule the rendering research measured.
---
--- Threads with no line to hang from (outdated, file-level, or a line past the end of the
--- file shown) are not drawn here; `unanchored()` lists them for the side list
--- (`review/sidelist.lua`).
---
--- Resolved threads are dimmed by default, or hidden (`threads.resolved = "hide"`), and a
--- key flips between the two. A thread resolved during the review (`state.kept`) stays
--- drawn, dimmed, while resolved ones are hidden, until the mode next changes, so a resolve
--- can be seen and undone. Which threads are expanded, and whether resolved ones show,
--- live in a state table the caller may share between the files of one review, so a
--- thread stays open when the reviewer steps to another file and back. Nothing is stored
--- beyond that table's life.
---
---     local tv = require("nvim-diff.review.threadview").attach(fileview, threads_of_this_file)
---     tv:toggle(thread.id)

local config = require("nvim-diff.config")
local log = require("nvim-diff.core.log")
local thread_mod = require("nvim-diff.review.thread")

local api = vim.api

local M = {}

--- Prefix of the block ids this module owns in a fileview.
local BLOCK = "nvim-diff.threads:"

---@class NvimDiff.ThreadState
--- Thread id to expanded, for threads toggled by hand. A thread not in it is expanded
--- when unresolved (see `ThreadView:is_expanded`).
---@field expanded table<string, boolean>
---@field resolved "dim"|"hide"
--- Threads resolved during this review: drawn dimmed even while resolved ones are hidden,
--- so a resolve can be seen and undone. Cleared when the resolved mode changes.
---@field kept? table<string, boolean>

---@class NvimDiff.ThreadViewOpts
--- Expanded threads and the resolved mode; share one table across a review's files.
--- Default: a fresh one, with `threads.resolved` from the config.
---@field state? NvimDiff.ThreadState
--- Called by the `keymaps.threads.list` key. The key is not mapped without it.
---@field on_list? fun()
--- `false`: map no keys (a caller that maps its own).
---@field keys? boolean

---@class NvimDiff.ThreadView
---@field file NvimDiff.FileView
---@field threads NvimDiff.GitHub.Thread[]
---@field state NvimDiff.ThreadState
---@field private opts NvimDiff.ThreadViewOpts
---@field private rows table<integer, NvimDiff.GitHub.Thread[]> Display row to its threads, in list order.
---@field private row_of_thread table<string, integer>
---@field private span table<string, integer[]> Thread id to the display rows `{ first, last }` of its lines.
---@field private active table<string, boolean> Threads on the cursor's line, drawn lit.
---@field private augroup integer
---@field private loose { thread: NvimDiff.GitHub.Thread, place: NvimDiff.ThreadPlace }[]
---@field private placed table<integer, boolean> Rows that currently hold a block.
---@field private width integer Display cells threads were last laid out for.
---@field private unwatch fun()
---@field private mapped { buf: integer, lhs: string }[]
---@field detached boolean
local ThreadView = {}
ThreadView.__index = ThreadView

--- A fresh state table: nothing toggled, resolved threads as the config says.
---@return NvimDiff.ThreadState
function M.new_state()
  return { expanded = {}, resolved = config.get().threads.resolved, kept = {} }
end

--- The threads of `list` on `path`.
---@param list NvimDiff.GitHub.Thread[]
---@param path string
---@return NvimDiff.GitHub.Thread[]
function M.for_path(list, path)
  local out = {}
  for _, t in ipairs(list) do
    if t.path == path then
      out[#out + 1] = t
    end
  end
  return out
end

--- Show `threads` (all on the file `file` shows) on `file`.
---@param file NvimDiff.FileView
---@param threads NvimDiff.GitHub.Thread[]
---@param opts? NvimDiff.ThreadViewOpts
---@return NvimDiff.ThreadView
function M.attach(file, threads, opts)
  opts = opts or {}
  local self = setmetatable({
    file = file,
    threads = {},
    state = opts.state or M.new_state(),
    opts = opts,
    rows = {},
    row_of_thread = {},
    span = {},
    active = {},
    loose = {},
    placed = {},
    width = 0,
    mapped = {},
    detached = false,
  }, ThreadView)
  M.seq = (M.seq or 0) + 1
  self.augroup = api.nvim_create_augroup("nvim-diff.threads." .. M.seq, { clear = true })
  self.unwatch = file:watch_scene(function()
    self:on_scene()
  end)
  self:map_keys()
  self:set_threads(threads)
  return self
end

--- Display cells a thread line may take: the narrowest window of the scene.
---@return integer
function ThreadView:measure()
  local width
  for _, win in ipairs(self.file:wins()) do
    if api.nvim_win_is_valid(win) then
      local w = api.nvim_win_get_width(win)
      width = width and math.min(width, w) or w
    end
  end
  return math.max(20, (width or 80) - 1)
end

--- Replace the threads and redraw them all.
---@param threads NvimDiff.GitHub.Thread[]
function ThreadView:set_threads(threads)
  self.threads = threads
  self.rows, self.row_of_thread, self.span, self.loose = {}, {}, {}, {}
  local diff = self.file:diff()
  for _, t in ipairs(threads) do
    local row, place = thread_mod.anchor(t, diff)
    if row then
      self.rows[row] = self.rows[row] or {}
      table.insert(self.rows[row], t)
      self.row_of_thread[t.id] = row
      local first = t.start_line and t.start_line >= 1 and t.start_line < t.line and t.start_line
      self.span[t.id] = { first and diff:row_of(t.side or "new", first) or row, row }
    else
      self.loose[#self.loose + 1] = { thread = t, place = place }
    end
  end
  self.active = self:lit()
  self:render()
end

--- The threads whose lines hold the cursor: on either side, since in side-by-side the old
--- pane's line faces the new pane's thread.
---@return table<string, boolean>
function ThreadView:lit()
  local out = {}
  local ok, row = pcall(self.cursor_row, self)
  if not ok or not row then
    return out
  end
  for id, span in pairs(self.span) do
    if row >= span[1] and row <= span[2] then
      out[id] = true
    end
  end
  return out
end

--- The cursor moved: relight the rows whose threads it came onto or left.
function ThreadView:on_cursor()
  if self.detached or self.file:is_closed() then
    return
  end
  local now = self:lit()
  local rows = {}
  for id in pairs(now) do
    if not self.active[id] then
      rows[self.row_of_thread[id]] = true
    end
  end
  for id in pairs(self.active) do
    if not now[id] and self.row_of_thread[id] then
      rows[self.row_of_thread[id]] = true
    end
  end
  self.active = now
  for row in pairs(rows) do
    self:render_row(row)
  end
end

--- Whether `t` is drawn at all.
---@param t NvimDiff.GitHub.Thread
---@return boolean
function ThreadView:visible(t)
  return not (t.resolved and self.state.resolved == "hide" and not (self.state.kept and self.state.kept[t.id]))
end

--- Whether `t` shows expanded: as last toggled, else when it is unresolved.
---@param t NvimDiff.GitHub.Thread
---@return boolean
function ThreadView:is_expanded(t)
  local e = self.state.expanded[t.id]
  if e == nil then
    return not t.resolved
  end
  return e
end

--- The block for display row `row`, or nil when none of its threads shows.
---@param row integer
---@return NvimDiff.Block?
function ThreadView:block(row)
  local block = { row = row }
  local any = false
  for _, t in ipairs(self.rows[row] or {}) do
    if self:visible(t) then
      local side = t.side or "new"
      local lines = block[side] or {}
      local o = { width = self.width, tail = true, active = self.active[t.id] }
      if self:is_expanded(t) then
        vim.list_extend(lines, thread_mod.expanded_lines(t, o))
      else
        lines[#lines + 1] = thread_mod.collapsed_line(t, o)
      end
      block[side] = lines
      any = true
    end
  end
  return any and block or nil
end

--- Redraw the threads of one display row.
---@param row integer
function ThreadView:render_row(row)
  if self.detached or self.file:is_closed() then
    return
  end
  local b = self:block(row)
  if b then
    self.file:set_block(BLOCK .. row, b)
    self.placed[row] = true
  elseif self.placed[row] then
    self.file:remove_block(BLOCK .. row)
    self.placed[row] = nil
  end
end

--- Redraw every thread, dropping blocks of rows that no longer hold one.
function ThreadView:render()
  if self.detached or self.file:is_closed() then
    return
  end
  self.width = self:measure()
  for row in pairs(self.placed) do
    if not self.rows[row] then
      self.file:remove_block(BLOCK .. row)
      self.placed[row] = nil
    end
  end
  local rows = vim.tbl_keys(self.rows)
  table.sort(rows)
  for _, row in ipairs(rows) do
    self:render_row(row)
  end
end

--- A new scene is up (layout or mode flip): its buffers need the keys, and a new width
--- the lines relaid. The fileview has already replayed the blocks.
function ThreadView:on_scene()
  if self.detached then
    return
  end
  self:map_keys()
  if self:measure() ~= self.width then
    self:render()
  end
end

--- Expanded or collapsed, as `expanded` says; `nil` flips it. False for a thread that is
--- not drawn on this diff (unanchored, or resolved while those are hidden).
---@param id string
---@param expanded? boolean
---@return boolean
function ThreadView:toggle(id, expanded)
  local row = self.row_of_thread[id]
  if not row then
    return false
  end
  local t
  for _, x in ipairs(self.rows[row]) do
    if x.id == id then
      t = x
    end
  end
  if not t or not self:visible(t) then
    return false
  end
  if expanded == nil then
    expanded = not self:is_expanded(t)
  end
  self.state.expanded[id] = expanded
  self:render_row(row)
  return true
end

---@param id string
---@return boolean
function ThreadView:expand(id)
  return self:toggle(id, true)
end

---@param id string
---@return boolean
function ThreadView:collapse(id)
  return self:toggle(id, false)
end

--- Expand (or collapse) every thread drawn on this diff.
---@param expanded? boolean Default true.
function ThreadView:expand_all(expanded)
  expanded = expanded ~= false
  for _, list in pairs(self.rows) do
    for _, t in ipairs(list) do
      self.state.expanded[t.id] = expanded
    end
  end
  self:render()
end

--- The display row under the cursor, nil on the header, the trailer or a closed fold.
---@return integer?
function ThreadView:cursor_row()
  local at = self.file:cursor()
  if not at.lnum then
    return nil
  end
  return self.file:diff():row_of(at.side, at.lnum)
end

--- The visible threads hanging under the cursor's line — on either side, since in
--- side-by-side the old pane's line faces the new pane's thread.
---@return NvimDiff.GitHub.Thread[]
function ThreadView:at_cursor()
  local row = self:cursor_row()
  local out = {}
  for _, t in ipairs(row and self.rows[row] or {}) do
    if self:visible(t) then
      out[#out + 1] = t
    end
  end
  return out
end

--- Expand the threads under the cursor's line, or collapse them when all are expanded.
---@return boolean toggled False when there is no thread there.
function ThreadView:toggle_at_cursor()
  local list = self:at_cursor()
  if #list == 0 then
    return false
  end
  local all = true
  for _, t in ipairs(list) do
    all = all and self:is_expanded(t)
  end
  for _, t in ipairs(list) do
    self.state.expanded[t.id] = not all
  end
  self:render_row(self:cursor_row() --[[@as integer]])
  return true
end

--- Move the cursor to the line of the next (`dir = 1`) or previous (`-1`) drawn thread,
--- wrapping around the file.
---@param dir 1|-1
---@return boolean moved False when no thread is drawn.
function ThreadView:jump(dir)
  local rows = {}
  for row, list in pairs(self.rows) do
    for _, t in ipairs(list) do
      if self:visible(t) then
        rows[#rows + 1] = row
        break
      end
    end
  end
  if #rows == 0 then
    return false
  end
  table.sort(rows)
  local here = self:cursor_row() or 0
  local target
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > here then
        target = r
        break
      end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      if rows[i] < here then
        target = rows[i]
        break
      end
    end
    target = target or rows[#rows]
  end
  -- Stay in the pane the cursor is in when it has a line on that row (side-by-side keeps
  -- the other pane facing it); otherwise go to the thread's own side.
  local here_side = self.file:cursor().side
  local old, new = self.file:diff():line_at(target)
  local lnum = here_side == "old" and old or new
  if lnum then
    self.file:jump(here_side, lnum)
    return true
  end
  for _, t in ipairs(self.rows[target]) do
    if self:visible(t) then
      local side = t.side or "new"
      if self.file.layout == "side_by_side" then
        api.nvim_set_current_win(self.file.scene.wins[side])
      end
      self.file:jump(side, t.line)
      return true
    end
  end
  return false
end

--- Show resolved threads dimmed, or hide them.
---@param mode "dim"|"hide"
function ThreadView:set_resolved(mode)
  self.state.resolved = mode
  self.state.kept = {}
  self:render()
end

--- Flip between dimming and hiding resolved threads.
---@return "dim"|"hide" mode The new mode.
function ThreadView:toggle_resolved()
  self:set_resolved(self.state.resolved == "hide" and "dim" or "hide")
  return self.state.resolved
end

--- Threads of this file that cannot hang under a line, and why.
---@return { thread: NvimDiff.GitHub.Thread, place: NvimDiff.ThreadPlace }[]
function ThreadView:unanchored()
  return self.loose
end

--- Map the thread keys in the scene's buffers, once per buffer, and watch their cursor.
function ThreadView:map_keys()
  for _, buf in ipairs(self.file:bufs()) do
    if #api.nvim_get_autocmds({ group = self.augroup, buffer = buf }) == 0 then
      api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
        group = self.augroup,
        buffer = buf,
        callback = function()
          self:on_cursor()
        end,
      })
    end
  end
  if self.opts.keys == false then
    return
  end
  local keys = config.get().keymaps.threads
  for _, buf in ipairs(self.file:bufs()) do
    local done = false
    for _, m in ipairs(self.mapped) do
      done = done or m.buf == buf
    end
    if not done then
      local function map(lhs, fn, desc)
        if type(lhs) == "string" then
          vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
          self.mapped[#self.mapped + 1] = { buf = buf, lhs = lhs }
        end
      end
      map(keys.toggle, function()
        if not self:toggle_at_cursor() then
          -- No thread here: the key does what it would have done.
          api.nvim_feedkeys(api.nvim_replace_termcodes(keys.toggle, true, false, true), "n", false)
        end
      end, "Threads: Expand / collapse")
      map(keys.next, function()
        self:jump(1)
      end, "Threads: Next thread")
      map(keys.prev, function()
        self:jump(-1)
      end, "Threads: Previous thread")
      map(keys.toggle_resolved, function()
        local mode = self:toggle_resolved()
        log.info("resolved threads: %s", mode == "hide" and "hidden" or "shown, dimmed")
      end, "Threads: Show / hide resolved")
      if self.opts.on_list then
        map(keys.list, self.opts.on_list, "Threads: List outdated & file comments")
      end
    end
  end
end

--- Remove every thread from the diff and unmap the keys. Idempotent.
function ThreadView:detach()
  if self.detached then
    return
  end
  if not self.file:is_closed() then
    for row in pairs(self.placed) do
      self.file:remove_block(BLOCK .. row)
    end
  end
  self.placed = {}
  self.detached = true
  self.unwatch()
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, m in ipairs(self.mapped) do
    if api.nvim_buf_is_valid(m.buf) then
      pcall(vim.keymap.del, "n", m.lhs, { buffer = m.buf })
    end
  end
  self.mapped = {}
end

return M
