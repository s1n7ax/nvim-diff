local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local conflict = require("nvim-diff.git.conflict")
local gitrepo = require("tests.gitrepo")
local repo_mod = require("nvim-diff.git.repo")

local FILE = {
  "top", -- 1
  "<<<<<<< HEAD", -- 2
  "ours 1", -- 3
  "ours 2", -- 4
  "=======", -- 5
  "theirs 1", -- 6
  ">>>>>>> feature", -- 7
  "middle", -- 8
  "<<<<<<< HEAD", -- 9
  "||||||| base", -- 10
  "base 1", -- 11
  "=======", -- 12
  "theirs 2", -- 13
  ">>>>>>> feature", -- 14
  "bottom", -- 15
}

--- A repository stopped in a merge with one conflicted file, `f.txt`.
---@return Test.Repo
local function conflicted()
  local r = gitrepo.new()
  r:write("f.txt", "a\nb\nc\n")
  r:write("clean.txt", "x\n")
  r:commit("base")
  r:git({ "checkout", "-q", "-b", "feature" })
  r:write("f.txt", "a\nTHEIRS\nc\n")
  r:commit("theirs")
  r:git({ "checkout", "-q", "main" })
  r:write("f.txt", "a\nOURS\nc\n")
  r:commit("ours")
  local res = vim.system({ "git", "merge", "-q", "feature" }, { cwd = r.root }):wait()
  assert(res.code ~= 0, "the merge should conflict")
  return r
end

describe("git.conflict", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  describe("parse", function()
    it("finds regions with and without a base section", function()
      local regions = conflict.parse(FILE)
      expect.eq(2, #regions)
      expect.eq({
        first = 2,
        last = 7,
        ours = { start = 3, count = 2 },
        theirs = { start = 6, count = 1 },
        labels = { ours = "HEAD", theirs = "feature" },
      }, regions[1])
      expect.eq({
        first = 9,
        last = 14,
        ours = { start = 10, count = 0 },
        base = { start = 11, count = 1 },
        theirs = { start = 13, count = 1 },
        labels = { ours = "HEAD", base = "base", theirs = "feature" },
      }, regions[2])
    end)

    it("says where the cursor is, with a half index between regions", function()
      local cases = { [1] = 0.5, [2] = 1, [7] = 1, [8] = 1.5, [9] = 2, [14] = 2, [15] = 2.5 }
      for lnum, want in pairs(cases) do
        local regions, current, index = conflict.parse(FILE, lnum)
        expect.eq(want, index, "line " .. lnum)
        expect.eq(want % 1 == 0 and regions[want] or nil, current, "line " .. lnum)
      end
      local _, current, index = conflict.parse({ "no", "markers" }, 1)
      expect.eq(nil, current)
      expect.eq(0.5, index)
    end)

    it("drops unfinished regions and restarts on a repeated opening marker", function()
      local regions = conflict.parse({
        "<<<<<<< a",
        "lost",
        "<<<<<<< b",
        "x",
        "=======",
        "y",
        ">>>>>>> c",
        "<<<<<<< never closed",
        "z",
        "=======",
      })
      expect.eq(1, #regions)
      expect.eq(3, regions[1].first)
      expect.eq("b", regions[1].labels.ours)
    end)

    it("ignores lines that only look like markers", function()
      local regions = conflict.parse({
        "<<<<<<<< eight",
        "<<<<<<<x",
        "<<<<<<<",
        "=======  ",
        "========",
        "=======",
        ">>>>>>>",
      })
      expect.eq(1, #regions)
      expect.eq({ first = 3, last = 7 }, { first = regions[1].first, last = regions[1].last })
      expect.eq({ start = 4, count = 2 }, regions[1].ours)
      expect.eq({ ours = "", theirs = "" }, regions[1].labels)
    end)

    it("steps from anywhere with floor/ceil of the index", function()
      local _, _, index = conflict.parse(FILE, 8)
      expect.eq(2, math.floor(index) + 1)
      expect.eq(1, math.ceil(index) - 1)
      _, _, index = conflict.parse(FILE, 9)
      expect.eq(3, math.floor(index) + 1)
      expect.eq(1, math.ceil(index) - 1)
    end)
  end)

  describe("choose", function()
    it("replaces a region with each choice", function()
      local regions = conflict.parse(FILE)
      local r1, r2 = regions[1], regions[2]
      expect.eq({ "ours 1", "ours 2" }, conflict.choose(FILE, r1, "ours"))
      expect.eq({ "theirs 1" }, conflict.choose(FILE, r1, "theirs"))
      expect.eq({ "ours 1", "ours 2", "theirs 1" }, conflict.choose(FILE, r1, "both"))
      expect.eq({}, conflict.choose(FILE, r1, "none"))
      expect.eq(nil, conflict.choose(FILE, r1, "base"))
      expect.eq({ "base 1" }, conflict.choose(FILE, r2, "base"))
      expect.eq({}, conflict.choose(FILE, r2, "ours"))
    end)
  end)

  describe("stages", function()
    it("gives the three stage ids of a conflicted path", function()
      local r = conflicted()
      local repo = assert(repo_mod.discover(r.root))
      local stages = assert(conflict.stages(repo, "f.txt"))
      expect.eq(r:oid(":1:f.txt"), stages.base)
      expect.eq(r:oid(":2:f.txt"), stages.ours)
      expect.eq(r:oid(":3:f.txt"), stages.theirs)
    end)

    it("reports a path that is not conflicted", function()
      local r = conflicted()
      local repo = assert(repo_mod.discover(r.root))
      local stages, err = conflict.stages(repo, "clean.txt")
      expect.eq(nil, stages)
      expect.eq("invalid", err and err.kind)
    end)

    it("leaves out the base of an add/add conflict", function()
      local r = gitrepo.new()
      r:write("keep.txt", "k\n")
      r:commit("root")
      r:git({ "checkout", "-q", "-b", "feature" })
      r:write("new.txt", "theirs\n")
      r:commit("theirs")
      r:git({ "checkout", "-q", "main" })
      r:write("new.txt", "ours\n")
      r:commit("ours")
      vim.system({ "git", "merge", "-q", "feature" }, { cwd = r.root }):wait()
      local repo = assert(repo_mod.discover(r.root))
      local stages = assert(conflict.stages(repo, "new.txt"))
      expect.eq(nil, stages.base)
      expect.truthy(stages.ours and stages.theirs)
    end)
  end)

  describe("other_head", function()
    it("finds MERGE_HEAD during a merge and nothing otherwise", function()
      local r = conflicted()
      local repo = assert(repo_mod.discover(r.root))
      local head = assert(conflict.other_head(repo))
      expect.eq("MERGE_HEAD", head.label)
      expect.eq(r:oid("feature"), head.oid)
      r:git({ "merge", "--abort" })
      expect.eq(nil, conflict.other_head(repo))
    end)
  end)
end)
