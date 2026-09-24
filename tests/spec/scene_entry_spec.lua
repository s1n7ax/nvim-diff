local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local blob = require("nvim-diff.git.blob")
local entry = require("nvim-diff.scene.entry")
local files = require("nvim-diff.git.files")
local gitrepo = require("tests.gitrepo")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")

---@param path string
---@param oid? string
---@param oldpath? string
---@return NvimDiff.Git.FileChange
local function change(path, oid, oldpath)
  return {
    path = path,
    oldpath = oldpath,
    status = oldpath and "R" or "M",
    binary = false,
    additions = 1,
    deletions = 1,
    old_mode = "100644",
    new_mode = "100644",
    old_oid = "1111",
    new_oid = oid or "2222",
  }
end

---@param ops NvimDiff.EditOp[]
---@return string[]
local function show(ops)
  return vim.tbl_map(function(op)
    return op.op .. " " .. op.entry.path .. (op.entry.oldpath and (" <- " .. op.entry.oldpath) or "")
  end, ops)
end

describe("scene.entry list morph", function()
  it("inserts every entry of a new list", function()
    local list = entry.list({})
    expect.eq({ "insert a", "insert b" }, show(list:morph({ change("a"), change("b") })))
  end)

  it("keeps unchanged entries as the same objects, with their state", function()
    local list = entry.list({ change("a"), change("b"), change("c") })
    local a, b = list.entries[1], list.entries[2]
    a.viewed, b.forced = "viewed", true
    local ops = list:morph({ change("a"), change("b", "3333"), change("d") })
    expect.eq({ "delete c", "keep a", "update b", "insert d" }, show(ops))
    expect.truthy(list.entries[1] == a, "a was rebuilt")
    expect.truthy(list.entries[2] == b, "b was rebuilt")
    expect.eq("viewed", a.viewed)
    expect.eq(true, b.forced)
    expect.eq("3333", b.change.new_oid)
    expect.eq("2222", ops[3].previous.new_oid)
    expect.eq(
      { "a", "b", "d" },
      vim.tbl_map(function(e)
        return e.path
      end, list.entries)
    )
  end)

  it("keys on the old path too, so a rename to a different source is a new entry", function()
    local list = entry.list({ change("new", nil, "old1") })
    local ops = list:morph({ change("new", nil, "old2") })
    expect.eq({ "delete new <- old1", "insert new <- old2" }, show(ops))
  end)

  it("uses the stamp it is given to decide what changed", function()
    local n = 0
    local list = entry.list({ change("a") }, function(c)
      n = n + 1
      return c.path .. n
    end)
    expect.eq({ "update a" }, show(list:morph({ change("a") })))
  end)

  it("finds an entry's index", function()
    local list = entry.list({ change("a"), change("b") })
    expect.eq(2, list:index_of(list.entries[2]))
    expect.eq(nil, list:index_of({}))
  end)
end)

describe("scene.entry measure", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  it("defers exactly the files whose larger side is over the line limit", function()
    local r = gitrepo.new()
    r:write("small.txt", "a\nb\n")
    r:write("grows.txt", string.rep("x\n", 8))
    r:write("shrinks.txt", string.rep("y\n", 12))
    r:write("gone.txt", string.rep("g\n", 11))
    r:write("wide.txt", string.rep("0123456789", 20) .. "\n")
    local base = r:commit("base")
    r:write("small.txt", "a\nB\n")
    r:write("grows.txt", string.rep("x\n", 11))
    r:write("shrinks.txt", "y\n")
    r:delete("gone.txt")
    r:write("wide.txt", string.rep("0123456789", 20) .. "!\n")
    r:write("added.txt", string.rep("n\n", 20))
    r:write("untracked.txt", string.rep("u\n", 15))
    r:git({ "add", "added.txt" })

    local repo = assert(repo_mod.discover(r.root))
    local left, right = rev.commit(base), rev.worktree()
    local list = entry.list(assert(files.diff(repo, left, right)))
    entry.measure(repo, { left = left, right = right }, list.entries, 10)

    local got = {}
    for _, e in ipairs(list.entries) do
      got[e.path] = e.deferred and e.lines or false
    end
    expect.eq({
      ["small.txt"] = false,
      ["grows.txt"] = 11,
      ["shrinks.txt"] = 12,
      ["gone.txt"] = 11,
      ["wide.txt"] = false, -- 201 bytes, one line
      ["added.txt"] = 20,
      ["untracked.txt"] = 15,
    }, got)
  end)

  it("never defers a binary file", function()
    local r = gitrepo.new()
    r:write("b.bin", "\0" .. string.rep("\n", 50))
    local base = r:commit("base")
    r:write("b.bin", "\0" .. string.rep("\n", 60))
    local repo = assert(repo_mod.discover(r.root))
    local left, right = rev.commit(base), rev.worktree()
    local list = entry.list(assert(files.diff(repo, left, right)))
    entry.measure(repo, { left = left, right = right }, list.entries, 10)
    expect.eq(false, list.entries[1].deferred)
  end)
end)

describe("git blob sizes and line counts", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  it("sizes objects in one call and skips zero and unknown ids", function()
    local r = gitrepo.new()
    r:write("a.txt", "12345")
    r:commit("one")
    local repo = assert(repo_mod.discover(r.root))
    local oid = r:oid("HEAD:a.txt")
    local missing = string.rep("d", #oid)
    local sizes = assert(blob.sizes(repo, { oid, string.rep("0", #oid), missing }))
    expect.eq({ [oid] = 5 }, sizes)
    expect.eq({}, assert(blob.sizes(repo, {})))
  end)

  it("counts lines the way lines() splits them", function()
    for _, bytes in ipairs({ "", "a", "a\n", "a\nb", "a\nb\n", "\n\n" }) do
      expect.eq(#blob.lines(bytes), blob.line_count(bytes), vim.inspect(bytes))
    end
  end)
end)
