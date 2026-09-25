local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")
local gitrepo = require("tests.gitrepo")
local prremote = require("tests.prremote")
local repo_mod = require("nvim-diff.git.repo")
local review_mod = require("nvim-diff.views.review")

local api = vim.api

--- A case arm answering `status` with a one-line JSON body (no single quote in it).
---@param status string
---@param body string
---@return string
local function answer(status, body)
  return ("printf 'HTTP/2.0 %s\\n\\n%%s\\n' '%s'"):format(status, body)
end

---@param id string
---@param db string
---@param author string
---@param body string
local function gql_comment(id, db, author, body)
  return {
    id = id,
    fullDatabaseId = db,
    author = { login = author },
    body = body,
    outdated = false,
    createdAt = "2026-09-01T12:00:00Z",
    url = "https://github.com/octocat/hello-world/pull/7#discussion_r" .. db,
    viewerDidAuthor = author == "me",
    replyTo = vim.NIL,
  }
end

---@param id string
---@param line integer
---@param side string
---@param comments table[]
---@param path? string
local function gql_thread(id, line, side, comments, path)
  return {
    id = id,
    path = path or "a.txt",
    line = line,
    startLine = vim.NIL,
    originalLine = line,
    originalStartLine = vim.NIL,
    diffSide = side,
    startDiffSide = vim.NIL,
    isResolved = false,
    isOutdated = false,
    isCollapsed = false,
    subjectType = "LINE",
    viewerCanReply = true,
    viewerCanResolve = true,
    viewerCanUnresolve = false,
    resolvedBy = vim.NIL,
    comments = { pageInfo = { hasNextPage = false, endCursor = vim.NIL }, nodes = comments },
  }
end

---@param nodes table[]
local function threads_body(nodes)
  return vim.json.encode({
    data = {
      repository = {
        pullRequest = { reviewThreads = { pageInfo = { hasNextPage = false, endCursor = vim.NIL }, nodes = nodes } },
      },
    },
  })
end

local POSTED = vim.json.encode({
  id = 202,
  node_id = "PRRC_new",
  body = "posted text",
  user = { login = "me" },
  created_at = "2026-09-25T10:00:00Z",
  html_url = "https://github.com/octocat/hello-world/pull/7#discussion_r202",
  path = "a.txt",
  line = 2,
  side = "RIGHT",
  start_line = vim.NIL,
  start_side = vim.NIL,
  in_reply_to_id = vim.NIL,
})

local REPLIED = vim.json.encode({
  id = 203,
  node_id = "PRRC_reply",
  body = "agreed",
  user = { login = "me" },
  created_at = "2026-09-25T10:00:00Z",
  html_url = "u",
  path = "a.txt",
  line = 1,
  side = "RIGHT",
  in_reply_to_id = 101,
})

local EDITED = vim.json.encode({
  id = 301,
  node_id = "PRRC_mine",
  body = "my better take",
  user = { login = "me" },
  path = "a.txt",
  line = 2,
  side = "RIGHT",
})

local FILE_POSTED = vim.json.encode({
  id = 401,
  node_id = "PRRC_file",
  body = "split this file",
  user = { login = "me" },
  path = "b.txt",
  line = vim.NIL,
  side = vim.NIL,
  subject_type = "file",
})

--- My own comment, on a.txt line 2.
---@param body? string
local function mine(body)
  return gql_thread("PRRT_3", 2, "RIGHT", { gql_comment("PRRC_mine", "301", "me", body or "my first take") })
end

--- A `gh` for PR #7 whose threads gain the posted comment once a POST went through (a
--- marker file records it). `before` and `after` replace the thread lists served before and
--- after a write; edits (`PATCH`) and deletes (`DELETE`) of any comment go through too.
---@param fixture Test.PRRemote
---@param opts? { fail_post?: boolean, fail_refetch?: boolean, before?: table[], after?: table[] }
---@return string bin
---@return fun(): string[] calls
local function stub(fixture, opts)
  opts = opts or {}
  local marker = vim.fn.tempname() .. "-posted"
  local pr = vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          id = "PR_kwDO7",
          number = 7,
          title = "Change things",
          url = "https://github.com/octocat/hello-world/pull/7",
          state = "OPEN",
          isDraft = false,
          isCrossRepository = false,
          maintainerCanModify = false,
          headRefName = "feature",
          headRefOid = fixture.head,
          baseRefName = "main",
          baseRefOid = fixture.base,
        },
      },
    },
  })
  local files = vim.json.encode({
    data = {
      repository = {
        pullRequest = {
          files = {
            pageInfo = { hasNextPage = false },
            nodes = {
              { path = "a.txt", viewerViewedState = "UNVIEWED" },
              { path = "b.txt", viewerViewedState = "UNVIEWED" },
              { path = "c.txt", viewerViewedState = "UNVIEWED" },
            },
          },
        },
      },
    },
  })
  local first = gql_thread("PRRT_1", 1, "RIGHT", { gql_comment("PRRC_1", "101", "alice", "why?") })
  local before = threads_body(opts.before or { first })
  local after = threads_body(opts.after or {
    gql_thread("PRRT_1", 1, "RIGHT", {
      gql_comment("PRRC_1", "101", "alice", "why?"),
      gql_comment("PRRC_reply", "203", "me", "agreed"),
    }),
    gql_thread("PRRT_2", 2, "RIGHT", { gql_comment("PRRC_new", "202", "me", "posted text") }),
  })
  local refused = '{"message":"Validation Failed","errors":["line must be part of the diff"]}'
  local after_arm = opts.fail_refetch and answer("502 Bad Gateway", '{"message":"down"}') or answer("200 OK", after)
  return ghstub.new(table.concat({
    "  *--method\\ DELETE*pulls/comments/*)",
    ("    touch '%s'; printf 'HTTP/2.0 204 No Content\\n\\n'; exit 0 ;;"):format(marker),
    "  *--method\\ PATCH*pulls/comments/*)",
    ("    touch '%s'; %s; exit 0 ;;"):format(marker, answer("200 OK", EDITED)),
    "  *subject_type=file*)",
    ("    touch '%s'; %s; exit 0 ;;"):format(marker, answer("201 Created", FILE_POSTED)),
    "  *comments/101/replies*)",
    ("    touch '%s'; %s; exit 0 ;;"):format(marker, answer("201 Created", REPLIED)),
    "  *pulls/7/comments*)",
    opts.fail_post and ("    %s; exit 0 ;;"):format(answer("422 Unprocessable Entity", refused))
      or ("    touch '%s'; %s; exit 0 ;;"):format(marker, answer("201 Created", POSTED)),
    "  *reviewThreads*)",
    ("    if [ -f '%s' ]; then %s; else %s; fi; exit 0 ;;"):format(marker, after_arm, answer("200 OK", before)),
    "  *viewerViewedState*)",
    ("    %s; exit 0 ;;"):format(answer("200 OK", files)),
    "  *headRefOid*)",
    ("    %s; exit 0 ;;"):format(answer("200 OK", pr)),
  }, "\n"))
end

---@param review NvimDiff.Review
---@param p string
---@return NvimDiff.FileEntry
local function find(review, p)
  for _, e in ipairs(review.view.list.entries) do
    if e.path == p then
      return e
    end
  end
  error("no entry " .. p)
end

---@param calls fun(): string[]
---@param pattern string
---@return string? call The last call matching.
local function last_call(calls, pattern)
  local found
  for _, c in ipairs(calls()) do
    if c:find(pattern) then
      found = c
    end
  end
  return found
end

describe("views review comments", function()
  local home_tab, real_confirm

  before_each(function()
    config.reset()
    home_tab = api.nvim_get_current_tabpage()
    real_confirm = compose.confirm
  end)

  after_each(function()
    vim.cmd.stopinsert()
    compose.confirm = function()
      return true
    end
    for _, tab in ipairs(api.nvim_list_tabpages()) do
      local r = review_mod.get(tab)
      if r then
        if r.compose and r.compose:is_open() then
          r.compose:close()
        end
        r:close()
      end
    end
    compose.confirm = real_confirm
    if api.nvim_tabpage_is_valid(home_tab) then
      api.nvim_set_current_tabpage(home_tab)
    end
    vim.cmd("silent! tabonly")
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if
        api.nvim_buf_get_name(buf):find("^nvim%-diff://comment/")
        or api.nvim_buf_get_name(buf):find("^nvim%-diff://verdict/")
      then
        api.nvim_buf_delete(buf, { force = true })
      end
    end
    config.reset()
    ghstub.cleanup()
    prremote.cleanup()
    gitrepo.cleanup()
  end)

  --- A review of PR #7 showing a.txt side by side (a1 a2 a3 → a1 A2 a3), cursor in `side`'s
  --- pane on file line `lnum`.
  ---@param opts? { fail_post?: boolean, fail_refetch?: boolean, side?: NvimDiff.Side, lnum?: integer }
  ---@return NvimDiff.Review review
  ---@return fun(): string[] calls
  local function setup(opts)
    opts = opts or {}
    local fixture = prremote.new()
    local bin, calls = stub(fixture, opts)
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    local repo = assert(repo_mod.discover(fixture.repo.root))
    local review = review_mod.open({ number = 7, repo = repo })
    review.view:select(find(review, "a.txt"))
    local side = opts.side or "new"
    api.nvim_set_current_win(review.view.file.scene.wins[side])
    review.view.file:jump(side, opts.lnum or 2)
    return review, calls
  end

  ---@param review NvimDiff.Review
  ---@param lines string[]
  local function type_text(review, lines)
    api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, lines)
  end

  it("posts a new comment on the new pane's line and shows its thread expanded", function()
    local review, calls = setup()
    local pane = api.nvim_get_current_win()
    local c = assert(review:comment())
    expect.eq(c.win, api.nvim_get_current_win())
    expect.matches("Comment on a%.txt L2", vim.wo[c.win].winbar)
    type_text(review, { "posted text" })
    expect.eq(true, c:submit())

    local sent = assert(last_call(calls, "%-%-method POST"))
    expect.matches("repos/octocat/hello%-world/pulls/7/comments %-f body=posted text ", sent)
    expect.matches("%-f path=a%.txt ", sent)
    expect.matches("%-F line=2 %-f side=RIGHT$", sent)
    expect.matches("%-f commit_id=" .. review.pr.head.oid, sent)

    expect.falsy(api.nvim_buf_is_valid(c.buf), "the split is gone")
    expect.eq(nil, review.compose)
    expect.eq(pane, api.nvim_get_current_win(), "focus is back in the pane")
    expect.eq(2, #review.view.threads, "refetched from GitHub")
    expect.eq(true, review.view.thread_state.expanded.PRRT_2)
  end)

  it("comments on the old pane as LEFT", function()
    local review, calls = setup({ side = "old" })
    local c = assert(review:comment())
    expect.matches("Comment on a%.txt old L2", vim.wo[c.win].winbar)
    type_text(review, { "why delete a2?" })
    c:submit()
    expect.matches("%-F line=2 %-f side=LEFT$", assert(last_call(calls, "%-%-method POST")))
  end)

  it("comments on a visual selection with the comment key", function()
    local review, calls = setup({ lnum = 1 })
    api.nvim_feedkeys("Vj\\cc", "mx", false)
    local c = assert(review.compose)
    expect.matches("Comment on a%.txt L1–2", vim.wo[c.win].winbar)
    type_text(review, { "these two" })
    c:submit()
    local sent = assert(last_call(calls, "%-%-method POST"))
    expect.matches("%-F line=2 %-f side=RIGHT %-F start_line=1 %-f start_side=RIGHT$", sent)
  end)

  it("keeps the split, the text and the error when GitHub refuses the comment", function()
    local review, calls = setup({ fail_post = true })
    local c = assert(review:comment())
    type_text(review, { "precious words" })
    expect.eq(false, c:submit())
    expect.truthy(api.nvim_win_is_valid(c.win))
    expect.eq({ "precious words" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
    local marks = api.nvim_buf_get_extmarks(c.buf, compose.ns, 0, -1, { details = true })
    expect.matches("Validation Failed: line must be part of the diff", marks[1][4].virt_lines[1][1][1])
    expect.eq(1, #review.view.threads)
    local fetches = vim.tbl_filter(function(call)
      return call:find("reviewThreads", 1, true) ~= nil
    end, calls())
    expect.eq(1, #fetches, "no refetch")
  end)

  it("replies to the thread on the cursor's line", function()
    local review, calls = setup({ lnum = 1 })
    expect.eq(true, review:reply())
    local c = assert(review.compose)
    expect.matches("Reply to alice on a%.txt L1: why%?", vim.wo[c.win].winbar)
    type_text(review, { "agreed" })
    expect.eq(true, c:submit())
    local sent = assert(last_call(calls, "%-%-method POST"))
    expect.matches("repos/octocat/hello%-world/pulls/7/comments/101/replies %-f body=agreed$", sent)
    expect.eq(2, #review.view.threads[1].comments)
    expect.eq(true, review.view.thread_state.expanded.PRRT_1)
  end)

  it("has no reply where there is no thread", function()
    local review = setup({ lnum = 3 })
    expect.eq(false, review:reply())
    expect.eq(nil, review.compose)
  end)

  it("shows the posted comment even when the threads cannot be refetched", function()
    local review = setup({ fail_refetch = true })
    local c = assert(review:comment())
    type_text(review, { "posted text" })
    expect.eq(true, c:submit())
    expect.eq(2, #review.view.threads)
    local added = review.view.threads[2]
    expect.eq("PRRC_new", added.comments[1].id)
    expect.eq(2, added.line)
    expect.eq(false, added.can_resolve, "not a real thread id")
    expect.eq(true, review.view.thread_state.expanded[added.id])
  end)

  it("writes one draft at a time: the comment key brings the open one back", function()
    local review = setup()
    local c = assert(review:comment())
    type_text(review, { "first" })
    api.nvim_set_current_win(review.view.file.scene.wins.new)
    expect.eq(nil, review:comment())
    expect.eq(c, review.compose)
    expect.eq(c.win, api.nvim_get_current_win())
    expect.eq(false, review:reply())
  end)

  it("keeps an unsent draft's text when the review ends", function()
    local review = setup()
    local c = assert(review:comment())
    type_text(review, { "not yet sent" })
    local buf = c.buf
    review:close()
    expect.truthy(api.nvim_buf_is_valid(buf))
    expect.eq(true, vim.bo[buf].buflisted)
    expect.eq({ "not yet sent" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("puts a suggestion block of the commented line into the split", function()
    local review = setup()
    local c = assert(review:comment())
    vim.cmd.stopinsert()
    expect.eq(true, c:insert_suggestion())
    expect.eq({ "```suggestion", "A2", "```" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
  end)

  it("has no suggestion for the old pane", function()
    local review = setup({ side = "old" })
    local c = assert(review:comment())
    expect.eq(false, c:insert_suggestion())
    expect.eq({ "" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
  end)

  describe("own comments", function()
    local real_confirm_delete

    before_each(function()
      real_confirm_delete = review_mod.confirm_delete
    end)

    after_each(function()
      review_mod.confirm_delete = real_confirm_delete
    end)

    ---@param opts? table
    local function setup_mine(opts)
      local first = gql_thread("PRRT_1", 1, "RIGHT", { gql_comment("PRRC_1", "101", "alice", "why?") })
      return setup(vim.tbl_extend("force", {
        before = { first, mine() },
        after = { first, mine("my better take") },
      }, opts or {}))
    end

    it("edits one in the split, starting from its text", function()
      local review, calls = setup_mine()
      expect.eq(true, review:edit())
      local c = assert(review.compose)
      expect.matches("Edit your comment on a%.txt L2", vim.wo[c.win].winbar)
      expect.eq({ "my first take" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
      vim.cmd.stopinsert()
      expect.eq(true, c:insert_suggestion(), "a suggestion works in an edit too")
      type_text(review, { "my better take" })
      expect.eq(true, c:submit())
      local sent = assert(last_call(calls, "%-%-method PATCH"))
      expect.matches("repos/octocat/hello%-world/pulls/comments/301 %-f body=my better take$", sent)
      local t3 = review.view.threads[2]
      expect.eq("my better take", t3.comments[1].body, "refetched")
      expect.eq(true, review.view.thread_state.expanded.PRRT_3)
    end)

    it("shows the edit even when the threads cannot be refetched", function()
      local review = setup_mine({ fail_refetch = true })
      review:edit()
      type_text(review, { "my better take" })
      expect.eq(true, review.compose:submit())
      expect.eq(2, #review.view.threads)
      expect.eq("my better take", review.view.threads[2].comments[1].body)
      expect.eq("me", review.view.threads[2].comments[1].author)
    end)

    it("does not post an edit that empties the comment", function()
      local review, calls = setup_mine()
      review:edit()
      local c = review.compose
      type_text(review, { "" })
      expect.eq(false, c:submit())
      expect.truthy(c:is_open())
      expect.eq(nil, last_call(calls, "%-%-method PATCH"))
    end)

    it("only offers the user's own comments", function()
      local review, calls = setup_mine({ lnum = 1 })
      expect.eq(false, review:edit())
      expect.eq(nil, review.compose)
      expect.eq(false, review:delete())
      expect.eq(nil, last_call(calls, "%-%-method DELETE"))
    end)

    it("deletes one only after asking", function()
      local first = gql_thread("PRRT_1", 1, "RIGHT", { gql_comment("PRRC_1", "101", "alice", "why?") })
      local review, calls = setup_mine({ after = { first } })
      local asked
      review_mod.confirm_delete = function(prompt)
        asked = prompt
        return false
      end
      expect.eq(false, review:delete())
      expect.matches("Delete your comment on a%.txt L2%?", asked)
      expect.matches("my first take", asked)
      expect.eq(nil, last_call(calls, "%-%-method DELETE"))
      expect.eq(2, #review.view.threads)

      review_mod.confirm_delete = function()
        return true
      end
      expect.eq(true, review:delete())
      expect.matches("%-%-method DELETE repos/octocat/hello%-world/pulls/comments/301$", last_call(calls, "DELETE"))
      expect.eq(1, #review.view.threads, "refetched")
    end)

    it("drops a deleted comment's thread when the threads cannot be refetched", function()
      local review = setup_mine({ fail_refetch = true })
      review_mod.confirm_delete = function()
        return true
      end
      expect.eq(true, review:delete())
      expect.eq(
        { "PRRT_1" },
        vim.tbl_map(function(th)
          return th.id
        end, review.view.threads)
      )
    end)

    it("edits and deletes from the side list too", function()
      local file_thread =
        gql_thread("PRRT_F", vim.NIL, "RIGHT", { gql_comment("PRRC_mine", "301", "me", "on the file") }, "b.txt")
      file_thread.subjectType = "FILE"
      file_thread.diffSide = vim.NIL
      local review = setup({ before = { file_thread }, after = { file_thread } })
      review.view:toggle_thread_list()
      local list = assert(review.view.thread_list)
      local descs = {}
      for _, m in ipairs(api.nvim_buf_get_keymap(list.buf, "n")) do
        descs[m.desc or ""] = m.lhs
      end
      expect.truthy(descs["nvim-diff: edit your comment in this thread"])
      expect.truthy(descs["nvim-diff: delete your comment in this thread"])
      api.nvim_set_current_win(list.win)
      local lines = api.nvim_buf_get_lines(list.buf, 0, -1, false)
      for i, l in ipairs(lines) do
        if l:find("on the file", 1, true) then
          api.nvim_win_set_cursor(list.win, { i, 0 })
        end
      end
      expect.eq(true, review:edit())
      local c = assert(review.compose)
      expect.matches("Edit your comment on the file b%.txt", vim.wo[c.win].winbar)
      expect.eq({ "on the file" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
      vim.cmd.stopinsert()
      expect.eq(false, c:insert_suggestion(), "a file comment has no lines")
    end)
  end)

  it("posts a file-level comment from the file panel and opens the side list on it", function()
    local file_thread =
      gql_thread("PRRT_F", vim.NIL, "RIGHT", { gql_comment("PRRC_file", "401", "me", "split this file") }, "b.txt")
    file_thread.subjectType = "FILE"
    file_thread.diffSide = vim.NIL
    local first = gql_thread("PRRT_1", 1, "RIGHT", { gql_comment("PRRC_1", "101", "alice", "why?") })
    local review, calls = setup({ after = { first, file_thread } })
    local panel = review.view.panel
    api.nvim_set_current_win(panel.win)
    for i, l in ipairs(api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
      if l:find("b.txt", 1, true) then
        api.nvim_win_set_cursor(panel.win, { i, 0 })
      end
    end
    api.nvim_feedkeys("\\cc", "mx", false)
    local c = assert(review.compose)
    expect.matches("Comment on the file b%.txt", vim.wo[c.win].winbar)
    type_text(review, { "split this file" })
    expect.eq(true, c:submit())

    local sent = assert(last_call(calls, "subject_type"))
    expect.matches("%-%-method POST repos/octocat/hello%-world/pulls/7/comments ", sent)
    expect.matches("%-f path=b%.txt ", sent)
    expect.matches("%-f subject_type=file$", sent)
    expect.falsy(sent:find("line=", 1, true))

    local list = assert(review.view.thread_list)
    expect.truthy(list:is_open())
    local text = table.concat(api.nvim_buf_get_lines(list.buf, 0, -1, false), "\n")
    expect.matches("file comment", text)
    expect.matches("split this file", text)
    expect.eq(panel.win, api.nvim_get_current_win(), "focus back in the panel")
  end)

  it("shows a file-level comment in the side list even when the threads cannot be refetched", function()
    local review = setup({ fail_refetch = true })
    local c = assert(review:file_comment(find(review, "b.txt")))
    type_text(review, { "split this file" })
    expect.eq(true, c:submit())
    local list = assert(review.view.thread_list)
    local text = table.concat(api.nvim_buf_get_lines(list.buf, 0, -1, false), "\n")
    expect.matches("split this file", text)
  end)

  it("keeps an unsent verdict summary when the review ends", function()
    local verdict = require("nvim-diff.review.verdict")
    local review = setup()
    local v = verdict.open(review, "COMMENT")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "summary so far" })
    review:close()
    expect.truthy(api.nvim_buf_is_valid(v.buf))
    expect.eq(true, vim.bo[v.buf].buflisted)
    expect.eq({ "summary so far" }, api.nvim_buf_get_lines(v.buf, 0, -1, false))
  end)

  it("maps the comment keys in both panes, in normal and visual mode", function()
    local review = setup()
    for _, buf in ipairs(review.view.file:bufs()) do
      local n, x = {}, {}
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        n[m.desc or ""] = true
      end
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "x")) do
        x[m.desc or ""] = true
      end
      expect.truthy(n["nvim-diff: comment on this line on GitHub"])
      expect.truthy(n["nvim-diff: reply to the comment thread on this line"])
      expect.truthy(x["nvim-diff: comment on the selected lines on GitHub"])
    end
  end)
end)
