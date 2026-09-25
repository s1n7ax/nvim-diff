--- A GitHub PR review: the PR checked out into its own worktree, diffed in its own tabpage,
--- with GitHub's per-file viewed marks in the file panel.
---
---     local review = require("nvim-diff.views.review").open({ number = 42 })
---     review:mark_viewed() -- marks the current file viewed on GitHub, jumps to the next unviewed
---     review:close()       -- closes the tab and removes the worktree
---
--- Opening a review:
---
--- 1. fetches the PR's node id, head and base (`github/pr.lua`);
--- 2. fetches `refs/pull/<n>/head` and the base branch from the remote when either commit
---    is missing locally (`git/fetch.lua`) — nothing is written to the user's refs;
--- 3. diffs `merge-base(base, head)` against `head`, both as commits, locally with git —
---    never GitHub's `/pulls/{n}/files`;
--- 4. reads every file's viewed state (`github/viewed.lua`);
--- 5. checks `head` out, detached, into `<common git dir>/nvim-diff/pr-<n>`
---    (`git/worktree.lua`), so LSP, tests and the debugger see the PR's code while the
---    user's branch and uncommitted changes are never touched;
--- 6. opens a `views/diff.lua` view on the worktree in a new tabpage, `:tcd` to the
---    worktree, and selects the first file not yet viewed.
---
--- Ending the review — `:tabclose`, `:NvimDiffClose`, `review:close()` or quitting Neovim —
--- closes the view, wipes any buffer on a file inside the worktree and removes the worktree.
---
--- Viewed state lives on GitHub only. `keymaps.review.mark_viewed` posts the mark, then
--- jumps to the next file that is not viewed (unviewed or re-changed), in panel order;
--- `unmark_viewed` clears it and stays. The panel changes only after GitHub accepted the
--- change. Nothing about the review is kept once it ends; reopening refetches everything.
---
--- Comments are written in a bottom split (`review/compose.lua`) and post immediately, one
--- at a time (`github/comments.lua`): `keymaps.comment.add` on the cursor's line of either
--- pane, or on a visual selection; `keymaps.comment.reply` answers the thread on the
--- cursor's line. After a post the threads are refetched and the new comment's thread shows
--- expanded.

local comment_mod = require("nvim-diff.review.comment")
local comments_mod = require("nvim-diff.github.comments")
local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")
local event = require("nvim-diff.core.event")
local fetch = require("nvim-diff.git.fetch")
local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")
local pr_mod = require("nvim-diff.github.pr")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local revparse = require("nvim-diff.git.revparse")
local threads_mod = require("nvim-diff.github.threads")
local viewed_mod = require("nvim-diff.github.viewed")
local views = require("nvim-diff.views.diff")
local worktree = require("nvim-diff.git.worktree")

local api = vim.api

local M = {}

--- Open reviews by PR number. One worktree per PR, so one review per PR.
---@type table<integer, NvimDiff.Review>
local by_number = {}

---@class NvimDiff.ReviewOpts
---@field number integer The PR number.
---@field repo? NvimDiff.Git.Repo Discovered from the cwd when omitted.
---@field remote? string The remote the PR lives on and is fetched from. Defaults to `origin`.

---@class NvimDiff.Review
---@field repo NvimDiff.Git.Repo The user's repository, which owns the worktree.
---@field number integer
---@field pr NvimDiff.GitHub.PR
---@field path string The worktree.
---@field cwd string The cwd before the review opened, restored on a tabpage that outlives it.
---@field view NvimDiff.DiffView
---@field augroup integer
---@field unsubscribe fun()[]
---@field closed boolean
---@field compose? NvimDiff.Compose The comment or reply being written, if any.
local Review = {}
Review.__index = Review

--- The review showing in `tab`, if any.
---@param tab? integer Defaults to the current tabpage.
---@return NvimDiff.Review?
function M.get(tab)
  tab = tab or api.nvim_get_current_tabpage()
  for _, review in pairs(by_number) do
    if not review.closed and review.view.tab == tab then
      return review
    end
  end
  return nil
end

---@param message string
local function fail(message)
  error("nvim-diff: " .. message, 0)
end

---@param err? { message: string }
---@return string
local function msg(err)
  return err and err.message or "unknown error"
end

--- Open PR `opts.number` for review in a new tabpage. When that PR is already open, its tab
--- is entered instead. Raises when the PR cannot be fetched or checked out; nothing is left
--- behind on failure.
---@param opts NvimDiff.ReviewOpts
---@return NvimDiff.Review
function M.open(opts)
  local number = opts.number
  if type(number) ~= "number" or number < 1 or number % 1 ~= 0 then
    fail(("not a PR number: %s"):format(vim.inspect(number)))
  end
  local existing = by_number[number]
  if existing and not existing.closed and existing.view:is_valid() then
    api.nvim_set_current_tabpage(existing.view.tab)
    return existing
  end

  local repo, err = opts.repo
  if not repo then
    repo, err = repo_mod.discover()
    if not repo then
      fail(msg(err))
    end
  end
  ---@cast repo NvimDiff.Git.Repo
  local remote = opts.remote or "origin"

  local pr
  pr, err = pr_mod.fetch(repo, number, { remote = remote })
  if not pr then
    fail(("cannot fetch PR #%d: %s"):format(number, msg(err)))
  end

  local refs = { ("refs/pull/%d/head"):format(number) }
  if pr.base.ref then
    refs[#refs + 1] = "refs/heads/" .. pr.base.ref
  end
  local ok
  ok, err = fetch.commits(repo, remote, refs, { pr.head.oid, pr.base.oid })
  if not ok then
    fail(("cannot fetch PR #%d's commits from %s: %s"):format(number, remote, msg(err)))
  end

  local head = rev.commit(pr.head.oid, ("#%d"):format(number))
  local base = rev.commit(pr.base.oid, pr.base.ref)
  local left
  left, err = revparse.merge_base(repo, base, head)
  if not left then
    fail(msg(err))
  end

  local states
  states, err = viewed_mod.fetch(pr)
  if not states then
    fail(("cannot read PR #%d's viewed files: %s"):format(number, msg(err)))
  end

  local threads
  threads, err = threads_mod.fetch(pr.target, number)
  if not threads then
    fail(("cannot read PR #%d's comment threads: %s"):format(number, msg(err)))
  end

  local wt_path
  wt_path, err = worktree.add(repo, number, head)
  if not wt_path then
    fail(("cannot check PR #%d out into a worktree: %s"):format(number, msg(err)))
  end

  local cwd = vim.fn.getcwd()
  local wt_repo
  wt_repo, err = repo_mod.discover(wt_path)
  local view_ok, view
  if wt_repo then
    view_ok, view = pcall(views.open, {
      repo = wt_repo,
      left = left,
      right = head,
      title = ("#%d %s"):format(number, pr.title or ""),
    })
  end
  if not wt_repo or not view_ok then
    worktree.remove(repo, number)
    fail(wt_repo and tostring(view):gsub("^nvim%-diff: ", "") or msg(err))
  end

  local self = setmetatable({
    repo = repo,
    number = number,
    pr = pr,
    path = wt_path,
    cwd = cwd,
    view = view,
    unsubscribe = {},
    closed = false,
  }, Review)
  by_number[number] = self

  -- `views.open` leaves its new tabpage current.
  vim.cmd.tcd(vim.fn.fnameescape(wt_path))
  for _, entry in ipairs(view.list.entries) do
    entry.viewed = states[entry.path] or "unviewed"
  end
  view:render()
  view:set_threads(threads)
  self:trap()
  self:map_keys(view.panel.buf)
  self:map_keys(view.note_buf)

  local first = self:next_unviewed(nil) or view.tree.order[1]
  if first then
    view:select(first)
  end
  return self
end

--- End the review when its tabpage goes, when its view is closed, and when Neovim exits;
--- map the review keys in every diff buffer the view opens.
function Review:trap()
  self.augroup = api.nvim_create_augroup(("nvim-diff.review.%d"):format(self.number), { clear = true })
  api.nvim_create_autocmd("TabClosed", {
    group = self.augroup,
    callback = function()
      if not api.nvim_tabpage_is_valid(self.view.tab) then
        -- After the event: closing windows is not safe inside `TabClosed`.
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = self.augroup,
    callback = function()
      -- Neovim is going away with its windows; only the worktree needs removing.
      self:close({ windows = false })
    end,
  })
  self.unsubscribe[#self.unsubscribe + 1] = event.on(event.events.VIEW_CLOSED, function(view)
    if view == self.view then
      -- `view_closed` fires before the view tears its tabpage down.
      vim.schedule(function()
        self:close()
      end)
    end
  end)
  self.unsubscribe[#self.unsubscribe + 1] = event.on(event.events.DIFF_BUF_READY, function(buf)
    -- Fired with the buffer's window current, so its tabpage is current too.
    if not self.closed and api.nvim_get_current_tabpage() == self.view.tab then
      self:map_keys(buf)
      self:map_comment_keys(buf)
    end
  end)
end

--- Map the comment keys in the diff pane buffer `buf`.
---@param buf integer
function Review:map_comment_keys(buf)
  local keys = config.get().keymaps.comment
  local function map(modes, lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map("n", keys.add, function()
    self:comment()
  end, "comment on this line on GitHub")
  map("x", keys.add, function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    self:comment({ first = first, last = last })
  end, "comment on the selected lines on GitHub")
  map("n", keys.reply, function()
    self:reply()
  end, "reply to the comment thread on this line")
end

--- Map the review keys in `buf`.
---@param buf integer
function Review:map_keys(buf)
  local keys = config.get().keymaps.review
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.mark_viewed, function()
    self:mark_viewed()
  end, "mark the file viewed on GitHub and jump to the next unviewed file")
  map(keys.unmark_viewed, function()
    self:unmark_viewed()
  end, "clear the file's viewed mark on GitHub")
end

--- The file a viewed key acts on: the file row under the cursor in the panel, else the file
--- showing.
---@return NvimDiff.FileEntry?
function Review:target()
  local view = self.view
  if api.nvim_get_current_win() == view.panel.win then
    local row = view.panel:cursor_row()
    if row and row.kind ~= "dir" and row.entry then
      return row.entry
    end
  end
  return view.current
end

--- The first file after `from` in panel order that is not viewed, wrapping; `from` itself
--- only when nothing else is left.
---@param from? NvimDiff.FileEntry Nil: from the top.
---@return NvimDiff.FileEntry?
function Review:next_unviewed(from)
  local order = self.view.tree.order
  local start = 0
  for i, e in ipairs(order) do
    if e == from then
      start = i
      break
    end
  end
  for step = 1, #order do
    local e = order[(start + step - 1) % #order + 1]
    if e.viewed ~= "viewed" then
      return e
    end
  end
  return nil
end

--- Whether the review is still open.
---@return boolean
function Review:is_valid()
  return not self.closed and self.view:is_valid()
end

--- Mark a file viewed on GitHub, then show the next file that is not viewed.
---@param entry? NvimDiff.FileEntry Defaults to `target()`.
---@return boolean ok False when there was no file or GitHub refused.
function Review:mark_viewed(entry)
  entry = entry or self:target()
  if not self:is_valid() or not entry then
    return false
  end
  local ok, err = viewed_mod.mark(self.pr, entry.path)
  if not ok then
    log.error("cannot mark %s viewed: %s", entry.path, msg(err))
    return false
  end
  self.view:set_viewed(entry, "viewed")
  local next_entry = self:next_unviewed(entry)
  if next_entry then
    self.view:select(next_entry)
  else
    log.warn("all %d files viewed", #self.view.list.entries)
  end
  return true
end

--- Clear a file's viewed mark on GitHub. The cursor stays where it is.
---@param entry? NvimDiff.FileEntry Defaults to `target()`.
---@return boolean ok
function Review:unmark_viewed(entry)
  entry = entry or self:target()
  if not self:is_valid() or not entry then
    return false
  end
  local ok, err = viewed_mod.unmark(self.pr, entry.path)
  if not ok then
    log.error("cannot clear the viewed mark on %s: %s", entry.path, msg(err))
    return false
  end
  self.view:set_viewed(entry, "unviewed")
  return true
end

-- Writing comments ------------------------------------------------------------------------

--- A GitHub error as the comment split shows it.
---@param err? NvimDiff.GitHub.Error
---@return string
local function post_error(err)
  if not err then
    return "unknown error"
  end
  if err.kind == "rate_limited" and err.retry_after then
    return ("%s (rate limited; try again in %d s)"):format(err.message, err.retry_after)
  end
  return err.message
end

--- The comment split already open for this review, brought back into view. Only one draft
--- is written at a time, so a second comment key never replaces unsent text.
---@return boolean open
function Review:resume_draft()
  local c = self.compose
  if not c or not c:is_open() then
    self.compose = nil
    return false
  end
  c:show()
  log.warn("finish or cancel this comment first")
  return true
end

---@param header string
---@param post fun(text: string): NvimDiff.GitHub.PostedComment?, NvimDiff.GitHub.Error?
---@return NvimDiff.Compose
function Review:open_compose(header, post)
  local c
  c = compose.open({
    header = header,
    on_submit = function(text)
      local posted, err = post(text)
      if not posted then
        return false, post_error(err)
      end
      -- It is on GitHub now: a redraw that fails must not leave the split open to be
      -- posted a second time.
      local ok, redraw_err = pcall(self.show_posted, self, posted)
      if not ok then
        log.error("comment posted, but redrawing the threads failed: %s", tostring(redraw_err))
      end
      return true
    end,
    on_done = function()
      if self.compose == c then
        self.compose = nil
      end
    end,
  })
  self.compose = c
  return c
end

--- Start a new comment on the lines of the diff pane the cursor is in: the cursor's line,
--- or `range` (buffer lines, from a visual selection). The old pane takes comments too.
---@param range? { first: integer, last: integer }
---@return NvimDiff.Compose? compose Nil when there is nothing to comment on, or a draft is open.
function Review:comment(range)
  if not self:is_valid() or self:resume_draft() then
    return nil
  end
  local view, entry = self.view, self.view.current
  if not entry or not view.file or view.file:is_closed() then
    log.warn("no diff showing to comment on")
    return nil
  end
  local win = api.nvim_get_current_win()
  local bl = api.nvim_win_get_cursor(win)[1]
  local target, why =
    comment_mod.target(view.file, entry.path, win, range and range.first or bl, range and range.last or bl)
  if not target then
    log.warn("cannot comment here: %s", why)
    return nil
  end
  return self:open_compose(comment_mod.header(target), function(text)
    return comments_mod.create(self.pr, {
      path = target.path,
      side = target.side,
      line = target.line,
      start_side = target.start_side,
      start_line = target.start_line,
      body = text,
    })
  end)
end

--- Start a reply to the thread on the cursor's line. With threads on both sides of a
--- side-by-side row, the one on the cursor's pane; with several still, the user picks.
---@return boolean started False when there is no thread here, or a draft is open.
function Review:reply()
  if not self:is_valid() or self:resume_draft() then
    return false
  end
  local tv = self.view.thread_view
  local here = tv and not tv.detached and tv:at_cursor() or {}
  local side = self.view.file and self.view.file:cursor().side
  local own = vim.tbl_filter(function(t)
    return (t.side or "new") == side
  end, here)
  local list = #own > 0 and own or here
  list = vim.tbl_filter(function(t)
    return t.can_reply
  end, list)
  if #list == 0 then
    log.warn(#here > 0 and "you cannot reply to this thread" or "no comment thread on this line")
    return false
  end
  local function start(thread)
    if not thread or self:resume_draft() then
      return
    end
    self:open_compose(comment_mod.reply_header(thread), function(text)
      return comments_mod.reply(self.pr, thread, text)
    end)
  end
  if #list == 1 then
    start(list[1])
  else
    vim.ui.select(list, {
      prompt = "Reply to which thread?",
      format_item = function(t)
        return comment_mod.reply_header(t, 60)
      end,
    }, start)
  end
  return true
end

--- Redraw the threads after a post: refetched from GitHub, the only source of truth, with
--- the thread holding the new comment expanded. When the refetch fails, the comment is
--- added to what is already showing, and the user told.
---@param posted NvimDiff.GitHub.PostedComment
function Review:show_posted(posted)
  if not self:is_valid() then
    return
  end
  local view = self.view
  local list, err = threads_mod.fetch(self.pr.target, self.number)
  if not list then
    log.warn("comment posted, but the threads could not be reloaded: %s", msg(err))
    list = view.threads or {}
    local parent
    for _, t in ipairs(list) do
      for _, c in ipairs(t.comments) do
        if posted.in_reply_to and c.database_id == posted.in_reply_to then
          parent = t
        end
      end
    end
    if parent then
      table.insert(parent.comments, posted)
    else
      list[#list + 1] = comment_mod.thread_of(posted)
    end
  end
  view.thread_state = view.thread_state or require("nvim-diff.review.threadview").new_state()
  for _, t in ipairs(list) do
    for _, c in ipairs(t.comments) do
      if c.id == posted.id then
        view.thread_state.expanded[t.id] = true
      end
    end
  end
  view:set_threads(list)
end

--- Wipe every buffer on a file inside the worktree: the files are about to be deleted.
function Review:wipe_buffers()
  local root = path.real(self.path) or self.path
  local modified = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and not name:find("^%a[%w+.-]*://") and path.is_under(path.normalize(name), root) then
      if vim.bo[buf].modified then
        modified[#modified + 1] = path.relative(name, root)
      end
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if #modified > 0 then
    log.warn("PR #%d review ended; unsaved changes discarded in %s", self.number, table.concat(modified, ", "))
  end
end

--- End the review: close its view and tabpage, wipe buffers on the worktree's files and
--- remove the worktree. Idempotent.
---@param opts? { windows?: boolean } `windows = false` leaves windows and buffers alone.
function Review:close(opts)
  local windows = not (opts and opts.windows == false)
  if self.closed then
    return
  end
  self.closed = true
  if by_number[self.number] == self then
    by_number[self.number] = nil
  end
  for _, unsubscribe in ipairs(self.unsubscribe) do
    unsubscribe()
  end
  pcall(api.nvim_del_augroup_by_id, self.augroup)

  if windows and self.compose then
    local kept = self.compose:orphan()
    self.compose = nil
    if kept then
      log.warn("PR #%d review ended with a comment not posted; its text is kept in %s", self.number, kept)
    end
  end
  if windows then
    local tab = self.view.tab
    if not self.view.closed then
      pcall(self.view.close, self.view)
    end
    -- The last tabpage survives its view; take it back out of the worktree.
    if api.nvim_tabpage_is_valid(tab) then
      api.nvim_win_call(api.nvim_tabpage_get_win(tab), function()
        pcall(vim.cmd.tcd, vim.fn.fnameescape(self.cwd))
      end)
    end
    self:wipe_buffers()
  end
  local ok, err = worktree.remove(self.repo, self.number)
  if not ok then
    log.error("cannot remove PR #%d's worktree %s: %s", self.number, self.path, msg(err))
  end
end

--- `:NvimDiffPR <number>`.
---@param arg string `42` or `#42`.
function M.command(arg)
  local number = tonumber((vim.trim(arg or ""):gsub("^#", "")))
  if not number then
    vim.notify("nvim-diff: :NvimDiffPR takes a PR number", vim.log.levels.ERROR)
    return
  end
  api.nvim_echo({ { ("nvim-diff: opening PR #%d…"):format(number) } }, false, {})
  vim.cmd.redraw()
  local ok, err = pcall(M.open, { number = number })
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

return M
