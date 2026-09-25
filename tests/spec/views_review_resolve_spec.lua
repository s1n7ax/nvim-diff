local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")
local gitrepo = require("tests.gitrepo")
local prremote = require("tests.prremote")
local repo_mod = require("nvim-diff.git.repo")
local review_mod = require("nvim-diff.views.review")
local thread_mod = require("nvim-diff.review.thread")

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
    url = "u",
    viewerDidAuthor = author == "me",
    replyTo = vim.NIL,
  }
end

---@param id string
---@param line integer
---@param resolved boolean
---@param comments table[]
local function gql_thread(id, line, resolved, comments)
  return {
    id = id,
    path = "a.txt",
    line = line,
    startLine = vim.NIL,
    originalLine = line,
    originalStartLine = vim.NIL,
    diffSide = "RIGHT",
    startDiffSide = vim.NIL,
    isResolved = resolved,
    isOutdated = false,
    isCollapsed = false,
    subjectType = "LINE",
    viewerCanReply = true,
    viewerCanResolve = not resolved,
    viewerCanUnresolve = resolved,
    resolvedBy = resolved and { login = "me" } or vim.NIL,
    comments = { pageInfo = { hasNextPage = false, endCursor = vim.NIL }, nodes = comments },
  }
end

--- GitHub's threads of PR #7, as they stand after what the flags say happened: PRRT_1 on
--- L1 (alice, unresolved until `resolved`), PRRT_3 on L3 (resolved), and PRRT_2 on L2 once
--- a comment was `posted`.
---@param posted boolean
---@param replied boolean
---@param resolved boolean
---@return string
local function threads_json(posted, replied, resolved)
  local first = { gql_comment("PRRC_1", "101", "alice", "why?") }
  if replied then
    first[2] = gql_comment("PRRC_reply", "203", "me", "done")
  end
  local nodes = { gql_thread("PRRT_1", 1, resolved, first) }
  if posted then
    nodes[#nodes + 1] = gql_thread("PRRT_2", 2, false, { gql_comment("PRRC_new", "202", "me", "posted text") })
  end
  nodes[#nodes + 1] = gql_thread("PRRT_3", 3, true, { gql_comment("PRRC_3", "301", "bob", "old news") })
  return vim.json.encode({
    data = {
      repository = {
        pullRequest = { reviewThreads = { pageInfo = { hasNextPage = false, endCursor = vim.NIL }, nodes = nodes } },
      },
    },
  })
end

---@param id string
---@param resolved boolean
---@param mutation string
local function mutation_json(id, resolved, mutation)
  return vim.json.encode({
    data = {
      [mutation] = {
        thread = {
          id = id,
          isResolved = resolved,
          viewerCanResolve = not resolved,
          viewerCanUnresolve = resolved,
          resolvedBy = resolved and { login = "me" } or vim.NIL,
        },
      },
    },
  })
end

---@class Test.ResolveStub
---@field dir string Holds the marker files: `posted`, `replied`, `resolved`, `down`.
---@field calls fun(): string[]

--- A `gh` for PR #7 whose threads follow what was posted and resolved (marker files), and
--- whose thread reads fail while `<dir>/down` exists.
---@param fixture Test.PRRemote
---@param opts? { fail_resolve?: boolean }
---@return string bin
---@return Test.ResolveStub stub
local function stub(fixture, opts)
  opts = opts or {}
  local dir = vim.fn.tempname() .. "-resolve"
  vim.fn.mkdir(dir, "p")
  for _, p in ipairs({ false, true }) do
    for _, r in ipairs({ false, true }) do
      for _, x in ipairs({ false, true }) do
        local name = ("%s/threads-%s%s%s.json"):format(dir, p and "p" or "", r and "r" or "", x and "x" or "")
        local fd = assert(io.open(name, "w"))
        fd:write(threads_json(p, r, x))
        fd:close()
      end
    end
  end
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
            nodes = { { path = "a.txt", viewerViewedState = "UNVIEWED" } },
          },
        },
      },
    },
  })
  local posted = vim.json.encode({
    id = 202,
    node_id = "PRRC_new",
    body = "posted text",
    user = { login = "me" },
    created_at = "2026-09-25T10:00:00Z",
    html_url = "u",
    path = "a.txt",
    line = 2,
    side = "RIGHT",
    in_reply_to_id = vim.NIL,
  })
  local replied = vim.json.encode({
    id = 203,
    node_id = "PRRC_reply",
    body = "done",
    user = { login = "me" },
    created_at = "2026-09-25T10:00:00Z",
    html_url = "u",
    path = "a.txt",
    line = 1,
    side = "RIGHT",
    in_reply_to_id = 101,
  })
  local refused = '{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}'
  local resolve_arm = opts.fail_resolve and answer("200 OK", refused)
    or ("touch '%s/resolved'; %s"):format(dir, answer("200 OK", mutation_json("PRRT_1", true, "resolveReviewThread")))
  local bin, calls = ghstub.new(table.concat({
    "  *unresolveReviewThread*)",
    ("    %s; exit 0 ;;"):format(answer("200 OK", mutation_json("PRRT_3", false, "unresolveReviewThread"))),
    "  *resolveReviewThread*)",
    ("    %s; exit 0 ;;"):format(resolve_arm),
    "  *comments/101/replies*)",
    ("    touch '%s/replied'; %s; exit 0 ;;"):format(dir, answer("201 Created", replied)),
    "  *pulls/7/comments*)",
    ("    touch '%s/posted'; %s; exit 0 ;;"):format(dir, answer("201 Created", posted)),
    "  *reviewThreads*)",
    ("    cd '%s'"):format(dir),
    ("    if [ -f down ]; then %s; exit 0; fi"):format(answer("502 Bad Gateway", '{"message":"down"}')),
    "    f=threads-$([ -f posted ] && echo p)$([ -f replied ] && echo r)$([ -f resolved ] && echo x).json",
    "    printf 'HTTP/2.0 200 OK\\n\\n'; cat \"$f\"; exit 0 ;;",
    "  *viewerViewedState*)",
    ("    %s; exit 0 ;;"):format(answer("200 OK", files)),
    "  *headRefOid*)",
    ("    %s; exit 0 ;;"):format(answer("200 OK", pr)),
  }, "\n"))
  return bin, { dir = dir, calls = calls }
end

---@param calls fun(): string[]
---@param needle string Plain text.
---@return string[]
local function matching(calls, needle)
  return vim.tbl_filter(function(c)
    return c:find(needle, 1, true) ~= nil
  end, calls())
end

---@param review NvimDiff.Review
---@param id string
---@return NvimDiff.GitHub.Thread?
local function thread(review, id)
  for _, th in ipairs(review.view.threads) do
    if th.id == id then
      return th
    end
  end
  return nil
end

--- The thread lines the new pane shows.
---@param review NvimDiff.Review
---@return NvimDiff.VirtLine[]
local function drawn(review)
  local out = {}
  local buf = review.view.file.scene.bufs.new
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      if thread_mod.text(vl):find(thread_mod.COLLAPSED, 1, true) then
        out[#out + 1] = vl
      end
    end
  end
  return out
end

describe("views review resolve", function()
  local home_tab, real_confirm, dirs

  before_each(function()
    config.reset()
    home_tab = api.nvim_get_current_tabpage()
    real_confirm = compose.confirm
    dirs = {}
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
      if api.nvim_buf_get_name(buf):find("^nvim%-diff://comment/") then
        api.nvim_buf_delete(buf, { force = true })
      end
    end
    for _, d in ipairs(dirs) do
      vim.fn.delete(d, "rf")
    end
    config.reset()
    ghstub.cleanup()
    prremote.cleanup()
    gitrepo.cleanup()
  end)

  --- A review of PR #7 showing a.txt side by side (a1 a2 a3 → a1 A2 a3), cursor in the new
  --- pane on file line `lnum`.
  ---@param opts? { fail_resolve?: boolean, lnum?: integer, config?: table }
  ---@return NvimDiff.Review review
  ---@return Test.ResolveStub gh
  local function setup(opts)
    opts = opts or {}
    local fixture = prremote.new()
    local bin, gh = stub(fixture, opts)
    dirs[#dirs + 1] = gh.dir
    config.setup(vim.tbl_deep_extend("force", { github = { bin = bin }, log = { level = "off" } }, opts.config or {}))
    local repo = assert(repo_mod.discover(fixture.repo.root))
    local review = review_mod.open({ number = 7, repo = repo })
    api.nvim_set_current_win(review.view.file.scene.wins.new)
    review.view.file:jump("new", opts.lnum or 1)
    return review, gh
  end

  it("resolves the thread on the cursor's line and keeps it drawn, dimmed with a ✓", function()
    local review, gh = setup()
    expect.eq(true, review:resolve())
    local sent = matching(gh.calls, "resolveReviewThread")
    expect.eq(1, #sent)
    expect.matches("%-f id=PRRT_1", sent[1])
    expect.falsy(sent[1]:find("resolutionReason", 1, true))

    local th = assert(thread(review, "PRRT_1"))
    expect.eq(true, th.resolved)
    expect.eq("me", th.resolved_by)
    expect.eq(true, th.can_unresolve)
    expect.eq(1, #review.view.thread_view:at_cursor(), "still on screen")
    local found = false
    for _, vl in ipairs(drawn(review)) do
      local text = thread_mod.text(vl)
      if text:find("why?", 1, true) then
        found = text:find("^╶▸ ✓ alice") ~= nil
        -- Dimmed, but for the green badge where the pane has room for it.
        for _, chunk in ipairs(vl) do
          if not chunk[1]:match("^%s*$") and chunk[2] ~= "NvimDiffThreadBadgeResolved" then
            expect.eq("NvimDiffThreadResolved", chunk[2])
          end
        end
      end
    end
    expect.truthy(found, vim.inspect(vim.tbl_map(thread_mod.text, drawn(review))))
    expect.eq(0, #matching(gh.calls, "reviewThreads") - 1, "no refetch: GitHub's answer is used")
  end)

  it("keeps a thread just resolved on screen while resolved threads are hidden", function()
    local review = setup({ config = { threads = { resolved = "hide" } } })
    expect.eq(true, review:resolve())
    expect.eq(1, #review.view.thread_view:at_cursor(), "shown until the mode flips")
    review.view.file:jump("new", 3)
    expect.eq(0, #review.view.thread_view:at_cursor(), "an older resolved thread stays hidden")
    review.view.thread_view:toggle_resolved()
    review.view.thread_view:toggle_resolved()
    review.view.file:jump("new", 1)
    expect.eq(0, #review.view.thread_view:at_cursor(), "hidden after the mode flips back")
  end)

  it("unresolves a resolved thread", function()
    local review, gh = setup({ lnum = 3 })
    expect.eq(false, review:resolve(), "nothing unresolved here")
    expect.eq(true, review:unresolve())
    expect.matches("%-f id=PRRT_3", matching(gh.calls, "unresolveReviewThread")[1])
    expect.eq(false, assert(thread(review, "PRRT_3")).resolved)
    expect.eq(1, #review.view.thread_view:at_cursor())
    expect.eq(false, review:unresolve(), "nothing resolved here any more")
  end)

  it("leaves the thread as it was when GitHub refuses", function()
    local review = setup({ fail_resolve = true })
    expect.eq(true, review:resolve())
    expect.eq(false, assert(thread(review, "PRRT_1")).resolved)
  end)

  it("has nothing to resolve on a line with no thread", function()
    local review, gh = setup({ lnum = 2 })
    expect.eq(false, review:resolve())
    expect.eq(false, review:reply_and_resolve())
    expect.eq(nil, review.compose)
    expect.eq(0, #matching(gh.calls, "resolveReviewThread"))
  end)

  it("replies in the comment split, then resolves", function()
    local review, gh = setup()
    expect.eq(true, review:reply_and_resolve())
    local c = assert(review.compose)
    expect.matches("Reply to alice on a%.txt L1: why%? — then resolve", vim.wo[c.win].winbar)
    api.nvim_buf_set_lines(c.buf, 0, -1, false, { "done" })
    expect.eq(true, c:submit())

    local sent = gh.calls()
    local reply_at, resolve_at
    for i, call in ipairs(sent) do
      reply_at = reply_at or (call:find("comments/101/replies", 1, true) and i)
      resolve_at = resolve_at or (call:find("resolveReviewThread", 1, true) and i)
    end
    expect.truthy(reply_at and resolve_at and reply_at < resolve_at, "reply first, then resolve")
    expect.falsy(api.nvim_buf_is_valid(c.buf))
    local th = assert(thread(review, "PRRT_1"))
    expect.eq(2, #th.comments, "refetched")
    expect.eq(true, th.resolved)
    expect.eq(true, review.view.thread_state.expanded.PRRT_1)
  end)

  it("keeps the reply and closes the split when the resolve after it fails", function()
    local review = setup({ fail_resolve = true })
    review:reply_and_resolve()
    local c = assert(review.compose)
    api.nvim_buf_set_lines(c.buf, 0, -1, false, { "done" })
    expect.eq(true, c:submit(), "the reply is public: nothing left to post")
    expect.falsy(api.nvim_buf_is_valid(c.buf))
    local th = assert(thread(review, "PRRT_1"))
    expect.eq(2, #th.comments)
    expect.eq(false, th.resolved)
  end)

  it("resolves a thread built from a post once GitHub's threads can be read again", function()
    local review, gh = setup({ lnum = 2 })
    local c = assert(review:comment())
    api.nvim_buf_set_lines(c.buf, 0, -1, false, { "posted text" })
    vim.fn.writefile({}, gh.dir .. "/down")
    expect.eq(true, c:submit())
    local built = assert(thread(review, "PRRC_new"))
    expect.eq(true, built.local_only)

    -- Still unreachable: it cannot be resolved, and GitHub is not asked to.
    review.view.file:jump("new", 2)
    expect.eq(true, review:resolve())
    expect.eq(0, #matching(gh.calls, "resolveReviewThread"))
    expect.eq(false, built.resolved)

    -- Back: the threads are read again, and the real thread is resolved by its own id.
    vim.fn.delete(gh.dir .. "/down")
    review.view.file:jump("new", 2)
    expect.eq(true, review:resolve())
    local sent = matching(gh.calls, "resolveReviewThread")
    expect.eq(1, #sent)
    expect.matches("%-f id=PRRT_2", sent[1])
    expect.eq(nil, thread(review, "PRRC_new"), "the local stand-in is gone")
    expect.eq(true, review.view.thread_state.expanded.PRRT_2, "still expanded under its real id")
  end)

  it("maps the resolve keys in both panes", function()
    local review = setup()
    for _, buf in ipairs(review.view.file:bufs()) do
      local n = {}
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        n[m.desc or ""] = m.lhs
      end
      expect.truthy(n["nvim-diff: resolve the comment thread on this line"])
      expect.truthy(n["nvim-diff: reply to the comment thread on this line, then resolve it"])
      expect.truthy(n["nvim-diff: unresolve the comment thread on this line"])
    end
  end)
end)
