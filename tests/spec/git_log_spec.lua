local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local gitrepo = require("tests.gitrepo")
local job = require("nvim-diff.core.job")
local log = require("nvim-diff.git.log")
local repo_mod = require("nvim-diff.git.repo")

--- `subject: S path, S old -> path` per commit.
---@param commits NvimDiff.Git.Commit[]
---@return string[]
local function summary(commits)
  local out = {}
  for _, c in ipairs(commits) do
    local parts = {}
    for _, f in ipairs(c.files) do
      parts[#parts + 1] = f.status .. " " .. (f.oldpath and (f.oldpath .. " -> ") or "") .. f.path
    end
    out[#out + 1] = c.subject .. ": " .. table.concat(parts, ", ")
  end
  return out
end

--- first: f.txt, d/x; second: f.txt edited, d/y added; rename: f.txt -> g.txt;
--- side (branch): g.txt edited; main2: d/x edited; then a merge of side.
---@return Test.Repo
local function fixture()
  local r = gitrepo.new()
  r:write("f.txt", "a\nb\n")
  r:write("d/x", "x\n")
  r:commit("first")
  r:write("f.txt", "a\nB\n")
  r:write("d/y", "y\n")
  r:commit("second")
  r:git({ "mv", "f.txt", "g.txt" })
  r:commit("rename")
  r:git({ "checkout", "-q", "-b", "side" })
  r:write("g.txt", "a\nB\ns\n")
  r:commit("side")
  r:git({ "checkout", "-q", "main" })
  r:write("d/x", "m\n")
  r:commit("main2")
  r:git({ "merge", "-q", "--no-edit", "side" })
  return r
end

describe("git log", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  it("walks the whole repository newest first, merges against their first parent once", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local commits = assert(log.commits(repo, {}))
    expect.eq({
      "Merge branch 'side': M g.txt",
      "main2: M d/x",
      "side: M g.txt",
      "rename: R f.txt -> g.txt",
      "second: A d/y, M f.txt",
      "first: A d/x, A f.txt",
    }, summary(commits))
    local merge = commits[1]
    expect.eq({ r:oid("HEAD^1"), r:oid("HEAD^2") }, merge.parents)
    expect.eq(r:oid("HEAD"), merge.oid)
    expect.eq("nvim-diff", merge.author)
    expect.eq("test@nvim-diff.invalid", merge.email)
    expect.truthy(merge.time > 1e9)
    expect.eq({}, commits[6].parents)
    local second = commits[5].files
    expect.eq({ 1, 0 }, { second[1].additions, second[1].deletions })
    expect.eq({ 1, 1 }, { second[2].additions, second[2].deletions })
  end)

  it("follows a single file across a rename, and stops there when told not to", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    expect.eq({
      "Merge branch 'side': M g.txt",
      "side: M g.txt",
      "rename: R f.txt -> g.txt",
      "second: M f.txt",
      "first: A f.txt",
    }, summary(assert(log.commits(repo, { path = "g.txt", follow = true }))))
    expect.eq({
      "Merge branch 'side': M g.txt",
      "side: M g.txt",
      "rename: A g.txt",
    }, summary(assert(log.commits(repo, { path = "g.txt" }))))
  end)

  it("limits a directory's history to the files under it", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    expect.eq({
      "main2: M d/x",
      "second: A d/y",
      "first: A d/x",
    }, summary(assert(log.commits(repo, { path = "d" }))))
  end)

  it("takes odd path names literally, followed or not", function()
    local r = gitrepo.new()
    r:write('sp ace/é "q"*.txt', "1\n")
    r:write("sp ace/other.txt", "2\n")
    r:commit("one")
    r:git({ "mv", 'sp ace/é "q"*.txt', "sp ace/[x].txt" })
    r:commit("two")
    local repo = assert(repo_mod.discover(r.root))
    expect.eq(
      { 'two: R sp ace/é "q"*.txt -> sp ace/[x].txt', 'one: A sp ace/é "q"*.txt' },
      summary(assert(log.commits(repo, { path = "sp ace/[x].txt", follow = true })))
    )
  end)

  it("reassembles records however the output is chunked", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local out = assert(require("nvim-diff.git.cmd").output(r.root, assert(log.args({}, true))))
    for _, size in ipairs({ 1, 2, 7, 64 }) do
      local pos = 1
      local batches, commits = 0, {}
      log.consume(repo, {}, function()
        if pos > #out then
          return nil
        end
        local chunk = out:sub(pos, pos + size - 1)
        pos = pos + size
        return chunk
      end, function(batch)
        batches = batches + 1
        vim.list_extend(commits, batch)
      end)
      expect.eq(6, #commits, "chunk size " .. size)
      expect.eq("first", commits[6].subject)
      if size == 1 then
        expect.eq(6, batches)
      end
    end
  end)

  it("re-reads a record that came back without stats, and skips one that never has them", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local out = assert(require("nvim-diff.git.cmd").output(r.root, assert(log.args({ max_count = 2 }, true))))
    -- Cut the numstat half off the first record ("Merge branch 'side'": one M g.txt).
    local raw_end = out:find("g.txt\0", 1, true) + #"g.txt\0" - 1
    local second = out:find(log.MARKER, 3, true)
    local broken = out:sub(1, raw_end) .. out:sub(second)
    local bogus = log.MARKER
      .. string.rep("f", 40)
      .. "\0\0x\0x@y\0"
      .. "1\0bogus\0\0\n:100644 100644 "
      .. string.rep("1", 40)
      .. " "
      .. string.rep("2", 40)
      .. " M\0nope\0"

    local warnings = {}
    local warn = require("nvim-diff.core.log").warn
    require("nvim-diff.core.log").warn = function(msg, ...)
      warnings[#warnings + 1] = msg:format(...)
    end
    local commits = {}
    local fed = false
    local ok, err = pcall(log.consume, repo, {}, function()
      if fed then
        return nil
      end
      fed = true
      return broken .. bogus
    end, function(batch)
      vim.list_extend(commits, batch)
    end)
    require("nvim-diff.core.log").warn = warn
    expect.truthy(ok, err)
    expect.eq({ "Merge branch 'side': M g.txt", "main2: M d/x" }, summary(commits))
    expect.eq(1, commits[1].files[1].additions)
    expect.eq({ "skipping commit ffffffffffff: git gave no file stats for it" }, warnings)
  end)

  it("streams inside a task, and cancelling the task stops git", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local seen = 0
    local task = job.task(function()
      return log.walk(repo, {}, function(batch)
        seen = seen + #batch
      end)
    end)
    expect.eq(0, seen) -- nothing yet: the task yielded to the event loop
    expect.truthy(task:wait(5000))
    expect.eq(6, seen)
    expect.eq({ true }, task.values)

    -- A task cancelled mid-walk unwinds with Cancelled.
    task = job.task(function()
      return log.walk(repo, {}, function() end)
    end)
    task:cancel()
    expect.truthy(task:wait(5000))
    expect.truthy(job.is_cancelled(task.err))
  end)

  it("reports an unborn branch and bad revisions as bad_revision", function()
    local r = gitrepo.new()
    local repo = assert(repo_mod.discover(r.root))
    local commits, err = log.commits(repo, {})
    expect.eq(nil, commits)
    expect.eq("bad_revision", err.kind)
    r:write("a", "a\n")
    r:commit("a")
    expect.eq("bad_revision", select(2, log.commits(repo, { rev = "nope" })).kind)
    expect.eq("bad_revision", select(2, log.commits(repo, { rev = "--all" })).kind)
    -- A path with no history is an empty list, not an error.
    expect.eq({}, log.commits(repo, { path = "missing.txt" }))
  end)

  it("tells a file from a directory from the whole repository, on disk or only in HEAD", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    expect.eq("repo", log.kind(repo, nil))
    expect.eq("repo", log.kind(repo, ""))
    expect.eq("file", log.kind(repo, "g.txt"))
    expect.eq("dir", log.kind(repo, "d"))
    r:delete("d/x")
    r:delete("d/y")
    expect.eq("dir", log.kind(repo, "d"))
    expect.eq("file", log.kind(repo, "f.txt"))
  end)
end)

describe("git log -L", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  --- `subject: path Loldstart,oldcount->newstart,newcount [<- oldpath]` per commit.
  ---@param commits NvimDiff.Git.LineCommit[]
  ---@return string[]
  local function line_summary(commits)
    local out = {}
    for _, c in ipairs(commits) do
      local h = c.hunks[1]
      local text = ("%s L%d,%d->%d,%d"):format(c.path, h.old_start, h.old_count, h.new_start, h.new_count)
      if c.oldpath then
        text = text .. " <- " .. c.oldpath
      end
      out[#out + 1] = c.subject .. ": " .. text
    end
    return out
  end

  it("follows the range's content across a plain rename with no help from --follow", function()
    -- Line 2 ("b"/"B") is edited in `second`, survives the rename untouched, and is
    -- never touched again — so the walk (queried at g.txt, HEAD) skips straight past the
    -- rename and the merge to the two commits that actually touched it, reporting them
    -- under the path they had at the time.
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local commits = assert(log.line_commits(repo, { path = "g.txt", start = 2, stop = 2 }))
    expect.eq({
      "second: f.txt L2,1->2,1",
      "first: f.txt L0,0->2,1",
    }, line_summary(commits))
    expect.eq(r:oid("HEAD~3"), commits[1].oid)
    expect.eq({ r:oid("HEAD~4") }, commits[1].parents)
    expect.eq("nvim-diff", commits[1].author)
    expect.eq("test@nvim-diff.invalid", commits[1].email)
    expect.truthy(commits[1].time > 1e9)
    expect.eq(1, commits[1].additions)
    expect.eq(1, commits[1].deletions)
    expect.eq(false, commits[1].added)
    expect.eq({}, commits[2].parents)
    expect.eq(true, commits[2].added)
    expect.eq(1, commits[2].additions)
    expect.eq(0, commits[2].deletions)
  end)

  it("reports a same-commit rename and content change as an ordinary rename", function()
    local r = gitrepo.new()
    r:write("a.txt", "1\n2\n3\n")
    r:commit("first")
    r:git({ "mv", "a.txt", "b.txt" })
    r:write("b.txt", "1\nTWO\n3\n")
    r:commit("rename and edit")
    local repo = assert(repo_mod.discover(r.root))
    local commits = assert(log.line_commits(repo, { path = "b.txt", start = 2, stop = 2 }))
    expect.eq({
      "rename and edit: b.txt L2,1->2,1 <- a.txt",
      "first: a.txt L0,0->2,1",
    }, line_summary(commits))
  end)

  it("stops with no earlier content at the walk's true root", function()
    local r = gitrepo.new()
    r:write("a.txt", "1\n2\n3\n")
    r:commit("first")
    local repo = assert(repo_mod.discover(r.root))
    local commits = assert(log.line_commits(repo, { path = "a.txt", start = 1, stop = 3 }))
    expect.eq(1, #commits)
    expect.eq(true, commits[1].added)
    expect.eq({}, commits[1].parents)
  end)

  it("streams inside a task, and cancelling the task stops git", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    local seen = 0
    local task = job.task(function()
      return log.walk_line(repo, { path = "g.txt", start = 2, stop = 2 }, function(batch)
        seen = seen + #batch
      end)
    end)
    expect.truthy(task:wait(5000))
    expect.eq(2, seen)
    expect.eq({ true }, task.values)

    task = job.task(function()
      return log.walk_line(repo, { path = "g.txt", start = 2, stop = 2 }, function() end)
    end)
    task:cancel()
    expect.truthy(task:wait(5000))
    expect.truthy(job.is_cancelled(task.err))
  end)

  it("rejects a bad revision, a bad range or a missing path", function()
    local r = fixture()
    local repo = assert(repo_mod.discover(r.root))
    expect.eq(
      "bad_revision",
      select(2, log.line_commits(repo, { path = "g.txt", start = 1, stop = 1, rev = "nope" })).kind
    )
    expect.eq("invalid", select(2, log.line_commits(repo, { path = "g.txt", start = 3, stop = 1 })).kind)
    expect.eq("invalid", select(2, log.line_commits(repo, { path = "", start = 1, stop = 1 })).kind)
  end)
end)
