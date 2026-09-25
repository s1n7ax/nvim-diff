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
---
--- Two more things live here, both needing a commit panel first:
---
--- - **Range compare**: `keymaps.history.mark` toggles a mark on the commit under the
---   cursor (a ring of at most two; a third mark drops the oldest), and
---   `keymaps.history.compare` opens a normal diff view — through `commands/diff.lua`, so
---   it gets the merge-base/tip-to-tip toggle for free — between the two, older on the left.
--- - **Line history** (`M.open_line`, `git log -L`): the same panel and diff area, but the
---   walk is `git/log.lua`'s `walk_line` instead of `walk`, filtered to commits that
---   touched one line range. Reached from a diff pane's `keymaps.view.line_history`, or
---   `:NvimDiffLineHistory` on the current buffer's cursor line. Selecting a commit jumps
---   the diff to the range's line at that commit.

local commands_diff = require("nvim-diff.commands.diff")
local config = require("nvim-diff.config")
local diff_view = require("nvim-diff.views.diff")
local entry_mod = require("nvim-diff.scene.entry")
local event = require("nvim-diff.core.event")
local job = require("nvim-diff.core.job")
local log = require("nvim-diff.git.log")
local nlog = require("nvim-diff.core.log")
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

--- Placeholder oid for a line history's synthetic file entries: `-L` gives no blob ids, so
--- `entry_mod.measure`'s `blob.sizes` lookup simply misses and a line-history entry is
--- never deferred by the size threshold. Acceptable for now — see Implementation notes.
local ZERO_OID = string.rep("0", 40)

---@class NvimDiff.HistoryOpts
---@field repo NvimDiff.Git.Repo
---@field path? string Git path of a file or directory; nil or `""` for the whole repository.
---@field follow? boolean Follow a single file across renames. Defaults to `history.follow`.
---@field rev? string Where the history starts. Defaults to `HEAD`.

---@class NvimDiff.LineHistoryOpts
---@field repo NvimDiff.Git.Repo
---@field path string Git path of a file.
---@field line integer 1-based line number, in `rev`'s blob.
---@field rev? string Where the history starts, and what `line` is a line number of. Defaults to `HEAD`.

--- One commit in the panel. `commit` is a plain `NvimDiff.Git.Commit` for a file, folder or
--- repository history, and a `NvimDiff.Git.LineCommit` for a line history — both carry
--- `oid`/`parents`/`author`/`time`/`subject`, which is all `put_commit` needs.
---@class NvimDiff.HistoryCommit
---@field commit NvimDiff.Git.Commit|NvimDiff.Git.LineCommit
---@field entries NvimDiff.FileEntry[] Its files, in git's order. One synthetic entry for a line history.
---@field left NvimDiff.Git.Rev The first parent, or the empty tree for a root commit.
---@field right NvimDiff.Git.Rev The commit.
---@field expanded boolean Its files show under it (directory and repository histories).
---@field range? NvimDiff.Git.LineHunk The tracked range's location in this commit, for a line history.
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
---@field marks NvimDiff.HistoryCommit[] Commits marked for range compare; at most two.
---@field line? { start: integer, stop: integer } Set for a line history; `walk_line`'s range.
local View = setmetatable({}, { __index = diff_view.View })
View.__index = View

--- The tabpage, note buffer and panel every history view opens with, whatever it is
--- walking — a commit list (`M.open`) or one line's range (`M.open_line`). Leaves the walk
--- itself to the caller.
---@param self NvimDiff.HistoryView
---@param cfg NvimDiff.Config
local function open_tab(self, cfg)
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
end

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
    marks = {},
    layouts = setmetatable({}, { __mode = "k" }),
    modes = setmetatable({}, { __mode = "k" }),
    closed = false,
    redraw_at = 0,
    redraw_pending = false,
    opened_first = false,
  }, View)
  open_tab(self, cfg)
  self:walk()
  return self
end

--- Open the history of one line range in one file (`git log -L`) in a new tabpage:
--- otherwise the same view as `M.open` on that file, but the commits are filtered to the
--- ones that touched the range, each row shows the range's location instead of the whole
--- file's stats, and selecting a commit jumps the diff to it. Renames are followed the same
--- way `-L`'s own range tracking follows them (see `git/log.lua`), which needs no
--- `history.follow` option here. Raises when `rev` does not resolve.
---@param opts NvimDiff.LineHistoryOpts
---@return NvimDiff.HistoryView
function M.open_line(opts)
  local cfg = config.get()
  local git_path = path.to_git(opts.path)
  if git_path == "" then
    error("nvim-diff: line history needs a path", 0)
  end
  if type(opts.line) ~= "number" or opts.line < 1 then
    error("nvim-diff: line history needs a line number", 0)
  end
  local rev_spec = opts.rev or "HEAD"
  local start, err = rev_mod.resolve(opts.repo, rev_spec)
  if not start then
    error("nvim-diff: " .. (err and err.message or ("cannot resolve " .. rev_spec)), 0)
  end

  local self = setmetatable({
    repo = opts.repo,
    kind = "file",
    path = git_path,
    follow = false,
    rev_spec = rev_spec,
    start = start,
    line = { start = opts.line, stop = opts.line },
    marks = {},
    layouts = setmetatable({}, { __mode = "k" }),
    modes = setmetatable({}, { __mode = "k" }),
    closed = false,
    redraw_at = 0,
    redraw_pending = false,
    opened_first = false,
  }, View)
  open_tab(self, cfg)
  self:walk_line()
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

--- Start reading a line history from `self.start`.
---@private
function View:walk_line()
  local l = self.line
  local opts = { path = self.path, start = l.start, stop = l.stop, rev = self.start.oid }
  local task
  task = job.task(function()
    return log.walk_line(self.repo, opts, function(batch)
      if self.task == task then
        self:add_line(batch)
      end
    end)
  end, function(err, ok, walk_err)
    if self.task ~= task or self.closed then
      return
    end
    if err then
      self.state, self.message = "error", tostring(err)
    elseif not ok then
      self.state, self.message = "error", walk_err and walk_err.message or "git log -L failed"
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

--- The first parent as a `Rev`, or the empty tree for a root commit (hashed once and cached
--- on `self.empty`). Shared by `add` and `add_line`.
---@param self NvimDiff.HistoryView
---@param parents string[]
---@return NvimDiff.Git.Rev
local function parent_rev(self, parents)
  if parents[1] then
    return rev_mod.commit(parents[1], parents[1]:sub(1, ABBREV))
  end
  if not self.empty then
    local err
    self.empty, err = rev_mod.empty(self.repo)
    if not self.empty then
      error(err and err.message or "cannot hash the empty tree", 0)
    end
  end
  return self.empty
end

--- Take a batch of commits from the walk. Only data here — the walk runs in a task, and a
--- redraw may open a diff, which reads blobs; that happens on the main loop instead.
---@private
---@param batch NvimDiff.Git.Commit[]
function View:add(batch)
  for _, commit in ipairs(batch) do
    ---@type NvimDiff.HistoryCommit
    local hc = {
      commit = commit,
      entries = entry_mod.list(commit.files).entries,
      left = parent_rev(self, commit.parents),
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

--- Take a batch of commits from a line-history walk (`git log -L`). Each commit becomes a
--- `HistoryCommit` with one synthetic file entry — status `A` where the range has no
--- earlier content, `R` where this exact commit both renamed the file and touched the
--- range (`entry.oldpath` then drives the existing rename marker row unmodified), `M`
--- otherwise — so the rest of the view (selecting, measuring, reading blobs) never has to
--- know it is looking at a line history rather than a file's.
---@private
---@param batch NvimDiff.Git.LineCommit[]
function View:add_line(batch)
  for _, lc in ipairs(batch) do
    local hunk = lc.hunks[1]
    ---@type NvimDiff.Git.FileChange
    local change = {
      path = lc.path,
      oldpath = lc.oldpath,
      status = lc.oldpath and "R" or (lc.added and "A" or "M"),
      -- `-L` gives no similarity score; nothing reads this field yet.
      additions = lc.additions,
      deletions = lc.deletions,
      binary = false,
      old_mode = "100644",
      new_mode = "100644",
      old_oid = ZERO_OID,
      new_oid = ZERO_OID,
    }
    ---@type NvimDiff.HistoryCommit
    local hc = {
      commit = lc,
      entries = entry_mod.list({ change }).entries,
      left = parent_rev(self, lc.parents),
      right = rev_mod.commit(lc.oid, lc.oid:sub(1, ABBREV)),
      expanded = false,
      range = hunk,
    }
    self.commits[#self.commits + 1] = hc
    local entry = hc.entries[1]
    self.order[#self.order + 1] = entry
    self.commit_of[entry] = hc
    if self.reselect and self.reselect == key(lc.oid, entry.path) then
      self.reselect = nil
      self.current = entry
      self.reveal_pending = true
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

--- The tracked range's location in this commit's own blob, for a line history's rows.
---@param l NvimDiff.PanelLine
---@param range? NvimDiff.Git.LineHunk
local function put_line_range(l, range)
  if not range then
    return
  end
  local text = range.new_count > 1 and ("L%d-%d"):format(range.new_start, range.new_start + range.new_count - 1)
    or ("L%d"):format(range.new_start)
  put(l, " " .. text, "NvimDiffHistoryLineRange")
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
  elseif self.line then
    put(header, ("Line history: %s:%d"):format(self.path, self.line.start), "NvimDiffPanelTitle")
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

--- Buffer line of `hc`'s own summary row (never a file or rename row under it). Not
--- `Panel:line_of`: that keys on `row.entry`, which in single-file mode is the row's
--- `FileEntry`, not the commit — this instead matches every mode's `commit`-kind row by
--- `row.commit`, which is always `hc` regardless of what `row.entry` holds.
---@private
---@param hc NvimDiff.HistoryCommit
---@return integer?
function View:commit_line(hc)
  for lnum, row in pairs(self.panel.rows) do
    if row.kind == "commit" and row.commit == hc then
      return lnum
    end
  end
  return nil
end

--- Redraw one commit's rows after it folded, unfolded, or its range-compare mark changed.
---@private
---@param hc NvimDiff.HistoryCommit
function View:redraw_commit(hc)
  local lnum = self:commit_line(hc)
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
      self:put_mark(l, hc)
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
      if self.line then
        put_line_range(l, hc.range)
      elseif e then
        put_change_stats(l, e.change)
      end
      self:put_mark(l, hc)
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

--- Whether `hc` is marked for range compare.
---@param hc NvimDiff.HistoryCommit
---@return boolean
function View:is_marked(hc)
  return vim.tbl_contains(self.marks, hc)
end

--- Append the range-compare mark, when `hc` carries one. Kept off the row entirely rather
--- than a fixed-width column, so an unmarked panel (every existing history) draws exactly
--- as before.
---@param l NvimDiff.PanelLine
---@param hc NvimDiff.HistoryCommit
function View:put_mark(l, hc)
  if self:is_marked(hc) then
    put(l, "  ★", "NvimDiffHistoryMarked")
  end
end

---@param hc NvimDiff.HistoryCommit
---@return integer?
function View:commit_index(hc)
  for i, c in ipairs(self.commits) do
    if c == hc then
      return i
    end
  end
  return nil
end

--- Toggle whether the commit under the panel's cursor is marked for range compare. Marks
--- are a ring of at most two: marking a third drops the oldest mark.
function View:toggle_mark()
  local row = self.panel:cursor_row()
  if not row then
    return
  end
  local hc = row.commit
  for i, m in ipairs(self.marks) do
    if m == hc then
      table.remove(self.marks, i)
      self:redraw_commit(hc)
      return
    end
  end
  self.marks[#self.marks + 1] = hc
  local dropped
  if #self.marks > 2 then
    dropped = table.remove(self.marks, 1)
  end
  self:redraw_commit(hc)
  if dropped then
    self:redraw_commit(dropped)
  end
end

--- Diff the two marked commits — older on the left, newer on the right — in a new
--- tabpage, through `commands/diff.lua` so it gets the merge-base/tip-to-tip toggle
--- (`gm`) for free. Clears the marks either way. Warns when fewer than two are marked.
---@return NvimDiff.DiffView?
function View:compare_marked()
  if #self.marks < 2 then
    nlog.warn("mark two commits (%s) first to compare the range between them", config.get().keymaps.history.mark)
    return nil
  end
  local a, b = self.marks[1], self.marks[2]
  self.marks = {}
  self:redraw_commit(a)
  self:redraw_commit(b)
  local ia, ib = self:commit_index(a), self:commit_index(b)
  -- `self.commits` is newest first: the larger index is the older commit.
  local older, newer = a, b
  if ia and ib and ia < ib then
    older, newer = b, a
  end
  local view, err = commands_diff.open({ repo = self.repo, range = { older.commit.oid, newer.commit.oid } })
  if not view then
    nlog.error("cannot open the range compare: %s", err or "?")
  end
  return view
end

--- Map the panel's keys: select and refresh from `keymaps.panel`, mark/compare from
--- `keymaps.history`, plus next/previous file.
function View:map_panel()
  local cfg = config.get()
  local keys, history_keys = cfg.keymaps.panel, cfg.keymaps.history
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
  map(history_keys.mark, function()
    self:toggle_mark()
  end, "mark the commit under the cursor for range compare")
  map(history_keys.compare, function()
    self:compare_marked()
  end, "diff the two marked commits, older against newer")
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

--- Show `entry` above the panel. Measures it against the size threshold first, once. For a
--- line history, jumps the diff to the tracked range's location in this commit once it is
--- open — not deferred, since a deferred file shows a note instead.
---@param entry? NvimDiff.FileEntry
---@param opts? { force?: boolean }
function View:select(entry, opts)
  self.opened_first = true
  local hc = entry and self.commit_of[entry]
  if entry and not self.measured[entry] then
    self.measured[entry] = true
    entry_mod.measure(self.repo, { left = hc.left, right = hc.right }, { entry }, config.get().thresholds.defer_lines)
  end
  diff_view.View.select(self, entry, opts)
  if self.line and hc and hc.range and self.file and not self.file:is_closed() then
    self.file:jump("new", hc.range.new_start)
  end
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
  if self.line then
    self:walk_line()
  else
    self:walk()
  end
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

--- `:NvimDiffLineHistory`: the history of the line under the cursor in the current buffer
--- (`git log -L`), as of `HEAD`. For the line under the cursor of an already-open diff or
--- history view, use `keymaps.view.line_history` in its panes instead — that one knows
--- which revision the pane is showing, this one always asks about `HEAD`.
function M.command_line()
  local ok, err = pcall(function()
    local bufname = api.nvim_buf_get_name(0)
    if bufname == "" or api.nvim_get_option_value("buftype", { buf = 0 }) ~= "" then
      error("nvim-diff: no file in the current buffer", 0)
    end
    local repo, repo_err = repo_mod.discover(bufname)
    if not repo then
      error("nvim-diff: " .. (repo_err and repo_err.message or "not in a git repository"), 0)
    end
    local git_path = path.relative(path.real(bufname), path.real(repo.toplevel))
      or error(("nvim-diff: %s is outside %s"):format(bufname, repo.toplevel), 0)
    M.open_line({ repo = repo, path = git_path, line = api.nvim_win_get_cursor(0)[1] })
  end)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

return M
