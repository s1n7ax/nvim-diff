--- A merge conflict view: ours | base | theirs across the top, the editable result below.
---
--- `:NvimDiffConflict [path]` opens it for a file (default: the current buffer's), and the
--- file panel (`views/diff.lua`) opens it for a `U` entry instead of the usual two-pane
--- diff. `next_file`/`prev_file` step to the next/previous conflicted file in place —
--- same tab, same window layout, fresh panes and result buffer.
---
---     local view = require("nvim-diff.views.conflict").open({ path = "lua/foo.lua" })
---     view:next_conflict()
---     view:take("theirs")
---     view:next_file()
---
--- The three top panes are read-only index stages (2 ours, 1 base, 3 theirs), aligned on
--- shared rows by `diff/merge.lua` and kept aligned by the scroll corrector. Ours and theirs
--- light up where they differ from the base; the base lights up where either side changed
--- it — so a change only one side made shows in that side's pane alone.
---
--- The result pane is the real file, in its own buffer: LSP, `:w` and undo work as they do
--- anywhere. It is not aligned with the top panes — every edit would move the alignment —
--- but moving onto a conflict in it scrolls the top panes to the matching lines. The take
--- keys act on the conflict under the result's cursor from any of the four windows, and are
--- a plain buffer splice, undoable with `u`. Nothing is written or staged for you.

local blob = require("nvim-diff.git.blob")
local buffer = require("nvim-diff.scene.buffer")
local config = require("nvim-diff.config")
local conflict = require("nvim-diff.git.conflict")
local event = require("nvim-diff.core.event")
local files_mod = require("nvim-diff.git.files")
local hl = require("nvim-diff.ui.hl")
local log = require("nvim-diff.core.log")
local merge_mod = require("nvim-diff.diff.merge")
local path = require("nvim-diff.core.path")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local scrollsync = require("nvim-diff.scene.scrollsync")
local sidebyside = require("nvim-diff.render.sidebyside")
local threeway = require("nvim-diff.render.threeway")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

--- Highlights on the result buffer: the conflict markers and sections.
M.ns = api.nvim_create_namespace("nvim-diff.conflict")

local SIDES = merge_mod.SIDES
local STAGE = { base = 1, ours = 2, theirs = 3 }

---@class NvimDiff.ConflictViewOpts
--- The conflicted file, absolute or relative to the cwd. Defaults to the current buffer's.
---@field path? string
---@field repo? NvimDiff.Git.Repo Discovered from the path when omitted.
--- The conflicted files `next_file`/`prev_file` step through, in order. Defaults to every
--- `U` path in the repository (`git/files.lua` `status`), listed fresh at open.
---@field files? string[]

---@class NvimDiff.ConflictView
---@field repo NvimDiff.Git.Repo
---@field git_path string
---@field file string Absolute path of the work tree file.
---@field files string[] The conflicted files `next_file`/`prev_file` step through.
---@field lines table<NvimDiff.MergeSide, string[]>
---@field merge NvimDiff.Merge
---@field map NvimDiff.ThreeWayMap
---@field bufs table<NvimDiff.MergeSide, integer>
---@field wins { ours: integer, base: integer, theirs: integer, result: integer }
---@field result_buf integer
---@field sync NvimDiff.ScrollSync
---@field tab integer
---@field closed boolean
---@field private augroup integer
---@field private mapped string[] Keys mapped in the result buffer, to unmap on close.
---@field private followed? string The conflict the top panes were last scrolled to.
---@field private filler_width integer
local View = {}
View.__index = View

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

--- Read the three stages. A stage the conflict does not have (the base of an add/add, one
--- side of a modify/delete) is empty.
---@param repo NvimDiff.Git.Repo
---@param git_path string
---@return table<NvimDiff.MergeSide, string[]> lines
---@return table<NvimDiff.MergeSide, boolean> present
local function read_stages(repo, git_path)
  local stages, err = conflict.stages(repo, git_path)
  if not stages then
    error("nvim-diff: " .. err.message, 0)
  end
  local lines, present = {}, {}
  for _, side in ipairs(SIDES) do
    lines[side] = {}
    present[side] = stages[side] ~= nil
    if stages[side] then
      local b, read_err = blob.read(repo, rev.index(STAGE[side]), git_path)
      if not b then
        error("nvim-diff: " .. read_err.message, 0)
      end
      if b.binary then
        error(("nvim-diff: %s is binary; resolve it with git checkout --ours/--theirs"):format(git_path), 0)
      end
      lines[side] = blob.lines(b.bytes)
    end
  end
  return lines, present
end

--- Header text of each top pane.
---@param repo NvimDiff.Git.Repo
---@param git_path string
---@param present table<NvimDiff.MergeSide, boolean>
---@return table<NvimDiff.MergeSide, string>
local function headers(repo, git_path, present)
  local other = conflict.other_head(repo)
  local names = {
    ours = "ours (HEAD)",
    base = "base",
    theirs = other and ("theirs (%s %s)"):format(other.label, other.oid:sub(1, 8)) or "theirs",
  }
  local out = {}
  for _, side in ipairs(SIDES) do
    local text = names[side] .. " · " .. git_path
    if not present[side] then
      text = text .. " (absent)"
    end
    out[side] = sidebyside.header(text)
  end
  return out
end

--- Resolve `opts.path`/`opts.repo` to a file, its repository and its git path. Raises when
--- there is no file, or it is not inside the repository.
---@param opts NvimDiff.ConflictViewOpts
---@return string file
---@return NvimDiff.Git.Repo repo
---@return string git_path
local function resolve_file(opts)
  local file = opts.path or api.nvim_buf_get_name(0)
  if file == "" then
    error("nvim-diff: no file to resolve", 0)
  end
  file = path.normalize(file)
  local repo = opts.repo
  if not repo then
    local err
    repo, err = repo_mod.discover(file)
    if not repo then
      error("nvim-diff: " .. err.message, 0)
    end
  end
  local git_path = path.relative(path.real(file), path.real(repo.toplevel))
  if not git_path or git_path == "." or git_path:sub(1, 3) == "../" then
    error(("nvim-diff: %s is not inside %s"):format(file, repo.toplevel), 0)
  end
  return file, repo, git_path
end

--- Read and align the three stages of `git_path`. Raises when it is not conflicted, a
--- stage cannot be read, or a stage is binary. Kept separate from `View:load` so a step to
--- another file fails before this view's current windows and buffers are touched.
---@param repo NvimDiff.Git.Repo
---@param git_path string
---@return table<NvimDiff.MergeSide, string[]> lines
---@return table<NvimDiff.MergeSide, boolean> present
---@return NvimDiff.Merge merge
---@return NvimDiff.ThreeWayMap map
local function prepare(repo, git_path)
  local lines, present = read_stages(repo, git_path)
  local merge = merge_mod.align(lines.ours, lines.base, lines.theirs)
  local map = threeway.map(merge)
  return lines, present, merge, map
end

--- Open the view in a new tabpage. Raises when the file is not conflicted or cannot be read.
---@param opts? NvimDiff.ConflictViewOpts
---@return NvimDiff.ConflictView
function M.open(opts)
  opts = opts or {}
  hl.setup()
  local file, repo, git_path = resolve_file(opts)

  local conflicted_files = opts.files
  if not conflicted_files then
    local status, ferr = files_mod.status(repo)
    if not status then
      error("nvim-diff: " .. ferr.message, 0)
    end
    conflicted_files = status.conflicted
  end

  local lines, present, merge, map = prepare(repo, git_path)

  local self = setmetatable({
    repo = repo,
    files = conflicted_files,
    bufs = {},
    wins = {},
    closed = false,
    mapped = {},
  }, View)

  vim.cmd("tabnew")
  self.tab = api.nvim_get_current_tabpage()
  local placeholder = api.nvim_get_current_buf()
  self.wins.ours = api.nvim_get_current_win()
  self.wins.result = api.nvim_open_win(placeholder, false, { split = "below", win = self.wins.ours })
  self.wins.base = api.nvim_open_win(placeholder, false, { split = "right", win = self.wins.ours })
  self.wins.theirs = api.nvim_open_win(placeholder, false, { split = "right", win = self.wins.base })

  self:load(git_path, file, lines, present, merge, map, placeholder)

  event.emit_in({ win = self.wins.result, buf = self.result_buf }, event.events.VIEW_OPENED, self)
  return self
end

--- Build the three stage panes and hook up the result buffer for `git_path`, in this
--- view's existing windows: `M.open` (freshly split windows, `placeholder` the tabnew's
--- scratch buffer) and `step_file` (the same windows, a different file, no `placeholder`)
--- share it. Replaces `self`'s buffers, keymaps and scroll sync in place — never swaps
--- `self` for a new table — so a caller's reference to the view survives a file step. The
--- outgoing result buffer (on a step) keeps its conflict markers and keymaps cleaned up,
--- the same as `close()` would.
---@param git_path string
---@param file string
---@param lines table<NvimDiff.MergeSide, string[]>
---@param present table<NvimDiff.MergeSide, boolean>
---@param merge NvimDiff.Merge
---@param map NvimDiff.ThreeWayMap
---@param placeholder? integer The `tabnew` scratch buffer, first open only.
function View:load(git_path, file, lines, present, merge, map, placeholder)
  local repo = self.repo
  local old_bufs, old_result_buf, old_mapped = self.bufs, self.result_buf, self.mapped
  self.git_path, self.file, self.lines, self.merge, self.map = git_path, file, lines, merge, map

  local header = headers(repo, git_path, present)
  local lang = lang_for(git_path)
  self.bufs = {}
  for _, side in ipairs(SIDES) do
    local name = ("nvim-diff://%s/%s/%s"):format(repo.gitdir, rev.id(rev.index(STAGE[side])), git_path)
    self.bufs[side] = buffer.create({
      lines = lines[side],
      header = header[side],
      trailer = map.trailer,
      name = vim.fn.bufexists(name) == 0 and name or nil,
      lang = lang,
    })
  end

  local width = threeway.number_width(merge)
  for _, side in ipairs(SIDES) do
    window.pane(self.wins[side], self.bufs[side], {
      statuscolumn = sidebyside.statuscolumn(merge.counts[side], width),
    })
    api.nvim_win_set_cursor(self.wins[side], { 1, 0 })
  end
  for _, side in ipairs(SIDES) do
    if old_bufs[side] and api.nvim_buf_is_valid(old_bufs[side]) then
      pcall(api.nvim_buf_delete, old_bufs[side], { force = true })
    end
  end

  api.nvim_win_call(self.wins.result, function()
    vim.cmd.edit(vim.fn.fnameescape(file))
  end)
  self.result_buf = api.nvim_win_get_buf(self.wins.result)
  if placeholder and api.nvim_buf_is_valid(placeholder) and placeholder ~= self.result_buf then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end
  if placeholder then
    api.nvim_win_call(self.wins.ours, function()
      vim.cmd("wincmd =")
    end)
  end
  if old_result_buf and old_result_buf ~= self.result_buf and api.nvim_buf_is_valid(old_result_buf) then
    api.nvim_buf_clear_namespace(old_result_buf, M.ns, 0, -1)
    for _, lhs in ipairs(old_mapped) do
      pcall(vim.keymap.del, "n", lhs, { buffer = old_result_buf })
    end
  end

  self.filler_width = sidebyside.filler_width()
  for _, side in ipairs(SIDES) do
    threeway.paint(self.bufs[side], map, side)
  end
  if self.sync then
    self.sync:detach()
  end
  self.sync = scrollsync.attach({ self:sync_pane("ours"), self:sync_pane("base"), self:sync_pane("theirs") })

  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
  end
  self.mapped = {}
  self:attach()
  for _, buf in ipairs({ self.bufs.ours, self.bufs.base, self.bufs.theirs, self.result_buf }) do
    self:map_keys(buf)
  end
  self:paint_result()

  api.nvim_set_current_win(self.wins.result)
  local regions = conflict.parse(self:result_lines())
  if regions[1] then
    api.nvim_win_set_cursor(self.wins.result, { regions[1].first, 0 })
  end
  self.followed = nil
  self:follow()
end

--- The corrector's view of one top pane.
---@param side NvimDiff.MergeSide
---@return NvimDiff.SyncPane
function View:sync_pane(side)
  local map = self.map
  return {
    win = self.wins[side],
    top_view = function(topline, topfill)
      return map:top_view(side, topline, topfill)
    end,
    view_top = function(v)
      return map:view_top(side, v)
    end,
    line_view = function(lnum)
      return map:line_view(side, lnum)
    end,
    max_top = function()
      return map:max_top()
    end,
  }
end

function View:attach()
  self.augroup = api.nvim_create_augroup("nvim-diff.conflict." .. self.bufs.ours, { clear = true })
  local wins = {}
  for _, key in ipairs({ "ours", "base", "theirs", "result" }) do
    wins[#wins + 1] = tostring(self.wins[key])
  end
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = wins,
    callback = function()
      -- A window cannot be closed from inside WinClosed; part of the layout is useless.
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.augroup,
    buffer = self.result_buf,
    callback = function()
      if api.nvim_get_current_win() == self.wins.result then
        self:follow()
      end
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.result_buf,
    callback = function()
      self:paint_result()
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if sidebyside.filler_width() > self.filler_width then
        self.filler_width = sidebyside.filler_width()
        for _, side in ipairs(SIDES) do
          threeway.paint(self.bufs[side], self.map, side)
        end
        self.sync:refresh()
      end
    end,
  })
end

--- Map the conflict keys, plus `keymaps.view.next_file`/`prev_file` for stepping across
--- conflicted files, in `buf`.
---@param buf integer
function View:map_keys(buf)
  local keys = config.get().keymaps.conflict
  local view_keys = config.get().keymaps.view
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
      if buf == self.result_buf then
        self.mapped[#self.mapped + 1] = lhs
      end
    end
  end
  for _, choice in ipairs({ "ours", "base", "theirs", "both", "none" }) do
    map(keys["take_" .. choice], function()
      self:take(choice)
    end, "resolve the conflict with " .. (choice == "both" and "ours then theirs" or choice))
  end
  map(keys.next_conflict, function()
    self:next_conflict()
  end, "next conflict")
  map(keys.prev_conflict, function()
    self:prev_conflict()
  end, "previous conflict")
  map(view_keys.next_file, function()
    self:next_file()
  end, "next conflicted file")
  map(view_keys.prev_file, function()
    self:prev_file()
  end, "previous conflicted file")
end

---@return string[]
function View:result_lines()
  return api.nvim_buf_get_lines(self.result_buf, 0, -1, false)
end

---@return integer
function View:result_cursor()
  return api.nvim_win_get_cursor(self.wins.result)[1]
end

--- The conflicts left in the result, the one under its cursor, and the stepping index
--- (`git/conflict.lua` `parse`).
---@return NvimDiff.ConflictRegion[] regions
---@return NvimDiff.ConflictRegion? current
---@return number index
function View:regions()
  local regions, current, index = conflict.parse(self:result_lines(), self:result_cursor())
  return regions, current, index --[[@as number]]
end

---@param buf integer
---@param first integer 1-based
---@param last integer 1-based, inclusive
---@param group string
local function mark_lines(buf, first, last, group)
  if last < first then
    return
  end
  api.nvim_buf_set_extmark(buf, M.ns, first - 1, 0, {
    end_row = last,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = sidebyside.PRIORITY_LINE,
  })
end

--- Colour the markers and sections of every conflict left in the result.
function View:paint_result()
  local buf = self.result_buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, r in ipairs(conflict.parse(self:result_lines())) do
    mark_lines(buf, r.first, r.first, "NvimDiffConflictMarker")
    mark_lines(buf, r.ours.start, r.ours.start + r.ours.count - 1, "NvimDiffConflictOurs")
    if r.base then
      mark_lines(buf, r.base.start - 1, r.base.start - 1, "NvimDiffConflictMarker")
      mark_lines(buf, r.base.start, r.base.start + r.base.count - 1, "NvimDiffConflictBase")
    end
    mark_lines(buf, r.theirs.start - 1, r.theirs.start - 1, "NvimDiffConflictMarker")
    mark_lines(buf, r.theirs.start, r.theirs.start + r.theirs.count - 1, "NvimDiffConflictTheirs")
    mark_lines(buf, r.last, r.last, "NvimDiffConflictMarker")
  end
end

--- Where `needle` occurs as a run of lines in `hay`, choosing the occurrence nearest `near`.
---@param hay string[]
---@param needle string[]
---@param near integer
---@return integer?
local function locate(hay, needle, near)
  local best
  for s = 1, #hay - #needle + 1 do
    local ok = true
    for k = 1, #needle do
      if hay[s + k - 1] ~= needle[k] then
        ok = false
        break
      end
    end
    if ok and (not best or math.abs(s - near) < math.abs(best - near)) then
      best = s
    end
  end
  return best
end

--- Where a conflict of the result sits in the top panes: the side and line its text was
--- found at. Each section was copied from its stage, so the first non-empty one is searched
--- for in that stage's text.
---@param region NvimDiff.ConflictRegion
---@return NvimDiff.MergeSide? side
---@return integer? lnum
function View:locate(region)
  local lines = self:result_lines()
  for _, side in ipairs({ "ours", "theirs", "base" }) do
    local section = region[side]
    if section and section.count > 0 then
      local s = locate(self.lines[side], conflict.section_lines(lines, section), section.start)
      if s then
        return side, s
      end
    end
  end
  return nil, nil
end

--- Scroll the top panes to the conflict under the result's cursor, once per conflict entered.
function View:follow()
  if self.closed then
    return
  end
  local _, current = self:regions()
  if not current then
    self.followed = nil
    return
  end
  local key = current.first .. ":" .. current.last
  if key == self.followed then
    return
  end
  self.followed = key
  local side, lnum = self:locate(current)
  if not side or not lnum then
    return
  end
  local win = self.wins[side]
  api.nvim_win_set_cursor(win, { lnum + 1, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  self.sync:sync(win)
end

--- Resolve the conflict under the result's cursor. False (with a warning) when the cursor
--- is not on a conflict, or `base` is asked of a conflict written without a base section.
---@param choice NvimDiff.ConflictChoice
---@return boolean
function View:take(choice)
  local lines = self:result_lines()
  local _, current = conflict.parse(lines, self:result_cursor())
  if not current then
    log.warn("the result's cursor is not on a conflict")
    return false
  end
  local replacement = conflict.choose(lines, current, choice)
  if not replacement then
    log.warn("this conflict has no base section (git writes one with merge.conflictStyle=diff3)")
    return false
  end
  api.nvim_buf_set_lines(self.result_buf, current.first - 1, current.last, false, replacement)
  local count = api.nvim_buf_line_count(self.result_buf)
  api.nvim_win_set_cursor(self.wins.result, { math.max(1, math.min(current.first, count)), 0 })
  self:paint_result()
  self.followed = nil
  self:follow()
  return true
end

--- Move the result's cursor to the conflict `step` away (1 next, -1 previous), wrapping.
---@param step 1|-1
---@return boolean moved False when no conflicts are left.
function View:step(step)
  local regions, _, index = self:regions()
  if #regions == 0 then
    log.info("no conflicts left in %s", self.git_path)
    return false
  end
  local i = step > 0 and math.floor(index) + 1 or math.ceil(index) - 1
  i = (i - 1) % #regions + 1
  api.nvim_win_set_cursor(self.wins.result, { regions[i].first, 0 })
  api.nvim_win_call(self.wins.result, function()
    vim.cmd("normal! zz")
  end)
  self:follow()
  return true
end

---@return boolean
function View:next_conflict()
  return self:step(1)
end

---@return boolean
function View:prev_conflict()
  return self:step(-1)
end

--- Move to the conflicted file `delta` away in `self.files`, wrapping, rebuilding this
--- view's panes in place (`load`) rather than closing and reopening — a caller's reference
--- to the view stays valid across the step. Warns and returns false when `self.files` holds
--- only this file (or does not list it at all); errors resolving the target (no longer
--- conflicted, made binary since `self.files` was built) are reported and leave the view on
--- its current file.
---@param delta 1|-1
---@return boolean moved
function View:step_file(delta)
  local list = self.files
  local index
  for i, p in ipairs(list) do
    if p == self.git_path then
      index = i
      break
    end
  end
  if not index or #list <= 1 then
    log.info("no other conflicted files")
    return false
  end
  local target = list[(index - 1 + delta) % #list + 1]
  local file = path.from_git(self.repo.toplevel, target)
  local ok, lines, present, merge, map = pcall(prepare, self.repo, target)
  if not ok then
    log.error("cannot open the conflict view for %s: %s", target, tostring(lines):gsub("^nvim%-diff: ", ""))
    return false
  end
  self:load(target, file, lines, present, merge, map)
  return true
end

---@return boolean
function View:next_file()
  return self:step_file(1)
end

---@return boolean
function View:prev_file()
  return self:step_file(-1)
end

--- Close the view: the three stage panes and their buffers, and the result window. The
--- result buffer stays loaded, with whatever edits it has. Idempotent.
function View:close()
  if self.closed then
    return
  end
  if api.nvim_win_is_valid(self.wins.result) then
    event.emit_in({ win = self.wins.result, buf = self.result_buf }, event.events.VIEW_CLOSED, self)
  end
  self.closed = true
  self.sync:detach()
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  if api.nvim_buf_is_valid(self.result_buf) then
    api.nvim_buf_clear_namespace(self.result_buf, M.ns, 0, -1)
    for _, lhs in ipairs(self.mapped) do
      pcall(vim.keymap.del, "n", lhs, { buffer = self.result_buf })
    end
  end
  for _, side in ipairs(SIDES) do
    local win = self.wins[side]
    if api.nvim_win_is_valid(win) then
      api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
      if not pcall(api.nvim_win_close, win, true) then
        api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
      end
    end
  end
  -- Force hides a modified result instead of refusing; the last window stays.
  if api.nvim_win_is_valid(self.wins.result) then
    pcall(api.nvim_win_close, self.wins.result, true)
  end
  for _, side in ipairs(SIDES) do
    if api.nvim_buf_is_valid(self.bufs[side]) then
      pcall(api.nvim_buf_delete, self.bufs[side], { force = true })
    end
  end
end

--- `:NvimDiffConflict [path]`: open the conflict view for `path` (default: the current
--- buffer's file). Errors — no file, not conflicted, binary — are reported, not raised.
---@param arg? string
function M.command(arg)
  local target
  if arg and arg ~= "" then
    target = path.normalize(vim.fn.expand(arg))
  end
  local ok, err = pcall(M.open, { path = target })
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

return M
