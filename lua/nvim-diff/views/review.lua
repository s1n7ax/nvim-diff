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
--- pane, or on a visual selection, or — in the file panel — on the whole file under the
--- cursor; `keymaps.comment.reply` answers the thread on the cursor's line;
--- `keymaps.comment.edit` reopens one of the user's own comments there in the split, and
--- `keymaps.comment.delete` deletes one after asking. Edit and delete work in the side list
--- too, on the thread under its cursor. After every change the threads are refetched; a new
--- comment's thread shows expanded, and a file-level one opens the side list.
---
--- Threads are resolved on GitHub from the cursor's line: `keymaps.threads.resolve` at once,
--- `reply_resolve` after a reply written in the same split, `unresolve` to undo. The thread
--- is redrawn from GitHub's answer and stays on screen, dimmed with a ✓ — even while
--- resolved threads are hidden, until the resolved mode is next flipped.
---
--- While the review is open it checks GitHub every `github.sync_interval_ms`, and at once on
--- `keymaps.review.sync` (`review/sync.lua`): new commits, a new base branch and a merge or
--- close are announced and marked in the panel. What GitHub has now is kept as
--- `review.latest`; what the review shows (`review.pr`) is unchanged by a check.
---
--- Every check redraws the threads, in place, when anything about them changed: new
--- threads, replies, edits and resolves by others show at once. Threads are fitted to the
--- head shown (`review/live.lua`): one on code newer than that is held back (`review.held`)
--- and counted in the panel until the new code is applied. A check that started before a
--- comment was posted, edited, deleted or resolved here is not drawn: it may predate it.

local comment_mod = require("nvim-diff.review.comment")
local comments_mod = require("nvim-diff.github.comments")
local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")
local event = require("nvim-diff.core.event")
local fetch = require("nvim-diff.git.fetch")
local live = require("nvim-diff.review.live")
local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")
local pr_mod = require("nvim-diff.github.pr")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local revparse = require("nvim-diff.git.revparse")
local sync_mod = require("nvim-diff.review.sync")
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
---@field remote string The remote the PR's commits are fetched from.
---@field number integer
--- The PR as the review shows it: its head is the diffed and checked-out commit, and what
--- every comment is posted against. A sync never changes it.
---@field pr NvimDiff.GitHub.PR
--- The PR as GitHub last answered — at open, then on every sync. Its `head.oid` or
--- `base.ref` differing from `pr`'s is new code the review does not show (`stale`).
---@field latest? NvimDiff.GitHub.Snapshot
---@field sync NvimDiff.ReviewSync
--- Where each thread drawn hangs in the head shown, so it keeps its place once GitHub's head
--- moves on (`review/live.lua`).
---@field anchors NvimDiff.ThreadAnchors
--- Threads GitHub has on code newer than the head shown, as last read: not drawn, counted in
--- the panel. What applying the new code shows.
---@field held NvimDiff.GitHub.Thread[]
--- Bumped by every change to the threads made here: a write to GitHub, or a redraw after
--- one. A sync that started before carries an older value, and is not drawn.
---@field threads_rev integer
---@field drawn? string `live.fingerprint` of the threads drawn, so an unchanged sync skips them.
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

  local snap
  snap, err = threads_mod.snapshot(pr.target, number)
  if not snap then
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
    remote = remote,
    number = number,
    pr = pr,
    latest = snap,
    anchors = live.anchors(pr.head.oid),
    held = {},
    threads_rev = 0,
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
  self.sync = sync_mod.new(self)
  self:show_threads(snap)
  self:trap()
  self:map_keys(view.panel.buf)
  self:map_keys(view.note_buf)
  self:map_panel_comment_keys(view.panel.buf)
  view.on_thread_list = function(list)
    self:map_own_comment_keys(list.buf)
  end

  local first = self:next_unviewed(nil) or view.tree.order[1]
  if first then
    view:select(first)
  end
  self.sync:start()
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
  api.nvim_create_autocmd("ExitPre", {
    group = self.augroup,
    callback = function()
      -- Before `VimLeavePre`, where session plugins save the tabpage cwd; a session
      -- restored into the removed worktree fails its `:tcd`.
      self:leave_worktree(self.view.tab)
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
      self:map_resolve_keys(buf)
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
  end, "Comments: Comment on line")
  map("x", keys.add, function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    self:comment({ first = first, last = last })
  end, "Comments: Comment on selection")
  map("n", keys.reply, function()
    self:reply()
  end, "Comments: Reply")
  self:map_own_comment_keys(buf)
end

--- Map the keys that edit and delete the user's own comments in `buf`: a diff pane, or the
--- side list.
---@param buf integer
function Review:map_own_comment_keys(buf)
  local keys = config.get().keymaps.comment
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.edit, function()
    self:edit()
  end, "Comments: Edit my comment")
  map(keys.delete, function()
    self:delete()
  end, "Comments: Delete my comment")
end

--- Map the file-level comment key in the file panel `buf`.
---@param buf integer
function Review:map_panel_comment_keys(buf)
  local lhs = config.get().keymaps.comment.add
  if type(lhs) == "string" then
    vim.keymap.set("n", lhs, function()
      self:file_comment()
    end, { buffer = buf, nowait = true, desc = "nvim-diff: Comments: Comment on file" })
  end
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
  end, "Review: Mark viewed, go to next")
  map(keys.unmark_viewed, function()
    self:unmark_viewed()
  end, "Review: Unmark viewed")
  map(keys.sync, function()
    self:sync_now()
  end, "Review: Check GitHub for updates")
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

--- What GitHub has that the review does not show: new commits, or the PR retargeted to
--- another base branch. A push to the base branch alone is not here — the diff is from the
--- merge-base, which it does not move.
---@return { head?: string, base?: string }? stale `head`: GitHub's head commit, when not the
---one shown; `base`: GitHub's base branch, when not the one shown. Nil when nothing is new.
function Review:stale()
  local latest = self.latest
  if not latest then
    return nil
  end
  local head = latest.head.oid ~= self.pr.head.oid and latest.head.oid or nil
  local base = latest.base.ref ~= self.pr.base.ref and latest.base.ref or nil
  if head or base then
    return { head = head, base = base }
  end
  return nil
end

--- Check GitHub for new commits, a new base branch or a merge now.
function Review:sync_now()
  if self:is_valid() then
    self.sync:now()
  end
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

---@class NvimDiff.ReviewComposeOpts
---@field lines? string[] Initial text (an edited comment's body).
---@field suggestion? NvimDiff.ComposeSuggestion
---@field what? string What happened, for messages. Default `"comment posted"`.
---@field after? fun(posted: NvimDiff.GitHub.PostedComment) Once the threads are redrawn.

---@param header string
---@param post fun(text: string): NvimDiff.GitHub.PostedComment?, NvimDiff.GitHub.Error?
---@param opts? NvimDiff.ReviewComposeOpts
---@return NvimDiff.Compose
function Review:open_compose(header, post, opts)
  opts = opts or {}
  local what = opts.what or "comment posted"
  local c
  c = compose.open({
    header = header,
    lines = opts.lines,
    suggestion = opts.suggestion,
    on_submit = function(text)
      self:touch_threads()
      local posted, err = post(text)
      if not posted then
        return false, post_error(err)
      end
      -- It is on GitHub now: a redraw that fails must not leave the split open to be
      -- posted a second time.
      local ok, redraw_err = pcall(function()
        self:show_posted(posted, what)
        if opts.after then
          opts.after(posted)
        end
      end)
      if not ok then
        log.error("%s, but redrawing the threads failed: %s", what, tostring(redraw_err))
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
  end, { suggestion = comment_mod.suggestion_for_target(view.file, target) })
end

--- Start a file-level comment on the file row under the file panel's cursor (or `entry`).
--- Once posted it shows in the side list, which opens.
---@param entry? NvimDiff.FileEntry
---@return NvimDiff.Compose? compose Nil when there is no file there, or a draft is open.
function Review:file_comment(entry)
  if not self:is_valid() or self:resume_draft() then
    return nil
  end
  if not entry then
    local row = self.view.panel:cursor_row()
    entry = row and row.kind ~= "dir" and row.entry or nil
  end
  if not entry then
    log.warn("no file under the cursor to comment on")
    return nil
  end
  local p = entry.path
  return self:open_compose(comment_mod.file_header(p), function(text)
    return comments_mod.create_file(self.pr, p, text)
  end, {
    suggestion = { reason = "a file comment has no lines" },
    after = function()
      if self:is_valid() then
        self.view:open_thread_list()
      end
    end,
  })
end

--- The suggestion for a reply to, or an edit in, `thread`.
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.ComposeSuggestion
function Review:thread_suggestion(thread)
  local view = self.view
  return comment_mod.suggestion_for_thread(view.file, view.current and view.current.path, thread)
end

--- The user's own comments where the cursor is: in the thread under the side list's cursor,
--- or in the threads on the cursor's line of a diff pane (the cursor's pane first).
---@return { thread: NvimDiff.GitHub.Thread, comment: NvimDiff.GitHub.Comment }[] own
---@return boolean any Whether there is any thread there at all.
function Review:own_here()
  local view = self.view
  local list = view.thread_list
  if list and list:is_open() and api.nvim_get_current_win() == list.win then
    local t = list:thread_at_cursor()
    return t and comment_mod.own({ t }) or {}, t ~= nil
  end
  local tv = view.thread_view
  local here = tv and not tv.detached and tv:at_cursor() or {}
  local side = view.file and not view.file:is_closed() and view.file:cursor().side
  local mine = comment_mod.own(vim.tbl_filter(function(t)
    return (t.side or "new") == side
  end, here))
  if #mine == 0 then
    mine = comment_mod.own(here)
  end
  return mine, #here > 0
end

--- Call `fn` with the one comment of `own`, or the one the user picks from several.
---@param own { thread: NvimDiff.GitHub.Thread, comment: NvimDiff.GitHub.Comment }[]
---@param verb string
---@param fn fun(pick: { thread: NvimDiff.GitHub.Thread, comment: NvimDiff.GitHub.Comment })
local function choose(own, verb, fn)
  if #own == 1 then
    fn(own[1])
    return
  end
  vim.ui.select(own, {
    prompt = verb .. " which of your comments?",
    format_item = function(x)
      return comment_mod.label(x.thread, x.comment)
    end,
  }, function(pick)
    if pick then
      fn(pick)
    end
  end)
end

---@param any boolean
local function none_here(any)
  log.warn(any and "none of the comments here is yours" or "no comment thread here")
end

--- Edit one of the user's own comments where the cursor is, in the comment split.
---@return boolean started False when there is none, or a draft is open.
function Review:edit()
  if not self:is_valid() or self:resume_draft() then
    return false
  end
  local own, any = self:own_here()
  if #own == 0 then
    none_here(any)
    return false
  end
  choose(own, "Edit", function(pick)
    if not self:is_valid() or self:resume_draft() then
      return
    end
    local c = pick.comment
    self:open_compose(comment_mod.edit_header(pick.thread), function(text)
      return comments_mod.edit(self.pr, c, text)
    end, {
      lines = vim.split(c.body, "\n", { plain = true }),
      suggestion = self:thread_suggestion(pick.thread),
      what = "comment edited",
    })
  end)
  return true
end

--- Asks whether to delete a comment. Replaceable, so specs can answer without a prompt.
---@param prompt string
---@return boolean delete
function M.confirm_delete(prompt)
  return vim.fn.confirm(prompt, "&Delete\n&Keep", 2) == 1
end

--- Delete one of the user's own comments where the cursor is, after asking.
---@return boolean deleted False when nothing was deleted — or not yet, when several of the
---user's comments are here and a picker asks which.
function Review:delete()
  if not self:is_valid() then
    return false
  end
  local own, any = self:own_here()
  if #own == 0 then
    none_here(any)
    return false
  end
  local deleted = false
  choose(own, "Delete", function(pick)
    local c = pick.comment
    local prompt = ("Delete your comment on %s?\n%s"):format(comment_mod.where(pick.thread), comment_mod.excerpt(c, 60))
    if not self:is_valid() or not M.confirm_delete(prompt) then
      return
    end
    self:touch_threads()
    local ok, err = comments_mod.delete(self.pr, c)
    if not ok then
      log.error("comment not deleted: %s", post_error(err))
      return
    end
    deleted = true
    local redrawn, redraw_err = pcall(self.reload_threads, self, "comment deleted", function(list)
      for i = #list, 1, -1 do
        local t = list[i]
        t.comments = vim.tbl_filter(function(x)
          return x.id ~= c.id
        end, t.comments)
        if #t.comments == 0 then
          table.remove(list, i)
        end
      end
    end)
    if not redrawn then
      log.error("comment deleted, but redrawing the threads failed: %s", tostring(redraw_err))
    end
  end)
  return deleted
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
    end, { suggestion = self:thread_suggestion(thread) })
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

-- Live threads ----------------------------------------------------------------------------

--- A change to the threads is being made here: a sync already under way may have read
--- GitHub before it, so its threads are not drawn.
function Review:touch_threads()
  self.threads_rev = self.threads_rev + 1
end

--- The threads of a snapshot, fitted to the head the review shows (`review/live.lua`). The
--- ones on newer code become `held`.
---@param snap NvimDiff.GitHub.Snapshot
---@return NvimDiff.GitHub.Thread[] shown
function Review:fit_threads(snap)
  local head = self.pr.head.oid
  if self.anchors.head ~= head then
    self.anchors = live.anchors(head)
  end
  local current = snap.head.oid == head and snap.base.ref == self.pr.base.ref
  local shown, held = live.fit(snap.threads, self.anchors, current)
  self.held = held
  return shown
end

--- Draw the threads of a snapshot a sync (or the opening) read, unless they look the same
--- as the ones drawn. A thread others resolved stays drawn, dimmed, while resolved ones are
--- hidden, as one resolved here does. Skipped while a comment is being posted: the post
--- redraws the threads once GitHub has it.
---@param snap NvimDiff.GitHub.Snapshot
function Review:show_threads(snap)
  if not self:is_valid() or (self.compose and self.compose.posting) then
    return
  end
  local list = self:fit_threads(snap)
  local key = live.fingerprint(list)
  if key == self.drawn then
    return
  end
  local view = self.view
  local was = {}
  for _, t in ipairs(view.threads or {}) do
    was[t.id] = t.resolved
  end
  view.thread_state = view.thread_state or require("nvim-diff.review.threadview").new_state()
  local ts = view.thread_state
  for _, t in ipairs(list) do
    if t.resolved and was[t.id] == false then
      ts.kept = ts.kept or {}
      ts.kept[t.id] = true
    end
  end
  self.drawn = key
  view:set_threads(list)
end

--- Draw `list` after a change made here, whatever was drawn before.
---@param list NvimDiff.GitHub.Thread[] Fitted already.
function Review:draw_threads(list)
  self:touch_threads()
  self.drawn = live.fingerprint(list)
  self.view:set_threads(list)
  self.sync:show()
end

--- Redraw the threads after a change: refetched from GitHub, the only source of truth. When
--- the refetch fails, `patch` applies the change to what is already showing instead, and
--- the user is told.
---@param what string What happened, `comment posted`.
---@param patch fun(list: NvimDiff.GitHub.Thread[])
---@param expand? string Node id of a comment whose thread to show expanded.
function Review:reload_threads(what, patch, expand)
  if not self:is_valid() then
    return
  end
  local view = self.view
  local snap, err = threads_mod.snapshot(self.pr.target, self.number)
  local list
  if snap then
    list = self:fit_threads(snap)
  else
    log.warn("%s, but the threads could not be reloaded: %s", what, msg(err))
    list = view.threads or {}
    patch(list)
  end
  view.thread_state = view.thread_state or require("nvim-diff.review.threadview").new_state()
  if expand then
    for _, t in ipairs(list) do
      for _, c in ipairs(t.comments) do
        if c.id == expand then
          view.thread_state.expanded[t.id] = true
        end
      end
    end
  end
  self:draw_threads(list)
end

--- Redraw the threads after a post or an edit, with the thread holding the comment
--- expanded. When the refetch fails, the comment is put into what is already showing.
---@param posted NvimDiff.GitHub.PostedComment
---@param what? string Default `"comment posted"`.
function Review:show_posted(posted, what)
  self:reload_threads(what or "comment posted", function(list)
    local parent
    for _, t in ipairs(list) do
      for i, c in ipairs(t.comments) do
        if c.id == posted.id then
          -- An edit: the comment is already here; only its text changed.
          t.comments[i] = vim.tbl_extend("force", c, { body = posted.body })
          return
        end
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
  end, posted.id)
end

-- Resolving threads -----------------------------------------------------------------------

--- Map the resolve keys in the diff pane buffer `buf`.
---@param buf integer
function Review:map_resolve_keys(buf)
  local keys = config.get().keymaps.threads
  local function map(lhs, fn, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "nvim-diff: " .. desc })
    end
  end
  map(keys.resolve, function()
    self:resolve()
  end, "Threads: Resolve")
  map(keys.reply_resolve, function()
    self:reply_and_resolve()
  end, "Threads: Reply and resolve")
  map(keys.unresolve, function()
    self:unresolve()
  end, "Threads: Unresolve")
end

--- Hand a thread on the cursor's line that `keep` accepts to `start`: the one on the
--- cursor's pane first, and with several still, the one the user picks.
---@param keep fun(t: NvimDiff.GitHub.Thread): boolean
---@param prompt string The picker's prompt.
---@param none string The warning when the line has threads but none that `keep` accepts.
---@param start fun(t?: NvimDiff.GitHub.Thread) Nil when the picker was dismissed.
---@return boolean found False when there is no such thread.
function Review:pick_thread(keep, prompt, none, start)
  local tv = self.view.thread_view
  local here = tv and not tv.detached and tv:at_cursor() or {}
  local file = self.view.file
  local side = file and not file:is_closed() and file:cursor().side
  local list = vim.tbl_filter(keep, here)
  local own = vim.tbl_filter(function(t)
    return (t.side or "new") == side
  end, list)
  if #own > 0 then
    list = own
  end
  if #list == 0 then
    if #here > 0 then
      log.warn(none)
    else
      local key = config.get().keymaps.threads.toggle_resolved
      if tv and tv.state.resolved == "hide" and type(key) == "string" then
        log.warn("no comment thread on this line (resolved ones are hidden; %s shows them)", key)
      else
        log.warn("no comment thread on this line")
      end
    end
    return false
  end
  if #list == 1 then
    start(list[1])
  else
    vim.ui.select(list, {
      prompt = prompt,
      format_item = function(t)
        return (comment_mod.reply_header(t, 60):gsub("^Reply to ", ""))
      end,
    }, start)
  end
  return true
end

--- `thread` with a GitHub thread id to resolve by. A thread drawn from a post alone, while
--- GitHub's threads could not be read back, has none: the threads are read again (and
--- redrawn) and the same thread, found by its first comment, is returned from that.
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.GitHub.Thread? thread
---@return string? why Why there is none.
function Review:with_thread_id(thread)
  if not thread.local_only then
    return thread
  end
  local snap, err = threads_mod.snapshot(self.pr.target, self.number)
  if not snap then
    local why = "it was drawn from your comment alone, as GitHub's threads could not be read back, "
      .. "so it has no thread id yet (%s)"
    return nil, why:format(msg(err))
  end
  local list = self:fit_threads(snap)
  local first = thread.comments[1]
  local found
  for _, t in ipairs(list) do
    for _, c in ipairs(t.comments) do
      if first and c.id == first.id then
        found = t
      end
    end
  end
  local state = self.view.thread_state
  if found and state and state.expanded[thread.id] ~= nil then
    state.expanded[found.id] = state.expanded[thread.id]
  end
  self:draw_threads(list)
  if not found then
    return nil, "GitHub no longer lists it"
  end
  return found
end

--- Record GitHub's answer on `thread`. A thread just resolved stays drawn while resolved
--- threads are hidden, so the resolve can be seen and undone.
---@param thread NvimDiff.GitHub.Thread
---@param state NvimDiff.GitHub.ResolvedState
function Review:apply_resolved(thread, state)
  threads_mod.apply(thread, state)
  local ts = self.view.thread_state
  if ts then
    ts.kept = ts.kept or {}
    ts.kept[thread.id] = state.resolved or nil
  end
end

--- Resolve (`resolved = true`) or unresolve `thread` on GitHub, then redraw the threads.
---@param thread NvimDiff.GitHub.Thread
---@param resolved boolean
---@return boolean ok
function Review:set_resolved(thread, resolved)
  if not self:is_valid() then
    return false
  end
  local verb = resolved and "resolve" or "unresolve"
  local real, why = self:with_thread_id(thread)
  if not real then
    log.error("cannot %s this thread: %s", verb, why)
    return false
  end
  if real.resolved == resolved then
    return true
  end
  if not (resolved and real.can_resolve or not resolved and real.can_unresolve) then
    log.warn("you cannot %s this thread", verb)
    return false
  end
  self:touch_threads()
  local state, err = (resolved and threads_mod.resolve or threads_mod.unresolve)(self.pr.target.host, real)
  if not state then
    log.error("cannot %s this thread: %s", verb, post_error(err))
    return false
  end
  self:apply_resolved(real, state)
  self:draw_threads(self.view.threads or {})
  return true
end

---@param t NvimDiff.GitHub.Thread
---@return boolean
local function resolvable(t)
  return not t.resolved and (t.can_resolve or t.local_only == true)
end

--- Resolve the thread on the cursor's line on GitHub.
---@return boolean found False when there is no thread here to resolve.
function Review:resolve()
  if not self:is_valid() then
    return false
  end
  return self:pick_thread(resolvable, "Resolve which thread?", "no thread on this line you can resolve", function(t)
    if t then
      self:set_resolved(t, true)
    end
  end)
end

--- Unresolve the resolved thread on the cursor's line on GitHub.
---@return boolean found False when there is no resolved thread here.
function Review:unresolve()
  if not self:is_valid() then
    return false
  end
  return self:pick_thread(
    function(t)
      return t.resolved and t.can_unresolve
    end,
    "Unresolve which thread?",
    "no resolved thread on this line you can unresolve",
    function(t)
      if t then
        self:set_resolved(t, false)
      end
    end
  )
end

--- Reply to the thread on the cursor's line in the comment split; posting the reply also
--- resolves the thread. The two are separate calls to GitHub: when the resolve fails, the
--- reply is already public, so the split closes and the failure is reported, never retried.
---@return boolean found False when there is no thread here to resolve, or a draft is open.
function Review:reply_and_resolve()
  if not self:is_valid() or self:resume_draft() then
    return false
  end
  local function keep(t)
    return t.can_reply and resolvable(t)
  end
  local none = "no thread on this line you can reply to and resolve"
  return self:pick_thread(keep, "Reply to and resolve which thread?", none, function(t)
    if not t or self:resume_draft() then
      return
    end
    local thread, why = self:with_thread_id(t)
    if not thread then
      log.error("cannot resolve this thread: %s", why)
      return
    end
    if thread.resolved or not (thread.can_reply and thread.can_resolve) then
      log.warn(thread.resolved and "this thread is already resolved" or "you cannot reply to and resolve this thread")
      return
    end
    self:open_compose(comment_mod.reply_header(thread) .. " — then resolve", function(text)
      local posted, err = comments_mod.reply(self.pr, thread, text)
      if not posted then
        return nil, err
      end
      local state, rerr = threads_mod.resolve(self.pr.target.host, thread)
      if state then
        self:apply_resolved(thread, state)
      else
        log.error("reply posted, but the thread could not be resolved: %s", post_error(rerr))
      end
      return posted
    end)
  end)
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

--- `:tcd` tabpage `tab` back to where the review was started, out of the worktree.
---@param tab integer
function Review:leave_worktree(tab)
  if api.nvim_tabpage_is_valid(tab) then
    api.nvim_win_call(api.nvim_tabpage_get_win(tab), function()
      pcall(vim.cmd.tcd, vim.fn.fnameescape(self.cwd))
    end)
  end
end

--- End the review: stop syncing, close its view and tabpage, wipe buffers on the worktree's
--- files and remove the worktree. Idempotent.
---@param opts? { windows?: boolean } `windows = false` leaves windows and buffers alone.
function Review:close(opts)
  local windows = not (opts and opts.windows == false)
  if self.closed then
    return
  end
  self.closed = true
  if self.sync then
    self.sync:close()
  end
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
    local kept = require("nvim-diff.review.verdict").orphan(self)
    if kept then
      log.warn("PR #%d review ended with its verdict not posted; the summary is kept in %s", self.number, kept)
    end
  end
  if windows then
    local tab = self.view.tab
    if not self.view.closed then
      pcall(self.view.close, self.view)
    end
    -- The last tabpage survives its view; take it back out of the worktree.
    self:leave_worktree(tab)
    self:wipe_buffers()
  else
    -- Leaving the cwd inside the removed worktree breaks `VimLeave` handlers that read it.
    self:leave_worktree(self.view.tab)
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
