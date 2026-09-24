--- Throwaway git repositories for specs.
---
--- Loading this module makes every git process in the test run hermetic: no global or
--- system config (so a user's `commit.gpgsign`, `diff.external` or hooks cannot leak in)
--- and a fixed identity.

vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME = "nvim-diff"
vim.env.GIT_AUTHOR_EMAIL = "test@nvim-diff.invalid"
vim.env.GIT_COMMITTER_NAME = "nvim-diff"
vim.env.GIT_COMMITTER_EMAIL = "test@nvim-diff.invalid"

-- `setup()` in other specs would otherwise prune worktrees in whatever repository the
-- runner was started from. The worktree spec re-arms it against a throwaway repo.
require("nvim-diff.git.worktree").startup_pruned = true

local M = {}

---@class Test.Repo
---@field root string
local Repo = {}
Repo.__index = Repo

--- Run git in the repository; raises on failure.
---@param args string[]
---@param stdin? string
---@return string stdout
function Repo:git(args, stdin)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = self.root, stdin = stdin }):wait()
  if res.code ~= 0 then
    error(("git %s failed: %s"):format(table.concat(args, " "), res.stderr), 2)
  end
  return res.stdout
end

--- Write a file (creating directories), relative to the root.
---@param rel string
---@param content string
function Repo:write(rel, content)
  local file = self.root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local fd = assert(io.open(file, "wb"))
  fd:write(content)
  fd:close()
end

---@param rel string
function Repo:delete(rel)
  assert(os.remove(self.root .. "/" .. rel))
end

--- Stage everything and commit; returns the new commit's oid.
---@param message string
---@return string oid
function Repo:commit(message)
  self:git({ "add", "-A" })
  self:git({ "commit", "-q", "--allow-empty", "-m", message })
  return vim.trim(self:git({ "rev-parse", "HEAD" }))
end

---@param spec string
---@return string oid
function Repo:oid(spec)
  return vim.trim(self:git({ "rev-parse", spec }))
end

---@type string[]
local created = {}

--- A fresh repository on branch `main` with no commits.
---@return Test.Repo
function M.new()
  local root = vim.fn.tempname() .. "-repo"
  vim.fn.mkdir(root, "p")
  -- Resolve symlinks (a /tmp that is a link) so paths compare equal to git's.
  root = vim.uv.fs_realpath(root)
  created[#created + 1] = root
  local repo = setmetatable({ root = root }, Repo)
  repo:git({ "init", "-q", "-b", "main" })
  return repo
end

--- Delete every repository `new` made. Call from `after_each`.
function M.cleanup()
  for _, root in ipairs(created) do
    vim.fn.delete(root, "rf")
  end
  created = {}
end

return M
