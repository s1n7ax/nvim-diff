--- A throwaway "GitHub" remote for PR specs.
---
--- `github/host.lua` resolves the host from the `origin` URL, so `origin` has to look like
--- GitHub (`git@github.com:octocat/hello-world.git`) — yet fetching from it has to stay on
--- disk. The repository's `core.sshCommand` is a stub that ignores the host and serves the
--- request from a bare repository under a temp directory, so `git fetch origin` runs the
--- real transport against a real `upload-pack`, and no network is touched.
---
--- `M.new()` builds:
---
--- - the bare remote, holding `main` at `base` and the PR's head at `refs/pull/7/head`
---   (branched off `fork_point`, the commit `local` also has);
--- - `local`, a `tests/gitrepo.lua` repository with only `fork_point` — neither the PR head
---   nor the moved-on `base` is in it until something fetches them.
---
--- The PR changes `a.txt` (modified), adds `b.txt` and deletes `c.txt`; `main` then moves
--- on with `z.txt`, which the PR's merge-base diff must not show.

local gitrepo = require("tests.gitrepo")

local M = {}

---@type string[]
local created = {}

---@param cwd string
---@param args string[]
---@return string stdout
local function git(cwd, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd }):wait()
  if res.code ~= 0 then
    error(("git %s failed: %s"):format(table.concat(args, " "), res.stderr), 2)
  end
  return res.stdout
end

---@class Test.PRRemote
---@field repo Test.Repo The user's clone.
---@field bare string The remote's path.
---@field fork_point string Commit both sides share: the PR's merge-base.
---@field head string The PR head, only on the remote.
---@field base string `main` on the remote, moved on past `fork_point`.
---@field number integer 7.

---@return Test.PRRemote
function M.new()
  local dir = vim.fn.tempname() .. "-prremote"
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  created[#created + 1] = dir

  local r = gitrepo.new()
  r:write("a.txt", "a1\na2\na3\n")
  r:write("c.txt", "gone soon\n")
  local fork_point = r:commit("fork point")

  local bare = dir .. "/octocat/hello-world.git"
  vim.fn.mkdir(vim.fs.dirname(bare), "p")
  git(dir, { "clone", "-q", "--bare", r.root, bare })

  local work = dir .. "/work"
  git(dir, { "clone", "-q", bare, work })
  git(work, { "checkout", "-q", "-b", "feature" })
  local fd = assert(io.open(work .. "/a.txt", "wb"))
  fd:write("a1\nA2\na3\n")
  fd:close()
  fd = assert(io.open(work .. "/b.txt", "wb"))
  fd:write("new\n")
  fd:close()
  os.remove(work .. "/c.txt")
  git(work, { "add", "-A" })
  git(work, { "commit", "-q", "-m", "the PR" })
  local head = vim.trim(git(work, { "rev-parse", "HEAD" }))
  git(work, { "push", "-q", "origin", "HEAD:refs/pull/7/head" })
  git(work, { "checkout", "-q", "main" })
  fd = assert(io.open(work .. "/z.txt", "wb"))
  fd:write("main moved on\n")
  fd:close()
  git(work, { "add", "-A" })
  git(work, { "commit", "-q", "-m", "main moves on" })
  local base = vim.trim(git(work, { "rev-parse", "HEAD" }))
  git(work, { "push", "-q", "origin", "main" })

  -- The "ssh" that serves every host from `dir`: with `ssh.variant=simple` git calls it as
  -- `<cmd> <host> "git-upload-pack 'octocat/hello-world.git'"`.
  local ssh = dir .. "/ssh"
  fd = assert(io.open(ssh, "w"))
  fd:write(table.concat({
    "#!/bin/sh",
    "cd '" .. dir .. "' || exit 1",
    'eval "exec git ${2#git-}"',
  }, "\n"))
  fd:close()
  vim.uv.fs_chmod(ssh, 448) -- 0700

  r:git({ "remote", "add", "origin", "git@github.com:octocat/hello-world.git" })
  r:git({ "config", "core.sshCommand", ssh })
  r:git({ "config", "ssh.variant", "simple" })

  return { repo = r, bare = bare, fork_point = fork_point, head = head, base = base, number = 7 }
end

--- Delete every remote `new` made (the local repositories go with `gitrepo.cleanup`).
function M.cleanup()
  for _, dir in ipairs(created) do
    vim.fn.delete(dir, "rf")
  end
  created = {}
end

return M
