--- `:checkhealth nvim-diff`.
---
--- Everything reported here is something that silently degrades the plugin rather than
--- breaking it loudly: a missing `gh` costs PR review but not diffing, a missing parser
--- costs structural diff but not line diff. The orphan-worktree check is the one that
--- reports state on disk the plugin is responsible for cleaning up.

local M = {}

--- Languages probed for a parser. Not exhaustive — enough to tell "treesitter works here"
--- from "treesitter has nothing to work with".
local PROBE_LANGS = {
  "bash",
  "c",
  "cpp",
  "css",
  "go",
  "html",
  "java",
  "javascript",
  "json",
  "lua",
  "markdown",
  "python",
  "ruby",
  "rust",
  "toml",
  "tsx",
  "typescript",
  "vim",
  "yaml",
}

local MIN_GIT = { 2, 25, 0 }

--- Run a command and return its result, or nil when the executable is missing or the run
--- failed outright.
---@param cmd string[]
---@param timeout_ms integer
---@return vim.SystemCompleted?
local function run(cmd, timeout_ms)
  if vim.fn.executable(cmd[1]) ~= 1 then
    return nil
  end
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout_ms)
  end)
  return ok and result or nil
end

---@param result vim.SystemCompleted?
---@return string
local function output(result)
  if not result then
    return ""
  end
  return vim.trim((result.stdout or "") .. (result.stderr or ""))
end

local function check_neovim()
  vim.health.start("Neovim")
  local version = tostring(vim.version())
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim " .. version)
  else
    vim.health.error("Neovim " .. version .. " is too old", { "nvim-diff requires Neovim 0.12 or newer" })
  end

  if type(vim.text) == "table" and type(vim.text.diff) == "function" then
    vim.health.ok("`vim.text.diff` is available")
  else
    vim.health.error("`vim.text.diff` is missing", { "the line diff engine has no backend without it" })
  end

  if vim.fn.exists("&winfixbuf") == 1 then
    vim.health.ok("`winfixbuf` is available")
  else
    vim.health.warn("`winfixbuf` is missing", { "a stray `:edit` can replace a diff pane's buffer" })
  end
end

local function check_config()
  vim.health.start("Configuration")
  local config = require("nvim-diff.config")
  local current = config.get()
  if config.did_setup() then
    vim.health.ok("`setup()` has been called")
  else
    vim.health.info("`setup()` has not been called; running on defaults")
  end
  vim.health.info(("layout: %s, structural diff: %s"):format(current.layout, tostring(current.diff.structural)))
  vim.health.info(
    ("thresholds: defer above %d lines, line diff above %d lines per side"):format(
      current.thresholds.defer_lines,
      current.thresholds.structural_lines
    )
  )
  local overrides = vim.tbl_keys(current.highlights)
  if #overrides > 0 then
    table.sort(overrides)
    vim.health.info("highlight overrides: " .. table.concat(overrides, ", "))
  end
end

local function check_git()
  vim.health.start("git")
  local config = require("nvim-diff.config").get()
  local result = run({ config.git.bin, "--version" }, config.git.timeout_ms)
  if not result then
    vim.health.error(("`%s` not found on PATH"):format(config.git.bin), { "nvim-diff cannot do anything without git" })
    return
  end

  local text = output(result)
  local major, minor, patch = text:match("(%d+)%.(%d+)%.?(%d*)")
  if not major then
    vim.health.warn("could not parse git's version: " .. text)
    return
  end

  local found = { tonumber(major), tonumber(minor), tonumber(patch) or 0 }
  if vim.version.lt(found, MIN_GIT) then
    vim.health.warn(
      ("git %d.%d.%d is older than the supported %d.%d"):format(found[1], found[2], found[3], MIN_GIT[1], MIN_GIT[2])
    )
  else
    vim.health.ok(("git %d.%d.%d"):format(found[1], found[2], found[3]))
  end
end

local function check_gh()
  vim.health.start("gh (GitHub PR review)")
  local config = require("nvim-diff.config").get()
  local status = require("nvim-diff.github.auth").status()
  if not status.installed then
    vim.health.warn(("`%s` not found on PATH"):format(config.github.bin), {
      "PR review is unavailable; diff, file history and merge conflicts are not affected",
      "install the GitHub CLI: https://cli.github.com",
    })
    return
  end
  vim.health.ok(status.version or config.github.bin)

  local authenticated = {}
  for _, host in ipairs(status.hosts) do
    if host.authenticated then
      authenticated[#authenticated + 1] = host.host
    end
  end
  if #authenticated > 0 then
    vim.health.ok("authenticated to " .. table.concat(authenticated, ", "))
  else
    vim.health.warn("`gh auth status` reports no authenticated host", { "run `gh auth login`" })
  end
end

local function check_treesitter()
  vim.health.start("treesitter (structural diff)")
  local available, missing = {}, {}
  for _, lang in ipairs(PROBE_LANGS) do
    -- The only probe that tells the truth: `vim.treesitter.language.add` returns true for
    -- languages that do not exist.
    if pcall(vim.treesitter.get_string_parser, "", lang) then
      available[#available + 1] = lang
    else
      missing[#missing + 1] = lang
    end
  end

  if #available == 0 then
    vim.health.warn("no parser found for any probed language", {
      "structural diff will always fall back to line diff",
      "install parsers with `:TSInstall <lang>` or nvim-treesitter",
    })
  else
    vim.health.ok(("%d of %d probed parsers installed"):format(#available, #PROBE_LANGS))
    vim.health.info("installed: " .. table.concat(available, ", "))
  end
  if #missing > 0 then
    vim.health.info("no parser: " .. table.concat(missing, ", "))
  end
end

--- The lock reason a PR worktree carries while a review has it open. The pid names the
--- Neovim that owns it, so a second Neovim's startup prune can tell a live review from a
--- crashed one.
M.WORKTREE_LOCK_REASON = "nvim-diff pid %d"

--- Whether a worktree lock reason names a Neovim that is still running.
---@param reason string?
---@return boolean
function M.worktree_owner_alive(reason)
  local pid = tonumber((reason or ""):match("^nvim%-diff pid (%d+)$"))
  if not pid then
    return false
  end
  if pid == vim.fn.getpid() then
    return true
  end
  -- Signal 0 checks for existence without delivering anything.
  return vim.uv.kill(pid, 0) == 0
end

--- Paths of PR worktrees left behind by a crash or `:qa!`: every `nvim-diff/pr-*`
--- worktree that is unlocked, or locked by a Neovim that is no longer running.
---@param opts? { cwd?: string } Repository to look in; the cwd when omitted.
---@return string[] paths
---@return string? err
function M.orphan_worktrees(opts)
  opts = opts or {}
  local config = require("nvim-diff.config").get()
  local cmd = { config.git.bin, "--no-optional-locks", "-c", "core.quotePath=false", "worktree", "list", "--porcelain" }
  if opts.cwd then
    table.insert(cmd, 2, "-C")
    table.insert(cmd, 3, opts.cwd)
  end
  local result = run(cmd, config.git.timeout_ms)
  if not result then
    return {}, "git is unavailable"
  end
  if result.code ~= 0 then
    return {}, "not inside a git repository"
  end

  return M.parse_orphans(result.stdout or "")
end

--- The orphan matcher on its own, over `git worktree list --porcelain` output, so
--- `git/worktree.lua` can fetch the list asynchronously and still share this code.
---@param porcelain string
---@return string[] paths
function M.parse_orphans(porcelain)
  local paths = {}
  -- Records are separated by a blank line; `locked` is optional and may carry a reason.
  for record in (porcelain .. "\n\n"):gmatch("(.-)\n\n") do
    local path = record:match("^worktree ([^\n]+)")
    if path and path:match("nvim%-diff[/\\]pr%-%w+$") then
      -- Unlocked, or locked by a Neovim that has gone. A lock anyone else placed is theirs.
      local locked = record:match("\nlocked") ~= nil
      local reason = record:match("\nlocked ([^\n]*)")
      local ours = reason ~= nil and reason:match("^nvim%-diff pid %d+$") ~= nil
      if not locked or (ours and not M.worktree_owner_alive(reason)) then
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

local function check_worktrees()
  vim.health.start("PR worktrees")
  local paths, err = M.orphan_worktrees()
  if err then
    vim.health.info(err .. "; skipping the orphan check")
    return
  end
  if #paths == 0 then
    vim.health.ok("no leftover PR worktrees")
    return
  end
  local advice = { "close the review, or remove them by hand:" }
  for _, path in ipairs(paths) do
    advice[#advice + 1] = ("  git worktree remove --force %s"):format(path)
  end
  vim.health.warn(("%d leftover PR worktree(s)"):format(#paths), advice)
end

--- Entry point for `:checkhealth nvim-diff`.
function M.check()
  check_neovim()
  check_config()
  check_git()
  check_gh()
  check_treesitter()
  check_worktrees()
end

return M
