--- A history view: a tabpage with the commits that touched a file, a directory or the whole
--- repository in a panel along the bottom, and above it the diff of one file in the
--- selected commit against that commit's first parent.
---
---     local view = require("nvim-diff.views.history").open({ repo = repo, path = "lua/init.lua" })
---     view:next_file()
---
--- It is a diff view (`views/diff.lua`) with a different panel and a revision pair per
--- commit: the diff area, the layout toggle, folding, the size threshold, next/previous
--- file and the events all come from there.
---
--- The history streams. `git log` runs in a task; commits are added as they are read, and
--- the panel redraws at most `REDRAW_FPS` times a second, showing `loading…` until the walk
--- ends. The first commit's file opens as soon as it arrives. Closing the view (or
--- refreshing it) kills the walk.
---
--- Panel rows:
---
--- - A single file: one row per commit — the file's status in it, the abbreviated id, the
---   author date, the subject, the author and the file's line counts. Renames are followed
---   (`history.follow`); under the commit where the trail crossed one sits a marker row
---   naming the path the file had before it.
--- - A directory or the whole repository: one foldable row per commit with its file count
---   and totals; unfolded, the commit's files under it. Selecting a folded commit unfolds
---   it and opens its first file.

local config = require("nvim-diff.config")
local diff_view = require("nvim-diff.views.diff")
local entry_mod = require("nvim-diff.scene.entry")
local event = require("nvim-diff.core.event")
local job = require("nvim-diff.core.job")
local log = require("nvim-diff.git.log")
local panel_mod = require("nvim-diff.ui.panel")
local path = require("nvim-diff.core.path")
local repo_mod = require("nvim-diff.git.repo")
local rev_mod = require("nvim-diff.git.rev")

local api = vim.api
local line, put, put_stats = panel_mod.line, panel_mod.put, panel_mod.put_stats

local M = {}

--- Panel redraws per second while the history streams in.
M.REDRAW_FPS = 15

--- Characters of a commit id shown in the panel.
local ABBREV = 7

---@class NvimDiff.HistoryOpts
---@field repo NvimDiff.Git.Repo
---@field path? string Git path of a file or directory; nil or `""` for the whole repository.
---@field follow? boolean Follow a single file across renames. Defaults to `history.follow`.
---@field rev? string Where the history starts. Defaults to `HEAD`.

--- One commit in the panel.
---@class NvimDiff.HistoryCommit
---@field commit NvimDiff.Git.Commit
---@field entries NvimDiff.FileEntry[] Its files, in git's order.
---@field left NvimDiff.Git.Rev The first parent, or the empty tree for a root commit.
---@field right NvimDiff.Git.Rev The commit.
---@field expanded boolean Its files show under it (directory and repository histories).
---@field size? integer Panel rows it took when last drawn.

---@alias NvimDiff.HistoryRow
---| { kind: "commit", entry: NvimDiff.FileEntry|NvimDiff.HistoryCommit, commit: NvimDiff.HistoryCommit }
---| { kind: "file", entry: NvimDiff.FileEntry, commit: NvimDiff.HistoryCommit }
---| { kind: "rename", commit: NvimDiff.HistoryCommit }

---@alias NvimDiff.HistoryState "loading"|"done"|"error"

---@class NvimDiff.HistoryView : NvimDiff.DiffView
---@field kind NvimDiff.Git.LogKind
---@field path string The walked git path; `""` for the whole repository.
---@field follow boolean
---@field rev_spec string
---@field start NvimDiff.Git.Rev Where the current walk started, resolved.
---@field commits NvimDiff.HistoryCommit[]
---@field drawn integer How many of `commits` the panel shows.
---@field order NvimDiff.FileEntry[] Every commit's entries, in panel order: what next/prev walk.
---@field commit_of table<NvimDiff.FileEntry, NvimDiff.HistoryCommit>
---@field measured table<NvimDiff.FileEntry, boolean>
---@field state NvimDiff.HistoryState
---@field message? string Why the walk failed.
---@field task? NvimDiff.Job.Task
---@field empty? NvimDiff.Git.Rev The empty tree, once a root commit needed it.
---@field redraw_at number When the panel may next redraw (ms, `vim.uv.now()`).
---@field redraw_pending boolean
---@field opened_first boolean The first file has been opened (or the user chose one).
---@field reselect? string `oid NUL path` of the entry to reselect after a refresh.
---@field reveal_pending? boolean The walk found `reselect`; mark it on the next redraw.
local View = setmetatable({}, { __index = diff_view.View })
View.__index = View

--- Open a history view in a new tabpage and start reading the history. Raises when the
--- starting revision does not resolve (an unborn branch included).
---@param opts NvimDiff.HistoryOpts
---@return NvimDiff.HistoryView
function M.open(opts)
  local cfg = config.get()
  local git_path = path.to_git(opts.path or "")
  if git_path == "." then
    git_path = ""
  end
  local kind = log.kind(opts.repo, git_path)
  local rev_spec = opts.rev or "HEAD"
  local start, err = rev_mod.resolve(opts.repo, rev_spec)
  if not start then
    error("nvim-diff: " .. (err and err.message or ("cannot resolve " .. rev_spec)), 0)
  end
  local follow = kind == "file"
  if opts.follow ~= nil then
    follow = follow and opts.follow
  else
    follow = follow and cfg.history.follow
  end

  local self = setmetatable({
    repo = opts.repo,
    kind = kind,
    path = git_path,
    follow = follow,
    rev_spec = rev_spec,
    start = start,
    layouts = setmetatable({}, { __mode = "k" }),
    modes = setmetatable({}, { __mode = "k" }),
    closed = false,
    redraw_at = 0,
    redraw_pending = false,
    opened_first = false,
  }, View)
  self:reset()

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

  self.panel = panel_mod.new({ width = cfg.panel.width, height = cfg.history.height, position = "bottom" })
  self.panel:open(area)
  self:show_note({ "", "  Reading the history…" })
  self:map_panel()
  self:map_view(self.note_buf)
  self:render()
  api.nvim_set_current_win(self.panel.win)

  event.emit_in({ win = self.panel.win, buf = self.panel.buf }, event.events.VIEW_OPENED, self)
  self:walk()
  return self
end

--- Forget every commit.
---@private
function View:reset()
  self.commits = {}
  self.drawn = 0
  self.order = {}
  self.commit_of = setmetatable({}, { __mode = "k" })
  self.measured = setmetatable({}, { __mode = "k" })
  self.state = "loading"
  self.message = nil
end

--- Start reading the history from `self.start`.
---@private
function View:walk()
  local opts = { path = self.path, follow = self.follow, rev = self.start.oid }
  local task
  task = job.task(function()
    return log.walk(self.repo, opts, function(batch)
      if self.task == task then
        self:add(batch)
      end
    end)
  end, function(err, ok, walk_err)
    if self.task ~= task or self.closed then
      return
    end
    if err then
      self.state, self.message = "error", tostring(err)
    elseif not ok then
      self.state, self.message = "error", walk_err and walk_err.message or "git log failed"
    else
      self.state = "done"
    end
    self:schedule_redraw(true)
  end)
  self.task = task
end

---@param oid string
---@param git_path string
---@return string
local function key(oid, git_path)
  return oid .. "\0" .. git_path
end

--- Take a batch of commits from the walk. Only data here — the walk runs in a task, and a
--- redraw may open a diff, which reads blobs; that happens on the main loop instead.
---@private
---@param batch NvimDiff.Git.Commit[]
function View:add(batch)
  for _, commit in ipairs(batch) do
    local left
    if commit.parents[1] then
      left = rev_mod.commit(commit.parents[1], commit.parents[1]:sub(1, ABBREV))
    else
      if not self.empty then
        local err
        self.empty, err = rev_mod.empty(self.repo)
        if not self.empty then
          error(err and err.message or "cannot hash the empty tree", 0)
        end
      end
      left = self.empty
    end
    ---@type NvimDiff.HistoryCommit
    local hc = {
      commit = commit,
      entries = entry_mod.list(commit.files).entries,
      left = left,
      right = rev_mod.commit(commit.oid, commit.oid:sub(1, ABBREV)),
      expanded = false,
    }
    self.commits[#self.commits + 1] = hc
    for _, entry in ipairs(hc.entries) do
      self.order[#self.order + 1] = entry
      self.commit_of[entry] = hc
      if self.reselect and self.reselect == key(commit.oid, entry.path) then
        self.reselect = nil
        self.current = entry
        self.reveal_pending = true
        hc.expanded = true
      end
    end
  end
  self:schedule_redraw(false)
end

--- Redraw the panel soon, at most `REDRAW_FPS` times a second; `now` skips the wait.
---@private
---@param now boolean
function View:schedule_redraw(now)
  if self.redraw_pending and not now then
    return
  end
  self.redraw_pending = true
  local delay = now and 0 or math.max(0, self.redraw_at - vim.uv.now())
  vim.defer_fn(function()
    if not self.redraw_pending then
      return
    end
    self.redraw_pending = false
    self:flush()
  end, delay)
end

--- Redraw, and open the first file once there is one.
---@private
function View:flush()
  if not self:is_valid() then
    return
  end
  self.redraw_at = vim.uv.now() + 1000 / M.REDRAW_FPS
  self:append()
  self.panel:set_current(self.current)
  if self.reveal_pending then
    -- A refresh found the file that was showing.
    self.reveal_pending = false
    self:reveal(self.current)
  end
  if not self.opened_first then
    if self.order[1] then
      self.opened_first = true
      self:select(self.order[1])
    elseif self.state ~= "loading" then
      self.opened_first = true
      self:show_note({ "", "  " .. (self.state == "error" and "The history could not be read." or "No commits.") })
    end
  end
end

--- Whether a directory's or the repository's history: commits fold, files list under them.
---@return boolean
function View:is_multi()
  return self.kind ~= "file"
end

---@param entry NvimDiff.FileEntry
---@return NvimDiff.Git.Rev left
---@return NvimDiff.Git.Rev right
function View:sides(entry)
  local hc = assert(self.commit_of[entry], "entry is not in this history")
  return hc.left, hc.right
end

---@param l NvimDiff.PanelLine
---@param hc NvimDiff.HistoryCommit
local function put_commit(l, hc)
  local c = hc.commit
  put(l, c.oid:sub(1, ABBREV), "NvimDiffHistoryHash")
  put(l, " ")
  put(l, os.date("%Y-%m-%d", c.time) --[[@as string]], "NvimDiffHistoryDate")
  put(l, " ")
  put(l, c.subject, "NvimDiffPanelPath")
  put(l, " (" .. c.author .. ")", "NvimDiffHistoryAuthor")
end

---@param l NvimDiff.PanelLine
---@param change NvimDiff.Git.FileChange
local function put_change_stats(l, change)
  if change.binary then
    put(l, " bin", "NvimDiffPanelDeferred")
  elseif change.additions then
    put_stats(l, change.additions, change.deletions)
  end
end

--- The status line: the commit count, and whether the walk is still going or failed.
---@private
---@return NvimDiff.PanelLine
function View:status_line()
  local status = line()
  local n = #self.commits
  put(status, ("%s %s"):format(panel_mod.thousands(n), n == 1 and "commit" or "commits"))
  if self.state == "loading" then
    put(status, "  loading…", "NvimDiffPanelDeferred")
  elseif self.state == "error" then
    put(status, "  " .. (self.message or "failed"):gsub("\n.*", ""), "NvimDiffHistoryError")
  end
  return status
end

--- Rebuild every row and redraw the whole panel. Streaming and folding redraw only what
--- changed (`flush`, `redraw_commit`); this is for opening and refreshing.
function View:render()
  local header = line()
  if self.kind == "repo" then
    put(header, "History: whole repository", "NvimDiffPanelTitle")
  else
    put(header, "History: " .. self.path .. (self.kind == "dir" and "/" or ""), "NvimDiffPanelTitle")
  end
  if self.rev_spec ~= "HEAD" then
    put(header, " @ " .. self.rev_spec, "NvimDiffPanelTitle")
  end

  local lines, rows = { header, self:status_line() }, {}
  for _, hc in ipairs(self.commits) do
    local block, block_rows = self:commit_block(hc)
    for i, l in ipairs(block) do
      lines[#lines + 1] = l
      rows[#lines] = block_rows[i]
    end
  end
  self.drawn = #self.commits
  self.panel:draw(lines, rows, 3, self.current)
end

--- Add the commits the walk delivered since the last redraw, and update the status line.
---@private
function View:append()
  local lines, rows = {}, {}
  for i = self.drawn + 1, #self.commits do
    local block, block_rows = self:commit_block(self.commits[i])
    for j, l in ipairs(block) do
      lines[#lines + 1] = l
      rows[#lines] = block_rows[j]
    end
  end
  self.drawn = #self.commits
  if #lines > 0 then
    local n = api.nvim_buf_line_count(self.panel.buf)
    self.panel:splice(n + 1, n + 1, lines, rows)
  end
  self.panel:splice(2, 3, { self:status_line() }, {})
end

--- Redraw one commit's rows after it folded or unfolded.
---@private
---@param hc NvimDiff.HistoryCommit
function View:redraw_commit(hc)
  local lnum = self.panel:line_of(hc)
  if not lnum then
    return
  end
  local size = hc.size
  local block, rows = self:commit_block(hc)
  self.panel:splice(lnum, lnum + size, block, rows)
  self.panel:set_current(self.current)
end

--- The rows one commit takes in the panel. Records their count as `hc.size`.
---@private
---@param hc NvimDiff.HistoryCommit
---@return NvimDiff.PanelLine[] lines
---@return NvimDiff.HistoryRow[] rows
function View:commit_block(hc)
  local lines, rows = {}, {}
  local multi = self:is_multi()
  do
    local l = line()
    if multi then
      put(l, hc.expanded and "▾ " or "▸ ", "NvimDiffPanelDir")
      put_commit(l, hc)
      local adds, dels = 0, 0
      for _, e in ipairs(hc.entries) do
        adds, dels = adds + (e.change.additions or 0), dels + (e.change.deletions or 0)
      end
      put(l, ("  %d %s"):format(#hc.entries, #hc.entries == 1 and "file" or "files"))
      put_stats(l, adds, dels)
      lines[#lines + 1] = l
      rows[#lines] = { kind = "commit", entry = hc, commit = hc }
      if hc.expanded then
        for _, e in ipairs(hc.entries) do
          local fl = line()
          put(fl, "    ")
          put(fl, e.change.status, panel_mod.STATUS_HL[e.change.status])
          put(fl, " ")
          put(fl, e.path, "NvimDiffPanelPath")
          if e.oldpath then
            put(fl, " ← " .. e.oldpath, "NvimDiffPanelOldPath")
          end
          put_change_stats(fl, e.change)
          lines[#lines + 1] = fl
          rows[#lines] = { kind = "file", entry = e, commit = hc }
        end
      end
    else
      local e = hc.entries[1]
      put(l, e and e.change.status or " ", e and panel_mod.STATUS_HL[e.change.status] or nil)
      put(l, " ")
      put_commit(l, hc)
      if e then
        put_change_stats(l, e.change)
      end
      lines[#lines + 1] = l
      rows[#lines] = { kind = "commit", entry = e or hc, commit = hc }
      if e and e.oldpath then
        local marker = line()
        put(
          marker,
          ("  ⤷ %s from %s"):format(e.change.status == "C" and "copied" or "renamed", e.oldpath),
          "NvimDiffHistoryRename"
        )
        lines[#lines + 1] = marker
        rows[#lines] = { kind = "rename", commit = hc }
      end
    end
  end
  hc.size = #lines
  return lines, rows
end

--- Map the panel's keys: select and refresh from `keymaps.panel`, plus next/previous file.
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
  end, "open the commit or file under the cursor, or fold the commit")
  map(keys.refresh, function()
    self:refresh()
  end, "read the history again")
  self:map_view(buf)
end

--- `n` fresh windows above the panel, left to right, holding the note buffer.
---@param n integer
---@return integer[]
function View:area_windows(n)
  local wins = { api.nvim_open_win(self.note_buf, false, { split = "above", win = self.panel.win }) }
  self.panel:fix_width()
  for i = 2, n do
    wins[i] = api.nvim_open_win(self.note_buf, false, { split = "right", win = wins[i - 1] })
  end
  return wins
end

--- Show `entry` above the panel. Measures it against the size threshold first, once.
---@param entry? NvimDiff.FileEntry
---@param opts? { force?: boolean }
function View:select(entry, opts)
  self.opened_first = true
  if entry and not self.measured[entry] then
    self.measured[entry] = true
    local hc = self.commit_of[entry]
    entry_mod.measure(self.repo, { left = hc.left, right = hc.right }, { entry }, config.get().thresholds.defer_lines)
  end
  diff_view.View.select(self, entry, opts)
end

--- Unfold the commit holding `entry`, and mark it current in the panel.
---@param entry? NvimDiff.FileEntry
function View:reveal(entry)
  local hc = entry and self.commit_of[entry]
  if hc and self:is_multi() and not hc.expanded then
    hc.expanded = true
    self:redraw_commit(hc)
  else
    self.panel:set_current(entry)
  end
  local lnum = entry and self.panel:line_of(entry)
  if lnum then
    self.panel:set_cursor(lnum)
  end
end

--- Show a note saying a commit has no files to show.
---@param hc NvimDiff.HistoryCommit
function View:show_empty(hc)
  self.current = nil
  self.panel:set_current(nil)
  self:show_note({
    "",
    "  " .. hc.commit.oid:sub(1, ABBREV) .. " " .. hc.commit.subject,
    "",
    "  No file changes against its first parent.",
  })
end

--- Act on the row under the panel's cursor: open a file; on a commit, open its file (a
--- single file's history) or fold/unfold it and open its first file when unfolding.
function View:select_cursor()
  local row = self.panel:cursor_row()
  if not row then
    return
  end
  local hc = row.commit
  local entry
  if row.kind == "file" then
    entry = row.entry
  elseif self:is_multi() and row.kind == "commit" then
    hc.expanded = not hc.expanded
    self:redraw_commit(hc)
    local lnum = self.panel:line_of(hc)
    if lnum then
      self.panel:set_cursor(lnum)
    end
    if not hc.expanded or (self.current and self.commit_of[self.current] == hc) then
      return
    end
    entry = hc.entries[1]
  else
    entry = hc.entries[1]
  end
  if not entry then
    self:show_empty(hc)
    return
  end
  -- Selecting a deferred file whose note is already showing is the request to load it.
  local again = entry == self.current and entry.deferred and self.note_win ~= nil
  local from = api.nvim_get_current_win()
  self:select(entry, { force = again })
  -- On a folding commit row, keep the cursor on the commit rather than its file.
  if row.kind == "commit" and self:is_multi() and api.nvim_get_current_win() == from then
    local lnum = self.panel:line_of(hc)
    if lnum then
      self.panel:set_cursor(lnum)
    end
  end
end

--- Step through every commit's files in panel order, wrapping at the ends.
---@param delta integer
function View:step(delta)
  local order = self.order
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

--- Read the history again from `rev` (re-resolved, so `HEAD` picks up new commits). The
--- diff showing stays; its entry is found again when the walk reaches it.
function View:refresh()
  if not self:is_valid() then
    return
  end
  local start, err = rev_mod.resolve(self.repo, self.rev_spec)
  if not start then
    require("nvim-diff.core.log").error("refresh failed: %s", err and err.message or "?")
    return
  end
  if self.task then
    self.task:cancel()
  end
  local current = self.current
  local hc = current and self.commit_of[current]
  self.reselect = hc and key(hc.commit.oid, current.path) or nil
  -- Until the walk finds it again nothing is marked, and the diff keeps showing rather
  -- than being replaced by the first commit's.
  self.current = nil
  self.opened_first = current ~= nil
  self.start = start
  self:reset()
  self:render()
  self:walk()
end

--- Close the view, stopping the walk. Idempotent.
function View:close()
  if self.task then
    self.task:cancel()
    self.task = nil
  end
  diff_view.View.close(self)
end

--- `:NvimDiffHistory [path]`: the history of `path` (a file or directory; `%` is the
--- current file), or of the whole repository around the current directory when omitted.
---@param arg? string
function M.command(arg)
  local target
  if arg and arg ~= "" then
    target = path.normalize(vim.fn.expand(arg))
  end
  local ok, err = pcall(function()
    local repo, repo_err = repo_mod.discover(target)
    if not repo then
      error("nvim-diff: " .. (repo_err and repo_err.message or "not in a git repository"), 0)
    end
    local git_path = ""
    if target then
      git_path = path.relative(path.real(target), path.real(repo.toplevel))
        or error(("nvim-diff: %s is outside %s"):format(target, repo.toplevel), 0)
    end
    M.open({ repo = repo, path = git_path })
  end)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

return M
