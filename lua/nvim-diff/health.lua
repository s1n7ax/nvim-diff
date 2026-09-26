--- `:checkhealth nvim-diff`.
---
--- Everything reported here is something that silently degrades the plugin rather than
--- breaking it loudly: a missing `gh` costs PR review but not diffing, a missing parser
--- costs structural diff but not line diff. The review-slot check is the one that reports
--- state on disk: the kept PR worktrees, which only the user removes.

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
--- `--diff-merges=first-parent`, which file history needs to list a merge commit's files.
local FIRST_PARENT_GIT = { 2, 31, 0 }

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
  local shown = ("git %d.%d.%d"):format(found[1], found[2], found[3])
  if vim.version.lt(found, MIN_GIT) then
    vim.health.warn(
      ("%s is older than the supported %d.%d"):format(shown, MIN_GIT[1], MIN_GIT[2]),
      { "upgrade git; options the plugin passes may be missing or behave differently" }
    )
  else
    vim.health.ok(shown)
  end
  if vim.version.lt(found, FIRST_PARENT_GIT) then
    vim.health.warn(
      ("%s has no `--diff-merges=first-parent` (git %d.%d)"):format(shown, FIRST_PARENT_GIT[1], FIRST_PARENT_GIT[2]),
      { "file history lists no files for merge commits; everything else works" }
    )
  end
end

--- The GitHub host the cwd's repository reviews against, resolved as `:NvimDiffPR` does:
--- `github.host`, else `$GH_HOST`, else the `origin` remote's host.
---@return NvimDiff.GitHub.Target? target
---@return string? why Why there is none.
local function repo_target()
  local repo = require("nvim-diff.git.repo").discover()
  if not repo then
    return nil, "not inside a git repository"
  end
  local target, err = require("nvim-diff.github.host").resolve(repo)
  if not target then
    if err and err.kind == "no_remote" then
      return nil, "the repository has no `origin` remote"
    end
    return nil, err and err.message or "no GitHub remote"
  end
  return target
end

---@return string
local function host_source()
  local config = require("nvim-diff.config").get()
  if config.github.host and config.github.host ~= "" then
    return "`github.host`"
  end
  if vim.env.GH_HOST and vim.env.GH_HOST ~= "" then
    return "`$GH_HOST`"
  end
  return "the `origin` remote"
end

local function check_gh()
  vim.health.start("gh (GitHub PR review)")
  local config = require("nvim-diff.config").get()
  local auth = require("nvim-diff.github.auth")
  local status = auth.status()
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
      authenticated[#authenticated + 1] = host.login and ("%s (%s)"):format(host.host, host.login) or host.host
    else
      vim.health.warn(("`gh` has a token for %s, but GitHub rejects it"):format(host.host), {
        ("run `gh auth refresh --hostname %s`, or `gh auth login --hostname %s`"):format(host.host, host.host),
      })
    end
  end
  if #authenticated > 0 then
    vim.health.ok("authenticated to " .. table.concat(authenticated, ", "))
  elseif #status.hosts == 0 then
    vim.health.warn("`gh auth status` reports no authenticated host", { "run `gh auth login`" })
  end

  -- The host that matters is the one this repository's PRs live on, which may be a GitHub
  -- Enterprise Server host `gh` was never logged in to.
  local target, why = repo_target()
  if not target then
    vim.health.info(("no PR host to check for the cwd: %s"):format(why))
    return
  end
  local where = ("%s/%s on %s (host from %s)"):format(target.owner, target.repo, target.host, host_source())
  if auth.is_authenticated(status, target.host) then
    vim.health.ok("`:NvimDiffPR` here reviews " .. where)
  else
    vim.health.warn(("`gh` is not authenticated to %s"):format(target.host), {
      "`:NvimDiffPR` here reviews " .. where,
      ("run `gh auth login --hostname %s`"):format(target.host),
    })
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

--- One line about review slot `slot`, at the level its state deserves.
---@param slot NvimDiff.Git.Slot
local function report_slot(slot)
  local name = vim.fs.basename(slot.path)
  if slot.state == "held" then
    local by = slot.pid == vim.fn.getpid() and "this Neovim" or ("Neovim pid %d"):format(slot.pid)
    vim.health.ok(("%s: in use by %s"):format(name, by))
  elseif slot.state == "free" then
    local note = slot.stale and (" (lock left by Neovim pid %d, which is gone)"):format(slot.pid) or ""
    vim.health.ok(("%s: free%s"):format(name, note))
  elseif slot.state == "missing" then
    vim.health.info(("%s: folder removed, still registered with git; re-created when next needed"):format(name))
  elseif slot.state == "foreign" then
    vim.health.warn(
      ("%s: locked by something other than nvim-diff (%s); skipped while locked"):format(
        name,
        slot.reason or "no reason given"
      ),
      { ("git worktree unlock %s"):format(slot.path) }
    )
  elseif slot.state == "unregistered" then
    vim.health.warn(("%s: a folder git does not list as a worktree; skipped, never deleted"):format(name), {
      ("if the repository was moved, relink it: `git worktree repair %s`"):format(slot.path),
      ("otherwise remove it by hand: `rm -rf %s`"):format(slot.path),
    })
  end
end

local function check_slots()
  vim.health.start("PR review slots")
  local repo = require("nvim-diff.git.repo").discover()
  if not repo then
    vim.health.info("not inside a git repository; skipping")
    return
  end
  local worktree = require("nvim-diff.git.worktree")
  local slots, err = worktree.slots(repo)
  if not slots then
    vim.health.warn("cannot list the repository's worktrees: " .. tostring(err))
    return
  end
  local dir = worktree.dir(repo)
  if #slots == 0 then
    vim.health.ok(("no review slots yet; `:NvimDiffPR` creates them in %s"):format(dir))
  else
    vim.health.info(("%d review slot(s) in %s"):format(#slots, dir))
    for _, slot in ipairs(slots) do
      report_slot(slot)
    end
    vim.health.info(
      "a slot keeps the files git ignores (`node_modules/`, build output) for the next review, and nvim-diff "
        .. "never removes it. Remove one not in use by hand with `git worktree remove --force <path>`; "
        .. "add a second `--force` when it still carries the lock of a Neovim that is gone."
    )
  end

  local legacy = worktree.legacy(repo) or {}
  if #legacy > 0 then
    local advice = { "worktrees of an older nvim-diff, which removed them itself; nothing uses them now:" }
    for _, path in ipairs(legacy) do
      advice[#advice + 1] = ("  git worktree remove --force --force %s"):format(path)
    end
    vim.health.warn(("%d leftover PR worktree(s)"):format(#legacy), advice)
  end
end

--- Entry point for `:checkhealth nvim-diff`.
function M.check()
  check_neovim()
  check_config()
  check_git()
  check_gh()
  check_treesitter()
  check_slots()
end

return M
