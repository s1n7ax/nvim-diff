--- A merge conflict view: ours | base | theirs across the top, the editable result below.
---
--- This is the Lua API a command will be built on; it adds no command itself.
---
---     local view = require("nvim-diff.views.conflict").open({ path = "lua/foo.lua" })
---     view:next_conflict()
---     view:take("theirs")
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

---@class NvimDiff.ConflictView
---@field repo NvimDiff.Git.Repo
---@field git_path string
---@field file string Absolute path of the work tree file.
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

--- Open the view in a new tabpage. Raises when the file is not conflicted or cannot be read.
---@param opts? NvimDiff.ConflictViewOpts
---@return NvimDiff.ConflictView
function M.open(opts)
  opts = opts or {}
  hl.setup()
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

  local lines, present = read_stages(repo, git_path)
  local merge = merge_mod.align(lines.ours, lines.base, lines.theirs)
  local map = threeway.map(merge)
  local self = setmetatable({
    repo = repo,
    git_path = git_path,
    file = file,
    lines = lines,
    merge = merge,
    map = map,
    bufs = {},
    wins = {},
    closed = false,
    mapped = {},
  }, View)

  local header = headers(repo, git_path, present)
  local lang = lang_for(git_path)
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

  vim.cmd("tabnew")
  self.tab = api.nvim_get_current_tabpage()
  local placeholder = api.nvim_get_current_buf()
  self.wins.ours = api.nvim_get_current_win()
  self.wins.result = api.nvim_open_win(placeholder, false, { split = "below", win = self.wins.ours })
  self.wins.base = api.nvim_open_win(placeholder, false, { split = "right", win = self.wins.ours })
  self.wins.theirs = api.nvim_open_win(placeholder, false, { split = "right", win = self.wins.base })

  local width = threeway.number_width(merge)
  for _, side in ipairs(SIDES) do
    window.pane(self.wins[side], self.bufs[side], {
      statuscolumn = sidebyside.statuscolumn(merge.counts[side], width),
    })
    api.nvim_win_set_cursor(self.wins[side], { 1, 0 })
  end
  api.nvim_win_call(self.wins.result, function()
    vim.cmd.edit(vim.fn.fnameescape(file))
  end)
  self.result_buf = api.nvim_win_get_buf(self.wins.result)
  if api.nvim_buf_is_valid(placeholder) and placeholder ~= self.result_buf then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end
  api.nvim_win_call(self.wins.ours, function()
    vim.cmd("wincmd =")
  end)

  self.filler_width = sidebyside.filler_width()
  for _, side in ipairs(SIDES) do
    threeway.paint(self.bufs[side], map, side)
  end
  self.sync = scrollsync.attach({ self:sync_pane("ours"), self:sync_pane("base"), self:sync_pane("theirs") })

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
  self:follow()

  event.emit_in({ win = self.wins.result, buf = self.result_buf }, event.events.VIEW_OPENED, self)
  return self
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

--- Map the conflict keys in `buf`.
---@param buf integer
function View:map_keys(buf)
  local keys = config.get().keymaps.conflict
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

return M
