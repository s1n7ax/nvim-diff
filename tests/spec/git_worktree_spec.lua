local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local errors = require("nvim-diff.git.error")
local gitrepo = require("tests.gitrepo")
local health = require("nvim-diff.health")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local worktree = require("nvim-diff.git.worktree")

---@param r Test.Repo
---@return string[]
local function listed(r)
  local out = {}
  for p in r:git({ "worktree", "list", "--porcelain" }):gmatch("worktree ([^\n]+)") do
    out[#out + 1] = p
  end
  return out
end

--- A pid that is certainly not running: a child that has already exited.
---@return integer
local function dead_pid()
  local proc = vim.system({ "true" })
  local pid = proc.pid
  proc:wait()
  return pid
end

describe("git worktree", function()
  after_each(function()
    gitrepo.cleanup()
  end)

  ---@return Test.Repo, NvimDiff.Git.Repo, string head
  local function setup_repo()
    local r = gitrepo.new()
    r:write("f.txt", "one\n")
    local head = r:commit("one")
    return r, assert(repo_mod.discover(r.root)), head
  end

  it("places PR worktrees under the common git dir", function()
    local _, repo = setup_repo()
    expect.eq(repo.common_dir .. "/nvim-diff/pr-42", worktree.path(repo, 42))
  end)

  it("adds a detached worktree at the commit, locked to this Neovim", function()
    local r, repo, head = setup_repo()
    local user_branch = r:git({ "branch", "--show-current" })
    r:write("dirty.txt", "uncommitted\n")

    local wt = assert(worktree.add(repo, 7, rev.commit(head)))
    expect.eq(worktree.path(repo, 7), wt)
    expect.eq("one\n", table.concat(vim.fn.readfile(wt .. "/f.txt"), "\n") .. "\n")

    local porcelain = r:git({ "worktree", "list", "--porcelain" })
    expect.matches(
      "worktree " .. vim.pesc(wt) .. "\nHEAD " .. head .. "\ndetached\nlocked nvim%-diff pid " .. vim.fn.getpid(),
      porcelain
    )

    -- The user's checkout is untouched.
    expect.eq(user_branch, r:git({ "branch", "--show-current" }))
    expect.truthy(vim.uv.fs_stat(r.root .. "/dirty.txt"))
    expect.eq({}, health.orphan_worktrees({ cwd = r.root }), "a live lock is not an orphan")

    -- Discovering from inside it gives a repo rooted there, sharing the common dir.
    local inner = assert(repo_mod.discover(wt))
    expect.eq(wt, inner.toplevel)
    expect.eq(repo.common_dir, inner.common_dir)
  end)

  it("replaces an existing worktree for the same PR, even a modified one", function()
    local r, repo, first = setup_repo()
    local wt = assert(worktree.add(repo, 1, rev.commit(first)))
    local fd = assert(io.open(wt .. "/f.txt", "w"))
    fd:write("edited in the review\n")
    fd:close()
    r:write("f.txt", "two\n")
    local second = r:commit("two")

    assert(worktree.add(repo, 1, rev.commit(second)))
    expect.eq({ "two" }, vim.fn.readfile(wt .. "/f.txt"))
    expect.eq(2, #listed(r))
  end)

  it("removes a worktree, locked and dirty, and is idempotent", function()
    local r, repo, head = setup_repo()
    local wt = assert(worktree.add(repo, 3, rev.commit(head)))
    local fd = assert(io.open(wt .. "/scratch.txt", "w"))
    fd:write("x")
    fd:close()

    expect.truthy(worktree.remove(repo, 3))
    expect.falsy(vim.uv.fs_stat(wt))
    expect.eq({ r.root }, listed(r))
    expect.truthy(worktree.remove(repo, 3))
  end)

  it("cleans up a worktree whose directory was deleted behind git's back", function()
    local r, repo, head = setup_repo()
    local wt = assert(worktree.add(repo, 4, rev.commit(head)))
    vim.fn.delete(wt, "rf")
    expect.truthy(worktree.remove(repo, 4))
    expect.eq({ r.root }, listed(r))
  end)

  it("refuses a non-commit revision", function()
    local _, repo = setup_repo()
    local _, err = worktree.add(repo, 1, rev.worktree())
    expect.truthy(errors.is(err, "invalid"))
  end)

  it("surfaces git's error for a commit that is not in the repository", function()
    local _, repo = setup_repo()
    local _, err = worktree.add(repo, 1, rev.commit(string.rep("1", 40)))
    expect.truthy(errors.is(err, "failed"), tostring(err))
  end)

  describe("orphan prune", function()
    it("removes unlocked and dead-owner worktrees, keeps live and foreign locks", function()
      local r, repo, head = setup_repo()
      local common = repo.common_dir .. "/nvim-diff/"
      r:git({ "worktree", "add", "-q", "--detach", common .. "pr-1", head })
      r:git({ "worktree", "add", "-q", "--detach", common .. "pr-2", head })
      r:git({ "worktree", "lock", "--reason", "nvim-diff pid " .. dead_pid(), common .. "pr-2" })
      r:git({ "worktree", "add", "-q", "--detach", common .. "pr-3", head })
      r:git({ "worktree", "lock", "--reason", "nvim-diff pid " .. vim.fn.getpid(), common .. "pr-3" })
      r:git({ "worktree", "add", "-q", "--detach", common .. "pr-4", head })
      r:git({ "worktree", "lock", "--reason", "mine, hands off", common .. "pr-4" })
      -- Not ours at all: a user's own worktree elsewhere.
      r:git({ "worktree", "add", "-q", "--detach", r.root .. "-mine", head })

      local expected = { common .. "pr-1", common .. "pr-2" }
      expect.eq(expected, health.orphan_worktrees({ cwd = r.root }), "health agrees on the orphans")

      local removed = assert(worktree.prune_orphans(repo))
      expect.eq(expected, removed)
      expect.eq({ r.root, r.root .. "-mine", common .. "pr-3", common .. "pr-4" }, listed(r))
      r:git({ "worktree", "remove", "--force", r.root .. "-mine" })
      expect.eq({}, health.orphan_worktrees({ cwd = r.root }))
    end)

    it("runs once per session at startup, in the background", function()
      local r, _, head = setup_repo()
      local orphan = r.root .. "/.git/nvim-diff/pr-9"
      r:git({ "worktree", "add", "-q", "--detach", orphan, head })

      worktree.startup_pruned = false
      local cwd = vim.uv.cwd()
      vim.uv.chdir(r.root)
      -- The cwd is read before the first await, so restoring it right away is safe.
      local task = assert(worktree.prune_on_startup())
      vim.uv.chdir(cwd)
      expect.truthy(task:wait(5000))
      expect.eq({ { orphan } }, task.values)
      expect.eq(nil, worktree.prune_on_startup(), "second call is a no-op")
    end)
  end)
end)
