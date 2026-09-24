--- A diff view: a tabpage holding the file panel on the left and, beside it, the diff of the
--- file selected in it.
---
--- This is the Lua API the working-tree and branch commands will be built on; it adds no
--- command itself.
---
---     local view = require("nvim-diff.views.diff").open({
---       repo = repo, left = rev.commit(base), right = rev.worktree(),
---     })
---     view:next_file()
---
--- The area right of the panel shows one of two things: the file's diff, as a
--- `scene/fileview.lua` (side-by-side or unified, flipped with its toggle key, with context
--- folding), or a single note window — for no selection, a binary file, a file over the
--- size threshold, or an error. Changing files closes whatever is there and opens fresh
--- windows beside the panel; the fileview owns and closes its own windows.
---
--- A file opens in `config.layout` until it is flipped; after that, reselecting it in the
--- same view opens it in the layout it was left in. The diff mode (structural or line) is
--- remembered the same way.
---
--- Size threshold: a file whose larger side has more lines than `thresholds.defer_lines`
--- is listed with its stats and a deferred marker, and selecting it shows a note instead of
--- fetching and diffing it. Selecting it again while that note shows loads it. Above
--- `thresholds.panel_entries` files the panel summarises: every directory starts collapsed.

local blob = require("nvim-diff.git.blob")
local config = require("nvim-diff.config")
local entry_mod = require("nvim-diff.scene.entry")
local event = require("nvim-diff.core.event")
local files = require("nvim-diff.git.files")
local fileview = require("nvim-diff.scene.fileview")
local line_diff = require("nvim-diff.diff.line")
local panel_mod = require("nvim-diff.ui.panel")
local path = require("nvim-diff.core.path")
local rev_mod = require("nvim-diff.git.rev")
local tree = require("nvim-diff.ui.tree")

local api = vim.api

local M = {}

---@class NvimDiff.DiffViewOpts
---@field repo NvimDiff.Git.Repo
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev
--- The files to list. Omitted: `git/files.diff(repo, left, right)`; `refresh()` re-runs it.
---@field changes? NvimDiff.Git.FileChange[]
---@field title? string Panel title. Defaults to `<left> → <right>`.
---@field listing? NvimDiff.Listing Defaults to `panel.listing`.

---@class NvimDiff.DiffView
---@field repo NvimDiff.Git.Repo
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev
---@field title string
---@field list NvimDiff.FileList
---@field listing NvimDiff.Listing
---@field collapsed table<string, boolean> Directory path to the user's own fold choice.
---@field summary boolean Over `thresholds.panel_entries`: directories start collapsed.
---@field tree NvimDiff.Tree
---@field panel NvimDiff.Panel
---@field tab integer
---@field current? NvimDiff.FileEntry
---@field file? NvimDiff.FileView The diff showing, if one is.
---@field layouts table<NvimDiff.FileEntry, NvimDiff.Layout> Layout each opened file was left in.
---@field modes table<NvimDiff.FileEntry, NvimDiff.DiffMode> Diff mode each opened file was left in.
---@field note_buf integer
---@field note_win? integer
---@field closed boolean
local View = {}
View.__index = View

--- Stamp that also sees worktree edits: `git diff` does not hash worktree files, so a
--- same-size edit would otherwise look unchanged to the morph.
---@param repo NvimDiff.Git.Repo
---@param right NvimDiff.Git.Rev
---@return fun(change: NvimDiff.Git.FileChange): string
local function stamper(repo, right)
  if right.type ~= "worktree" then
    return entry_mod.stamp
  end
  return function(change)
    local stat = vim.uv.fs_stat(path.from_git(repo.toplevel, change.path))
    local s = stat and ("%d:%d.%d"):format(stat.size, stat.mtime.sec, stat.mtime.nsec) or "-"
    return entry_mod.stamp(change) .. "\0" .. s
  end
end

---@param buf integer
---@param lines string[]
local function set_note(buf, lines)
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("modified", false, { buf = buf })
end

---@param win integer
local function setup_note_win(win)
  for name, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false }) do
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  api.nvim_set_option_value("winfixbuf", true, { win = win, scope = "local" })
end

--- Open a view in a new tabpage. Raises when the file list cannot be read.
---@param opts NvimDiff.DiffViewOpts
---@return NvimDiff.DiffView
function M.open(opts)
  local cfg = config.get()
  local changes = opts.changes
  if not changes then
    local err
    changes, err = files.diff(opts.repo, opts.left, opts.right)
    if not changes then
      error("nvim-diff: " .. (err and err.message or "cannot list files"), 0)
    end
  end

  local self = setmetatable({
    repo = opts.repo,
    left = opts.left,
    right = opts.right,
    title = opts.title or (rev_mod.display(opts.left) .. " → " .. rev_mod.display(opts.right)),
    listing = opts.listing or cfg.panel.listing,
    collapsed = {},
    layouts = setmetatable({}, { __mode = "k" }),
    modes = setmetatable({}, { __mode = "k" }),
    closed = false,
  }, View)
  self.list = entry_mod.list(changes, stamper(self.repo, self.right))
  entry_mod.measure(self.repo, self, self.list.entries, cfg.thresholds.defer_lines)
  self.summary = #self.list.entries > cfg.thresholds.panel_entries

  vim.cmd("tabnew")
  self.tab = api.nvim_get_current_tabpage()
  local area = api.nvim_get_current_win()
  local placeholder = api.nvim_get_current_buf()

  self.note_buf = api.nvim_create_buf(false, true)
  for name, value in pairs({ buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = false }) do
    api.nvim_set_option_value(name, value, { buf = self.note_buf })
  end
  api.nvim_win_set_buf(area, self.note_buf)
  if api.nvim_buf_is_valid(placeholder) and placeholder ~= self.note_buf then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end
  self.note_win = area
  setup_note_win(area)
  set_note(self.note_buf, { "", "  Select a file in the panel." })

  self.panel = panel_mod.new({ width = cfg.panel.width })
  self.panel:open(area)
  self:map_panel()
  self:map_view(self.note_buf)
  self:render()
  api.nvim_set_current_win(self.panel.win)

  event.emit_in({ win = self.panel.win, buf = self.panel.buf }, event.events.VIEW_OPENED, self)
  return self
end

--- Map the view-wide keys (next/previous file) in `buf`.
---@param buf integer
function View:map_view(buf)
  local keys = config.get().keymaps.view
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.next_file, function()
    self:next_file()
  end, "next file")
  map(keys.prev_file, function()
    self:prev_file()
  end, "previous file")
end

function View:map_panel()
  local keys = config.get().keymaps.panel
  local buf = self.panel.buf
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.select, function()
    self:select_cursor()
  end, "open the file or fold the directory under the cursor")
  map(keys.toggle_listing, function()
    self:toggle_listing()
  end, "switch between tree and flat listing")
  map(keys.refresh, function()
    self:refresh()
  end, "refresh the file list")
  self:map_view(buf)
end

--- Rebuild the rows and redraw the panel.
function View:render()
  self.tree = tree.build(self.list.entries, {
    listing = self.listing,
    collapsed = self.collapsed,
    collapse_default = self.summary,
  })
  local notice
  if self.summary then
    notice = ("Over %s files: directories start folded."):format(
      panel_mod.thousands(config.get().thresholds.panel_entries)
    )
  end
  self.panel:render({
    title = self.title,
    tree = self.tree,
    listing = self.listing,
    entries = self.list.entries,
    current = self.current,
    notice = notice,
  })
end

--- Whether the view still has its tabpage and panel.
---@return boolean
function View:is_valid()
  return not self.closed and api.nvim_tabpage_is_valid(self.tab) and self.panel:is_open()
end

--- Close whatever shows in the area right of the panel.
function View:clear_area()
  if self.file and not self.file:is_closed() then
    self.file:close()
  end
  self.file = nil
  if self.note_win and api.nvim_win_is_valid(self.note_win) then
    api.nvim_set_option_value("winfixbuf", false, { win = self.note_win, scope = "local" })
    pcall(api.nvim_win_close, self.note_win, true)
  end
  self.note_win = nil
end

--- `n` fresh windows right of the panel, left to right, holding the note buffer.
---@param n integer
---@return integer[]
function View:area_windows(n)
  -- The area is empty, so the panel holds the whole tab. The first split takes half of
  -- it; putting the panel back at its width gives the first window everything else, and
  -- each later split halves the window before it.
  local wins = {}
  local anchor = self.panel.win
  for i = 1, n do
    wins[i] = api.nvim_open_win(self.note_buf, false, { split = "right", win = anchor })
    anchor = wins[i]
    if i == 1 then
      self.panel:fix_width()
    end
  end
  return wins
end

--- Show a note in the area instead of a diff.
---@param lines string[]
function View:show_note(lines)
  self:clear_area()
  set_note(self.note_buf, lines)
  self.note_win = self:area_windows(1)[1]
  setup_note_win(self.note_win)
end

--- Treesitter language for a git path, when a parser for it is installed.
---@param git_path string
---@return string?
local function lang_for(git_path)
  local ft = vim.filetype.match({ filename = git_path })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if lang and pcall(vim.treesitter.get_string_parser, "", lang) then
    return lang
  end
  return nil
end

--- Buffer name for one side, unless a buffer already has it (another view showing it).
---@param at NvimDiff.Git.Rev
---@param git_path string
---@return string?
function View:buf_name(at, git_path)
  local name = ("nvim-diff://%s/%s/%s"):format(self.repo.gitdir, rev_mod.id(at), git_path)
  return vim.fn.bufexists(name) == 0 and name or nil
end

--- Read one side of `entry` as lines.
---@param entry NvimDiff.FileEntry
---@param side "old"|"new"
---@return string[]? lines
---@return string? problem Why it cannot be shown.
function View:read_side(entry, side)
  local c = entry.change
  if side == "old" and (c.status == "A" or c.status == "?") then
    return {}
  elseif side == "new" and c.status == "D" then
    return {}
  end
  local at = side == "old" and self.left or self.right
  local git_path = side == "old" and (entry.oldpath or entry.path) or entry.path
  local b, err = blob.read(self.repo, at, git_path)
  if not b then
    return nil, err and err.message or ("cannot read " .. git_path)
  end
  if b.binary then
    return nil, "binary"
  end
  return (blob.lines(b.bytes))
end

--- Show `entry` in the area. A deferred entry shows a note unless `force` (or it was
--- forced before); asking for the entry whose deferred note is already showing counts as
--- asking to load it.
---@param entry? NvimDiff.FileEntry Nil clears the selection.
---@param opts? { force?: boolean }
function View:select(entry, opts)
  opts = opts or {}
  if not self:is_valid() then
    return
  end
  local from = api.nvim_get_current_win()
  local from_side = self:diff_side(from)
  local from_area = from_side ~= nil or from == self.note_win

  self.current = entry
  if entry and opts.force and not entry.forced then
    entry.forced = true
    -- Its deferred marker goes.
    self:render()
  end
  self:reveal(entry)
  if not entry then
    self:show_note({ "", "  Select a file in the panel." })
  elseif entry.change.binary then
    self:show_note({ "", "  " .. entry.path, "", "  Binary file; not shown." })
  elseif entry.deferred and not entry.forced then
    local key = config.get().keymaps.panel.select
    self:show_note({
      "",
      "  " .. entry.path,
      "",
      ("  %s lines, over the %s-line limit (thresholds.defer_lines)."):format(
        panel_mod.thousands(entry.lines or 0),
        panel_mod.thousands(config.get().thresholds.defer_lines)
      ),
      type(key) == "string" and ("  Press %s on it in the panel again to load it."):format(key)
        or "  Select it again to load it.",
    })
  else
    self:show_diff(entry)
  end

  -- Keep the cursor in the same kind of window it was in.
  if from_area then
    if self.file then
      api.nvim_set_current_win(self:diff_win(from_side or "new"))
    elseif self.note_win then
      api.nvim_set_current_win(self.note_win)
    end
  elseif api.nvim_win_is_valid(from) then
    api.nvim_set_current_win(from)
  end
end

--- Load a deferred entry: `select` with `force`.
---@param entry NvimDiff.FileEntry
function View:load(entry)
  self:select(entry, { force = true })
end

--- Which side of the showing diff `win` is: `"old"`/`"new"` for a side-by-side pane, the
--- cursor's side for the unified pane, nil for any other window.
---@param win integer
---@return NvimDiff.Side?
function View:diff_side(win)
  local file = self.file
  if not file or file:is_closed() then
    return nil
  end
  if file.layout == "unified" then
    if win ~= file.scene.win then
      return nil
    end
    local side = file.scene:cursor_pos()
    return side or "new"
  end
  return file.scene:side_of(win)
end

--- The showing diff's window for `side`; unified has only one.
---@param side NvimDiff.Side
---@return integer
function View:diff_win(side)
  local file = assert(self.file)
  if file.layout == "unified" then
    return file.scene.win
  end
  return file.scene.wins[side]
end

---@param entry NvimDiff.FileEntry
function View:show_diff(entry)
  local old, problem = self:read_side(entry, "old")
  local new
  if old then
    new, problem = self:read_side(entry, "new")
  end
  if not old or not new then
    local text = problem == "binary" and "Binary file; not shown." or ("Cannot show this file: " .. problem)
    self:show_note({ "", "  " .. entry.path, "", "  " .. text })
    return
  end

  local d = line_diff.diff(old, new, { algorithm = config.get().diff.algorithm })
  self:clear_area()
  local layout = self.layouts[entry] or config.get().layout
  local wins = self:area_windows(layout == "unified" and 1 or 2)
  local old_path = entry.oldpath or entry.path
  self.file = fileview.open({
    diff = d,
    layout = layout,
    mode = self.modes[entry],
    old = {
      lines = old,
      label = "a/" .. old_path,
      name = self:buf_name(self.left, old_path),
      lang = lang_for(old_path),
    },
    new = {
      lines = new,
      label = "b/" .. entry.path,
      name = self:buf_name(self.right, entry.path),
      lang = lang_for(entry.path),
    },
    wins = layout == "unified" and { win = wins[1] } or { old = wins[1], new = wins[2] },
    on_scene = function(file)
      self:on_scene(entry, file)
    end,
  })
end

--- A diff's scene is up — first open or after a flip: map the view keys in its new buffers,
--- keep the panel at its width (a flip closes or splits a window beside it) and remember
--- the layout and diff mode for the file.
---@param entry NvimDiff.FileEntry
---@param file NvimDiff.FileView
function View:on_scene(entry, file)
  self.panel:fix_width()
  for _, buf in ipairs(file:bufs()) do
    self:map_view(buf)
  end
  self.layouts[entry] = file.layout
  self.modes[entry] = file.mode
end

--- Unfold every directory holding `entry`, and mark it current in the panel.
---@param entry? NvimDiff.FileEntry
function View:reveal(entry)
  local changed = false
  if entry and self.tree.dirs[entry] then
    for _, dir in ipairs(self.tree.dirs[entry]) do
      local folded = self.collapsed[dir]
      if folded == nil then
        folded = self.summary
      end
      if folded then
        self.collapsed[dir] = false
        changed = true
      end
    end
  end
  if changed then
    self:render()
  else
    self.panel:set_current(entry)
  end
  local lnum = entry and self.panel:line_of(entry)
  if lnum then
    self.panel:set_cursor(lnum)
  end
end

--- Open the file, or fold/unfold the directory, under the panel's cursor.
function View:select_cursor()
  local row = self.panel:cursor_row()
  if not row then
    return
  end
  if row.kind == "dir" then
    self:toggle_dir(row.path)
  else
    -- Selecting a deferred file whose note is already showing is the request to load it.
    local again = row.entry == self.current and row.entry.deferred and self.note_win ~= nil
    self:select(row.entry, { force = again })
  end
end

--- Fold or unfold a directory row.
---@param dir_path string
function View:toggle_dir(dir_path)
  local folded = self.collapsed[dir_path]
  if folded == nil then
    folded = self.summary
  end
  self.collapsed[dir_path] = not folded
  self:render()
  local lnum = self.panel:line_of_dir(dir_path)
  if lnum then
    self.panel:set_cursor(lnum)
  end
end

--- Step through the files in panel order, wrapping at the ends.
---@param delta integer
function View:step(delta)
  local order = self.tree.order
  if #order == 0 then
    return
  end
  local index = 0
  for i, e in ipairs(order) do
    if e == self.current then
      index = i
      break
    end
  end
  if index == 0 then
    index = delta > 0 and 0 or 1
  end
  self:select(order[(index - 1 + delta) % #order + 1])
end

function View:next_file()
  self:step(1)
end

function View:prev_file()
  self:step(-1)
end

--- Switch between tree and flat listing.
---@param listing? NvimDiff.Listing Omitted: the other one.
function View:toggle_listing(listing)
  self.listing = listing or (self.listing == "tree" and "flat" or "tree")
  self:render()
  local lnum = self.current and self.panel:line_of(self.current)
  if lnum then
    self.panel:set_cursor(lnum)
  end
end

--- Set an entry's viewed state and redraw. The review step drives this from GitHub.
---@param entry NvimDiff.FileEntry
---@param state? NvimDiff.Viewed
function View:set_viewed(entry, state)
  entry.viewed = state
  self:render()
end

--- Re-list the files and morph the panel to match. An unchanged entry keeps its object,
--- its state and, when it is showing, its open diff; a changed current entry is reloaded;
--- a removed current entry hands the selection to whatever took its place in the list.
---@param changes? NvimDiff.Git.FileChange[] Omitted: `git/files.diff` again.
---@return NvimDiff.EditOp[]? ops Nil when the list could not be read.
function View:refresh(changes)
  if not self:is_valid() then
    return nil
  end
  if not changes then
    local err
    changes, err = files.diff(self.repo, self.left, self.right)
    if not changes then
      require("nvim-diff.core.log").error("refresh failed: %s", err and err.message or "?")
      return nil
    end
  end
  local cfg = config.get()
  local current_index = self.current and self.list:index_of(self.current)
  local ops = self.list:morph(changes)

  local measure = {}
  local current_op
  for _, op in ipairs(ops) do
    if op.op == "insert" or op.op == "update" then
      measure[#measure + 1] = op.entry
    end
    if op.entry == self.current then
      current_op = op.op
    end
  end
  entry_mod.measure(self.repo, self, measure, cfg.thresholds.defer_lines)

  local was_summary = self.summary
  self.summary = #self.list.entries > cfg.thresholds.panel_entries
  if was_summary ~= self.summary then
    self.collapsed = {}
  end
  self:render()

  if current_op == "update" then
    self:select(self.current)
  elseif current_op == "delete" then
    local entries = self.list.entries
    self:select(entries[math.min(current_index or 1, #entries)])
  end
  return ops
end

--- Close the view: its diff, its panel and its tabpage. Idempotent.
function View:close()
  if self.closed then
    return
  end
  if self.panel:is_open() then
    event.emit_in({ win = self.panel.win, buf = self.panel.buf }, event.events.VIEW_CLOSED, self)
  end
  self.closed = true
  self:clear_area()
  if api.nvim_tabpage_is_valid(self.tab) and #api.nvim_list_tabpages() > 1 then
    local tabnr = api.nvim_tabpage_get_number(self.tab)
    self.panel:close()
    pcall(vim.cmd, "tabclose " .. tabnr)
  else
    -- The last tabpage: leave an empty window behind.
    if self.panel:is_open() then
      api.nvim_open_win(api.nvim_create_buf(true, false), true, { split = "right", win = self.panel.win })
    end
    self.panel:close()
  end
  if api.nvim_buf_is_valid(self.note_buf) then
    pcall(api.nvim_buf_delete, self.note_buf, { force = true })
  end
end

return M
