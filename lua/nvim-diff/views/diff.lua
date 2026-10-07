--- A diff view: a tabpage holding the file panel on the left and, beside it, the diff of the
--- file selected in it.
---
--- The Lua API under `:NvimDiffOpen` (`commands/diff.lua`), which resolves what the user
--- typed and hands this module two revisions and, for a branch diff, the range they came from.
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
---
--- A file that exists on one side only (added, deleted, untracked) opens unified, since
--- side-by-side would be one pane of text beside one pane of filler; the toggle still flips it.
---
--- Selecting a conflicted (`U`) entry opens `views/conflict.lua`'s three-way layout in its
--- own tabpage instead, leaving a note in the area; the other `U` entries in this view's
--- list become that view's `next_file`/`prev_file` order.
---
--- A view given a `range` can flip it between merge-base (`a...b`) and tip-to-tip (`a..b`)
--- with `keymaps.view.toggle_range`. A view whose right side is the worktree or the index
--- re-lists its files when its tabpage is entered and when Neovim regains focus.
---
--- A PR review hands the view its comment threads with `set_threads`: each file's diff then
--- shows its threads (`review/threadview.lua`), and `keymaps.threads.list` opens the side
--- list of every thread (`review/sidelist.lua`).
---
--- A PR review's jumps to another file (`route_jump`) — an LSP jump from the head pane
--- showing the real file, a quickfix or location list entry, `:edit` or a picker's pick in
--- any pane, the file panel, the note or the thread list — never replace that window's
--- buffer and never split the review's tabpage: a file the diff lists is selected and shown
--- at the jump's line; any other opens in the review's files tabpage (one per review,
--- reused, so `<C-o>` there goes back), read-only when it is in the review's worktree (the
--- PR's code).

local blob = require("nvim-diff.git.blob")
local buffer = require("nvim-diff.scene.buffer")
local catch = require("nvim-diff.scene.catch")
local config = require("nvim-diff.config")
local conflict_view = require("nvim-diff.views.conflict")
local entry_mod = require("nvim-diff.scene.entry")
local event = require("nvim-diff.core.event")
local filebuf = require("nvim-diff.scene.filebuf")
local files = require("nvim-diff.git.files")
local fileview = require("nvim-diff.scene.fileview")
local help = require("nvim-diff.ui.help")
local line_diff = require("nvim-diff.diff.line")
local log = require("nvim-diff.core.log")
local panel_mod = require("nvim-diff.ui.panel")
local path = require("nvim-diff.core.path")
local rev_mod = require("nvim-diff.git.rev")
local revparse = require("nvim-diff.git.revparse")
local tree = require("nvim-diff.ui.tree")

local api = vim.api

local M = {}

--- Open views by tabpage, for `M.get`.
---@type table<integer, NvimDiff.DiffView>
local by_tab = {}

---@class NvimDiff.DiffViewOpts
---@field repo NvimDiff.Git.Repo
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev
--- The files to list. Omitted: `git/files.diff(repo, left, right)`; `refresh()` re-runs it.
---@field changes? NvimDiff.Git.FileChange[]
---@field title? string Panel title. Defaults to `<left> → <right>`.
---@field listing? NvimDiff.Listing Defaults to `panel.listing`.
--- The range `left`/`right` were resolved from. A `merge_base` or `tip` range makes
--- `toggle_range` work and titles the panel `a...b` / `a..b`.
---@field range? NvimDiff.Git.Range
---@field resolve_opts? NvimDiff.Git.ResolveOpts Passed back to `revparse.toggle`.
---@field paths? string[] Limit the listing to these git paths.
--- A PR review's view: side-by-side panes show their headers as winbars, the head side
--- has no trailer line, and both panes have a sign column — the layout the head pane needs
--- to show the real file in the review worktree.
---@field review? boolean
--- With `review`: the side-by-side head pane shows the file in `repo`'s worktree, which has
--- `right` checked out, in its own buffer with filetype and LSP (`scene/filebuf.lua`) — not
--- a scratch copy. A file whose buffer does not hold exactly the diffed lines falls back to
--- the copy. `view.real_file` may change later; it counts from the next file shown, or
--- from `reshow()` for the one showing.
---@field real_file? boolean

---@class NvimDiff.DiffView
---@field repo NvimDiff.Git.Repo
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev
---@field title string
---@field range? NvimDiff.Git.Range
---@field resolve_opts? NvimDiff.Git.ResolveOpts
---@field paths? string[]
---@field review? boolean
---@field real_file? boolean
--- Auto-refresh autocmds, for a worktree or index right side; a review's jump routing.
---@field augroup? integer
--- Called with each files tabpage a jump opens for a file the diff does not list
--- (`route_jump`), which starts in the view's tab-local directory. A new one opens only
--- when the last is gone.
---@field on_tab? fun(tab: integer)
--- The tabpage jumps to files the diff does not list show in (`open_tab`), once one did.
---@field files_tab? integer
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
---@field threads? NvimDiff.GitHub.Thread[] Review threads, from `set_threads`.
--- Threads on code newer than the review shows: not drawn, counted in the panel.
---@field held_threads? NvimDiff.GitHub.Thread[]
---@field thread_state? NvimDiff.ThreadState Expanded threads and the resolved mode, across files.
---@field thread_view? NvimDiff.ThreadView The threads on the diff showing.
---@field thread_list? NvimDiff.SideList
--- Called with each side list as it opens (a review maps its comment keys there).
---@field on_thread_list? fun(list: NvimDiff.SideList)
---@field status? NvimDiff.PanelStatus[] Panel header lines a PR review's sync sets.
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

--- The panel title for a range: what the user would type, so a merge-base diff reads
--- `main...feature` rather than `merge-base(main, feature) → feature`.
---@param range? NvimDiff.Git.Range
---@param left NvimDiff.Git.Rev
---@param right NvimDiff.Git.Rev
---@return string
local function title_of(range, left, right)
  local spec = range and range.spec
  if spec and spec.mode ~= "single" then
    local text = spec.left .. (spec.mode == "merge_base" and "..." or "..") .. spec.right
    return right.type == "worktree" and (text .. " (worktree)") or text
  end
  return rev_mod.display(left) .. " → " .. rev_mod.display(right)
end

--- The view open in `tab`, if any.
---@param tab? integer Defaults to the current tabpage.
---@return NvimDiff.DiffView?
function M.get(tab)
  local view = by_tab[tab or api.nvim_get_current_tabpage()]
  if view and view:is_valid() then
    return view
  end
  return nil
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
    changes, err = files.diff(opts.repo, opts.left, opts.right, { paths = opts.paths })
    if not changes then
      error("nvim-diff: " .. (err and err.message or "cannot list files"), 0)
    end
  end

  local self = setmetatable({
    repo = opts.repo,
    left = opts.left,
    right = opts.right,
    title = opts.title or title_of(opts.range, opts.left, opts.right),
    range = opts.range,
    resolve_opts = opts.resolve_opts,
    paths = opts.paths,
    review = opts.review,
    real_file = opts.real_file,
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
  if self.review then
    self:route_from(self.panel.win, self.panel.buf)
    self:route_from(area, self.note_buf)
  end
  self:map_panel()
  self:map_view(self.note_buf)
  self:render()
  api.nvim_set_current_win(self.panel.win)
  by_tab[self.tab] = self
  self:watch()
  if self.review then
    self:catch_splits()
  end

  event.emit_in({ win = self.panel.win, buf = self.panel.buf }, event.events.VIEW_OPENED, self)
  return self
end

--- Map the view-wide keys (next/previous file, focus panel) in `buf`.
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
  end, "Files: Next file")
  map(keys.prev_file, function()
    self:prev_file()
  end, "Files: Previous file")
  map(keys.toggle_range, function()
    self:toggle_range()
  end, "Diff: Toggle a...b / a..b")
  map(keys.line_history, function()
    self:line_history()
  end, "Diff: Line history")
  map(keys.focus_panel, function()
    self:focus_panel()
  end, "Files: Focus file panel")
  help.attach(buf)
end

--- Open the history of the line under the cursor (`git log -L`), from whichever side of
--- the diff the cursor is on. Needs a committed revision on that side — the worktree and
--- the index have no `-L` history of their own.
---@return NvimDiff.HistoryView?
function View:line_history()
  if not self.file or self.file:is_closed() then
    log.warn("no diff showing")
    return nil
  end
  local entry = self.current
  if not entry then
    return nil
  end
  local at = self.file:cursor()
  if not at.lnum then
    log.warn("place the cursor on a file line to see its history")
    return nil
  end
  local left, right = self:sides(entry)
  local rev, git_path
  if at.side == "old" then
    rev, git_path = left, entry.oldpath or entry.path
  else
    rev, git_path = right, entry.path
  end
  if rev.type ~= "commit" then
    log.warn("line history needs a committed revision, not the %s", rev.type)
    return nil
  end
  return require("nvim-diff.views.history").open_line({
    repo = self.repo,
    path = git_path,
    line = at.lnum,
    rev = rev.oid,
  })
end

--- Re-list the files when the view's tabpage is entered or Neovim regains focus, for a
--- right side that changes under the view (the worktree or the index). A commit is
--- resolved once and never moves, so a view of two commits is not watched.
function View:watch()
  if self.right.type == "commit" then
    return
  end
  self.augroup = api.nvim_create_augroup(("nvim-diff.view.%d"):format(self.tab), { clear = true })
  api.nvim_create_autocmd({ "TabEnter", "FocusGained" }, {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() ~= self.tab then
        return
      end
      -- After the event: a refresh may close and split windows, which is not safe to do
      -- inside `TabEnter`.
      vim.schedule(function()
        if self:is_valid() and api.nvim_get_current_tabpage() == self.tab then
          self:refresh()
        end
      end)
    end,
  })
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
  end, "Files: Open file / toggle directory")
  map(keys.toggle_listing, function()
    self:toggle_listing()
  end, "Files: Toggle tree / flat list")
  map(keys.refresh, function()
    self:refresh()
  end, "Files: Refresh list")
  self:map_view(buf)
end

--- Unresolved review-thread count by file path, from the drawn threads and the ones held
--- back on newer code. Empty when there is nothing unresolved.
---@return table<string, integer>
function View:unresolved_counts()
  local counts = {}
  local function add(list)
    for _, t in ipairs(list or {}) do
      if not t.resolved and type(t.path) == "string" then
        counts[t.path] = (counts[t.path] or 0) + 1
      end
    end
  end
  add(self.threads)
  add(self.held_threads)
  return counts
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
    status = self.status,
    unresolved = self:unresolved_counts(),
  })
end

--- Set the status lines under the panel's counts (`{}` clears them) and redraw. A cursor on
--- a file row stays on that row as the header grows or shrinks.
---@param status NvimDiff.PanelStatus[]
function View:set_status(status)
  local shift = #status - #(self.status or {})
  self.status = status
  if not self:is_valid() then
    return
  end
  local win = self.panel.win
  local row = api.nvim_win_get_cursor(win)[1]
  local on_row = row >= self.panel.first_row
  self:render()
  if shift ~= 0 and on_row then
    local last = api.nvim_buf_line_count(self.panel.buf)
    pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(row + shift, last)), 0 })
  end
end

--- Whether the view still has its tabpage and panel.
---@return boolean
function View:is_valid()
  return not self.closed and api.nvim_tabpage_is_valid(self.tab) and self.panel:is_open()
end

--- Close whatever shows in the area right of the panel, and the threads drawn on it.
function View:clear_area()
  if self.thread_view then
    self.thread_view:detach()
    self.thread_view = nil
  end
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
  if self.review then
    self:route_from(self.note_win, self.note_buf)
  end
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

--- Buffer name for one side. `scene/buffer.lua` falls back to an unnamed buffer when a
--- window already shows one by this name, and takes back a kept one otherwise.
---@param at NvimDiff.Git.Rev
---@param git_path string
---@return string
function View:buf_name(at, git_path)
  return ("nvim-diff://%s/%s/%s"):format(self.repo.gitdir, rev_mod.id(at), git_path)
end

--- The two revisions `entry` is diffed between. The view's own pair here; a history view
--- gives each commit's entries that commit and its parent.
---@param _entry NvimDiff.FileEntry
---@return NvimDiff.Git.Rev left
---@return NvimDiff.Git.Rev right
function View:sides(_entry)
  return self.left, self.right
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
  local left, right = self:sides(entry)
  local at = side == "old" and left or right
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

---@class NvimDiff.SelectOpts
---@field force? boolean Load a deferred entry.
--- Context folds to open the diff with, from an earlier view of the same diff (`reshow`);
--- used only when the diff still has `rows` display rows.
---@field folds? { list: NvimDiff.Fold[], rows: integer }

--- Show `entry` in the area. A deferred entry shows a note unless `force` (or it was
--- forced before); asking for the entry whose deferred note is already showing counts as
--- asking to load it. A conflicted (`U`) entry opens the merge conflict view in its own
--- tabpage instead, and the cursor is left there.
---@param entry? NvimDiff.FileEntry Nil clears the selection.
---@param opts? NvimDiff.SelectOpts
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
  elseif entry.change.status == "U" then
    self:show_note({ "", "  " .. entry.path, "", "  Resolving this conflict in a separate tab." })
    self:open_conflict(entry)
    return
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
    self:show_diff(entry, opts.folds)
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

--- Show the file showing again, built anew — after `real_file` changed — in the same
--- layout and diff mode, with the same context folds, and the cursor on the same line of
--- the same side at the same screen row. A no-op when no diff is showing.
function View:reshow()
  local entry, file = self.current, self.file
  if not self:is_valid() or not entry or not file or file:is_closed() then
    return
  end
  local at = file:cursor()
  local scene = file.scene
  self:select(entry, { folds = { list = scene.folds, rows = scene.diff.rows } })
  if self.file and self.file ~= file and not self.file:is_closed() then
    self.file:place(at)
  end
end

--- The head pane's file changed on disk while it showed (`scene/filebuf.lua`): show it
--- again, which makes the head pane a copy of the diffed version, without LSP, until the
--- file on disk is the PR's again.
---@param entry NvimDiff.FileEntry
function View:head_changed(entry)
  if self.current ~= entry then
    return
  end
  self:reshow()
  local file = self.file
  if file and not file:is_closed() and file.layout == "side_by_side" and not file.scene.claims.new then
    log.warn("%s changed on disk: the head pane shows the PR's version as a copy, without LSP", entry.path)
  end
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

--- The layout a file opens in: the one it was left in, else unified for a file that exists
--- on one side only, else `config.layout`.
---@param entry NvimDiff.FileEntry
---@return NvimDiff.Layout
function View:layout_for(entry)
  local remembered = self.layouts[entry]
  if remembered then
    return remembered
  end
  local status = entry.change.status
  if status == "A" or status == "D" or status == "?" then
    return "unified"
  end
  return config.get().layout
end

--- The file on disk the head pane shows for `entry` instead of a copy (`real_file`), if any.
---@param entry NvimDiff.FileEntry
---@return string?
function View:real_path(entry)
  if not (self.review and self.real_file) or entry.change.status == "D" then
    return nil
  end
  return path.from_git(self.repo.toplevel, entry.path)
end

---@param entry NvimDiff.FileEntry
---@param folds? { list: NvimDiff.Fold[], rows: integer } As `NvimDiff.SelectOpts.folds`.
function View:show_diff(entry, folds)
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
  local layout = self:layout_for(entry)
  local wins = self:area_windows(layout == "unified" and 1 or 2)
  local old_path = entry.oldpath or entry.path
  local left, right = self:sides(entry)
  self.file = fileview.open({
    diff = d,
    layout = layout,
    mode = self.modes[entry],
    old = {
      lines = old,
      label = "a/" .. old_path,
      name = self:buf_name(left, old_path),
      lang = lang_for(old_path),
      keep = left.type == "commit",
    },
    new = {
      lines = new,
      label = "b/" .. entry.path,
      name = self:buf_name(right, entry.path),
      lang = lang_for(entry.path),
      keep = right.type == "commit",
      trailer = not self.review,
      file = self:real_path(entry),
      root = self.repo.toplevel,
      on_changed = function()
        self:head_changed(entry)
      end,
    },
    winbar = self.review,
    signs = self.review,
    on_jump = self.review and function(jump)
      self:route_jump(jump)
    end or nil,
    folds = folds and folds.rows == d.rows and folds.list or nil,
    wins = layout == "unified" and { win = wins[1] } or { old = wins[1], new = wins[2] },
    on_scene = function(file)
      self:on_scene(entry, file)
    end,
  })
  self:attach_threads(entry)
end

--- Open the merge conflict view for a conflicted (`U`) entry, in its own tabpage. Every
--- other `U` entry in this view's list becomes that view's `next_file`/`prev_file` order,
--- in panel order rather than `git/files.lua`'s.
---@param entry NvimDiff.FileEntry
function View:open_conflict(entry)
  local conflicted = {}
  for _, e in ipairs(self.list.entries) do
    if e.change.status == "U" then
      conflicted[#conflicted + 1] = e.path
    end
  end
  local ok, err = pcall(conflict_view.open, {
    repo = self.repo,
    path = path.from_git(self.repo.toplevel, entry.path),
    files = conflicted,
  })
  if not ok then
    log.error("cannot open the conflict view for %s: %s", entry.path, tostring(err):gsub("^nvim%-diff: ", ""))
  end
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

--- Focus the file panel, keeping its cursor where it is.
function View:focus_panel()
  if self:is_valid() then
    api.nvim_set_current_win(self.panel.win)
  end
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
    changes, err = files.diff(self.repo, self.left, self.right, { paths = self.paths })
    if not changes then
      log.error("refresh failed: %s", err and err.message or "?")
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

--- Diff `left` against `right` from now on — a PR review applying new code — and re-list
--- the files as `refresh` does, entries the new diff keeps keeping their state (viewed,
--- forced load, layout, diff mode). Nothing is selected after: the caller picks the file.
---@param left NvimDiff.Git.Rev
---@param right NvimDiff.Git.Rev
---@param title? string Defaults to the one the revisions give.
---@param changes? NvimDiff.Git.FileChange[] The new list, when the caller read it already.
---@return NvimDiff.EditOp[]? ops Nil when the list could not be read.
function View:retarget(left, right, title, changes)
  if not self:is_valid() then
    return nil
  end
  self.left, self.right = left, right
  self.title = title or title_of(nil, left, right)
  self.current = nil
  if self.file then
    -- A diff of the old revisions.
    self:show_note({ "", "  Select a file in the panel." })
  end
  return self:refresh(changes)
end

--- Flip a branch diff between merge-base (`a...b`, what a PR shows) and tip-to-tip
--- (`a..b`, what a rebase brings in), then re-list. Files the flip does not touch keep
--- their state and their open diff.
---@return boolean flipped False, with a warning, when the view has no range to flip.
function View:toggle_range()
  if not self:is_valid() then
    return false
  end
  if not self.range or self.range.spec.mode == "single" then
    log.warn("this diff is not between two revisions; there is no merge-base to flip")
    return false
  end
  local range, err = revparse.toggle(self.repo, self.range, self.resolve_opts)
  if not range then
    log.error("cannot flip the range: %s", err and err.message or "?")
    return false
  end
  self.range, self.left, self.right = range, range.left, range.right
  self.title = title_of(range, range.left, range.right)
  self:refresh()
  return true
end

--- Close the view: its diff, its panel and its tabpage. Idempotent.
function View:close()
  if self.closed then
    return
  end
  if by_tab[self.tab] == self then
    by_tab[self.tab] = nil
  end
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if self.panel:is_open() then
    event.emit_in({ win = self.panel.win, buf = self.panel.buf }, event.events.VIEW_CLOSED, self)
  end
  self.closed = true
  if self.thread_list then
    self.thread_list:close()
  end
  self:clear_area()
  if api.nvim_tabpage_is_valid(self.tab) and #api.nvim_list_tabpages() > 1 then
    self.panel:close()
    -- Closing the panel closes the tabpage when it was its last window; the number is read
    -- after, so the tabpage after this one (a review's files tabpage) is never closed.
    if api.nvim_tabpage_is_valid(self.tab) then
      pcall(vim.cmd, "tabclose " .. api.nvim_tabpage_get_number(self.tab))
    end
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

-- Jumps to other files ---------------------------------------------------------------------

--- Whether `buf` is a file on disk inside the view's worktree (a review's slot); nil when it
--- is no file at all (a scratch buffer, a `scheme://` one), false for one elsewhere.
---@param buf integer
---@return boolean?
function View:in_worktree(buf)
  local name = api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" or name:find("^%a[%w+.-]*://") then
    return nil
  end
  return path.is_under(path.real(name), path.real(self.repo.toplevel))
end

--- The entry the diff lists for `buf`'s file — in the worktree, at the entry's path (a
--- renamed file's new one) and not deleted; nil for any other buffer.
---@param buf integer
---@return NvimDiff.FileEntry?
function View:entry_of(buf)
  if not self:in_worktree(buf) then
    return nil
  end
  local rel = path.relative(path.real(api.nvim_buf_get_name(buf)), path.real(self.repo.toplevel))
  for _, e in ipairs(self.list.entries) do
    if e.path == rel and e.change.status ~= "D" then
      return e
    end
  end
  return nil
end

--- Whether `buf` is one of nvim-diff's own scratch buffers: a pane's copy, a panel, a note,
--- a thread list, a comment being written. A jump to one (`<C-^>`, `<C-o>` in a pane) shows
--- it nowhere. Not a real file a head pane shows, which carries the pane mark too.
---@param buf integer
---@return boolean
function View:ours(buf)
  if self:in_worktree(buf) ~= nil then
    return false
  end
  return buf == self.note_buf
    or vim.b[buf][buffer.VAR] ~= nil
    or vim.startswith(api.nvim_buf_get_name(buf), "nvim-diff://")
end

--- Route jumps out of `win`, one of the review's own windows showing `buf` (the file panel,
--- the note, the thread list), as out of a pane: `win` is not 'winfixbuf', and another
--- buffer opened there (`:edit`, a picker's pick) goes to `route_jump` once `win` has
--- `buf` back (`scene/catch.lua`).
---@param win integer
---@param buf integer
function View:route_from(win, buf)
  catch.watch(win, buf, {
    on_jump = function(jump)
      self:route_jump(jump)
    end,
  })
end

--- A jump went to another file (`NvimDiff.PaneJump`): out of one of the review's windows —
--- a pane, the file panel, the note, the thread list —, which got its buffer back
--- (`scene/catch.lua`), or into a window the review's tabpage just split for it
--- (`catch_splits`, which closed it). A file the diff lists is selected — a deferred one
--- loaded — and its diff shows on the jump's line, on the head side; any other file opens
--- in the review's files tabpage (`open_tab`). One of nvim-diff's own buffers goes nowhere.
---@param jump NvimDiff.PaneJump
function View:route_jump(jump)
  if not self:is_valid() or not api.nvim_buf_is_valid(jump.buf) or self:ours(jump.buf) then
    return
  end
  local entry = self:entry_of(jump.buf)
  if not entry then
    self:open_tab(jump)
    return
  end
  if jump.read then
    -- Loaded by the jump, as the user's: the head pane loads it its own way.
    pcall(api.nvim_buf_delete, jump.buf, { force = true })
  elseif filebuf.owns(jump.buf) then
    -- The head pane's, hidden; a jump lists the buffer it goes to.
    api.nvim_set_option_value("buflisted", false, { buf = jump.buf })
  end
  if entry ~= self.current or not self.file or self.file:is_closed() then
    self:select(entry, { force = true })
  end
  local file = self.file
  if self.current ~= entry or not file or file:is_closed() then
    return
  end
  api.nvim_set_current_win(self:diff_win("new"))
  file:jump("new", jump.lnum, jump.col)
end

--- Whether `win` can take a file a jump routes to the files tabpage: a plain window, not a
--- float, a list, a help or terminal window, nor one fixed to its buffer.
---@param win integer
---@return boolean
local function takes_file(win)
  local bt = vim.bo[api.nvim_win_get_buf(win)].buftype
  return api.nvim_win_get_config(win).relative == ""
    and vim.fn.win_gettype(win) == ""
    and not vim.wo[win].winfixbuf
    and bt ~= "help"
    and bt ~= "terminal"
    and bt ~= "prompt"
    and bt ~= "quickfix"
end

--- The window of the files tabpage the next jump shows in: the one last used there, else
--- the first that can take a file. Nil when there is no files tabpage (never opened, or
--- closed since) or no window there can.
---@return integer?
function View:files_window()
  local tab = self.files_tab
  if not tab or not api.nvim_tabpage_is_valid(tab) or tab == self.tab then
    return nil
  end
  local last = api.nvim_tabpage_get_win(tab)
  if takes_file(last) then
    return last
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if takes_file(win) then
      return win
    end
  end
  return nil
end

--- A new files tabpage right after the view's, in the view's tab-local directory, with an
--- empty jump list (`on_tab` is told). Returns its window, on an empty buffer.
---@return integer win
function View:new_files_tab()
  local nr = api.nvim_tabpage_get_number(self.tab)
  local cwd = vim.fn.getcwd(-1, nr)
  local tcd = vim.fn.haslocaldir(-1, nr) == 1
  vim.cmd(("%dtabnew"):format(nr))
  if tcd and vim.fn.getcwd() ~= cwd then
    vim.cmd.tcd(vim.fn.fnameescape(cwd))
  end
  -- A new window starts with the jump list of the one it came from: a review pane's, whose
  -- entries are the review's own buffers.
  vim.cmd("clearjumps")
  self.files_tab = api.nvim_get_current_tabpage()
  if self.on_tab then
    self.on_tab(self.files_tab)
  end
  return api.nvim_get_current_win()
end

--- Show `jump.buf` on the jump's line in the review's files tabpage: one per review, opened
--- by the first such jump right after the view's, in the view's tab-local directory, and
--- reused by every later one — in the window last used there — so `<C-o>` there goes back
--- to the file and line shown before. A file of the worktree — the PR's code — is made
--- read-only, as in the head pane ('readonly', 'nomodifiable'); one from elsewhere (a
--- library, the standard library) is not the review's, and is left as it is. The file shown
--- before stays loaded, hidden, as with `:hide`.
---@param jump NvimDiff.PaneJump
function View:open_tab(jump)
  local buf = jump.buf
  local win = self:files_window()
  local placeholder
  if win then
    api.nvim_set_current_win(win)
    -- Where `<C-o>` comes back to.
    vim.cmd("normal! m'")
  else
    win = self:new_files_tab()
    placeholder = api.nvim_win_get_buf(win)
  end
  if api.nvim_win_get_buf(win) ~= buf then
    local hidden = vim.o.hidden
    vim.o.hidden = true
    local ok, err = pcall(api.nvim_win_set_buf, win, buf)
    vim.o.hidden = hidden
    if not ok then
      log.error("cannot show %s: %s", api.nvim_buf_get_name(buf), err)
      return
    end
  end
  if
    placeholder
    and placeholder ~= buf
    and api.nvim_buf_is_valid(placeholder)
    and api.nvim_buf_get_name(placeholder) == ""
    and not vim.bo[placeholder].modified
  then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end
  if self:in_worktree(buf) then
    api.nvim_set_option_value("readonly", true, { buf = buf })
    api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  pcall(api.nvim_win_set_cursor, win, { jump.lnum, jump.col })
  api.nvim_win_call(win, function()
    -- Open the user's folds over the line, as an LSP jump does.
    vim.cmd("silent! normal! zv")
  end)
end

--- Whether `win` is one of the view's own windows: the panel, the note, the diff's panes,
--- the thread list.
---@param win integer
---@return boolean
function View:owns_window(win)
  if win == self.panel.win or win == self.note_win then
    return true
  elseif self.thread_list and win == self.thread_list.win then
    return true
  end
  return self.file ~= nil and not self.file:is_closed() and vim.tbl_contains(self.file:wins(), win)
end

--- Route a file opened in a new window of the view's tabpage as a jump (`route_jump`) when
--- the window was split off a quickfix or location list window or one of the view's own
--- windows, by the command that opened the file: a list entry or `:cnext` no pane could
--- take (Neovim splits when no window shows a file of its own: the head pane is a copy, the
--- layout is unified), a jump that opens a window of its own. The window
--- closes once the jump is over: the tabpage holds the review only. A window split off one
--- of the user's own, or a file opened in a split later, is left alone.
function View:catch_splits()
  self.augroup = self.augroup or api.nvim_create_augroup(("nvim-diff.view.%d"):format(self.tab), { clear = true })
  ---@type table<integer, true> New windows split off a list or a view window, this tick.
  local splits = {}
  ---@type table<integer, integer> Buffer to the window it was read from disk in.
  local read = {}

  api.nvim_create_autocmd("WinNew", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() ~= self.tab or not self:is_valid() then
        return
      end
      local prev = vim.fn.win_getid(vim.fn.winnr("#"))
      local kind = vim.fn.win_gettype(prev)
      if kind == "quickfix" or kind == "loclist" or self:owns_window(prev) then
        local win = api.nvim_get_current_win()
        splits[win] = true
        -- The command that split it puts the file in (`:new`, then a buffer) before this.
        vim.schedule(function()
          splits[win] = nil
        end)
      end
    end,
  })
  api.nvim_create_autocmd("BufReadPost", {
    group = self.augroup,
    callback = function(args)
      local win = api.nvim_get_current_win()
      if splits[win] then
        read[args.buf] = win
      end
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = self.augroup,
    callback = function(args)
      local win = api.nvim_get_current_win()
      -- The view's own windows (a pane buffer comes in), floats (a picker's preview) and
      -- buffers that are no file stay.
      if
        not splits[win]
        or vim.b[args.buf][buffer.VAR]
        or api.nvim_win_get_config(win).relative ~= ""
        or self:in_worktree(args.buf) == nil
      then
        return
      end
      splits[win] = nil
      local pending = true
      -- After the jump, which puts the cursor on its line after this event.
      local function route()
        if not pending then
          return
        end
        pending = false
        if not self:is_valid() or not api.nvim_win_is_valid(win) then
          return
        end
        local buf = api.nvim_win_get_buf(win)
        local cursor = api.nvim_win_get_cursor(win)
        local jump = { buf = buf, lnum = cursor[1], col = cursor[2], read = read[buf] == win }
        read = {}
        -- Its buffer stays loaded, also with 'nohidden'.
        api.nvim_win_hide(win)
        self:route_jump(jump)
      end
      api.nvim_create_autocmd("CursorMoved", { group = self.augroup, once = true, callback = route })
      vim.schedule(route)
    end,
  })
end

-- Review threads ---------------------------------------------------------------------------

--- Show a PR's review threads: on each file's diff as it opens (the one showing now at
--- once), in the side list, and as comment icons in the file panel. Replaces any threads
--- set before; `{}` clears them. The diff showing is redrawn in place, not re-diffed:
--- only rows whose threads changed are touched. `held` threads on newer code are not drawn,
--- only counted in the panel.
---@param list NvimDiff.GitHub.Thread[]
---@param held? NvimDiff.GitHub.Thread[]
function View:set_threads(list, held)
  self.threads = list
  self.held_threads = held
  local threadview = require("nvim-diff.review.threadview")
  self.thread_state = self.thread_state or threadview.new_state()
  local tv = self.thread_view
  if tv and not tv.detached and self.current and self.file and not self.file:is_closed() then
    tv:set_threads(threadview.for_path(list, self.current.path))
  elseif self.current and self.file and not self.file:is_closed() then
    self:attach_threads(self.current)
  end
  if self.thread_list and self.thread_list:is_open() then
    self.thread_list:set(self.threads or {})
  end
  if self:is_valid() then
    self:render()
  end
end

--- Put the threads of `entry` on the diff just opened for it, in place of any drawn before.
---@param entry NvimDiff.FileEntry
function View:attach_threads(entry)
  if not self.threads or not self.file then
    return
  end
  if self.thread_view then
    self.thread_view:detach()
  end
  local threadview = require("nvim-diff.review.threadview")
  self.thread_view = threadview.attach(self.file, threadview.for_path(self.threads, entry.path), {
    state = self.thread_state,
    on_list = function()
      self:toggle_thread_list()
    end,
  })
  if self.thread_list and self.thread_list:is_open() then
    self.thread_list:set(self.threads or {})
  end
end

--- Every review thread, for the side list. The list filters them itself
--- (`review/sidelist.lua`); kept for callers that read what it shows.
---@return NvimDiff.SideListItem[]
function View:thread_items()
  local filter = self.thread_list and self.thread_list:is_open() and self.thread_list.filter or "all"
  return require("nvim-diff.review.sidelist").items(self.threads or {}, filter)
end

--- Jump to `thread` from the side list: select its file and put the cursor on its line,
--- with the thread expanded. A resolved thread hidden in the diff is kept drawn, so the
--- jump lands on it instead of on nothing. A file-level or outdated thread has no line
--- to land on: its file is selected. Returns false when the thread's file is not in
--- this diff.
---@param thread NvimDiff.GitHub.Thread
---@return boolean jumped
function View:goto_thread(thread)
  if not self:is_valid() then
    return false
  end
  local entry
  for _, e in ipairs(self.list.entries) do
    if e.path == thread.path then
      entry = e
      break
    end
  end
  if not entry then
    log.warn("%s is not in this diff", thread.path)
    return false
  end
  if entry ~= self.current or not self.file or self.file:is_closed() then
    self:select(entry, { force = entry.deferred and not entry.forced })
  end
  if self.current ~= entry then
    return false
  end
  local file = self.file
  if not file or file:is_closed() then
    -- A note shows instead of a diff (a binary file, or one that cannot be read):
    -- the file is selected, and there is no line to put the cursor on.
    return true
  end
  local state = self.thread_state or require("nvim-diff.review.threadview").new_state()
  self.thread_state = state
  state.expanded[thread.id] = true
  if thread.resolved then
    state.kept = state.kept or {}
    state.kept[thread.id] = true
  end
  local tv = self.thread_view
  if tv and not tv.detached then
    tv:toggle(thread.id, true)
  end
  if thread.subject ~= "file" and thread.line and not thread.outdated then
    local side = thread.side or "new"
    local ok, win = pcall(self.diff_win, self, side)
    if ok and api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
    end
    file:jump(side, thread.line)
  else
    local ok, win = pcall(self.diff_win, self, "new")
    if ok and api.nvim_win_is_valid(win) then
      api.nvim_set_current_win(win)
    end
  end
  return true
end

--- Open the side list right of the diff, or close it.
function View:toggle_thread_list()
  if self.thread_list and self.thread_list:is_open() then
    self.thread_list:close()
    self.thread_list = nil
    return
  end
  self:open_thread_list()
end

--- Open the side list right of the diff, unless it is open already.
---@return NvimDiff.SideList
function View:open_thread_list()
  if self.thread_list and self.thread_list:is_open() then
    return self.thread_list
  end
  local wins = self.file and not self.file:is_closed() and self.file:wins() or { self.note_win }
  self.thread_list = require("nvim-diff.review.sidelist").open({
    threads = self.threads or {},
    win = wins[#wins],
    hold = self.review,
    on_select = function(thread)
      self:goto_thread(thread)
    end,
  })
  if self.review then
    self:route_from(self.thread_list.win, self.thread_list.buf)
  end
  if self.on_thread_list then
    self.on_thread_list(self.thread_list)
  end
  return self.thread_list
end

--- The view class, for views that build on this one (`views/history.lua`).
M.View = View

return M
