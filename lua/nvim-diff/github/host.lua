--- Where a repository's PRs live: the host `gh` should talk to, plus the owner and name
--- `gh api` needs explicitly.
---
--- `gh api` is not repo-context aware the way `gh pr view` or `gh repo view` are — its
--- `--hostname` flag defaults to `github.com` regardless of what the local git remote
--- points at (verified against `gh api --help`), and `{owner}`/`{repo}` placeholder
--- substitution is a REST-only convenience that does not extend to GraphQL variables. So
--- this module resolves all three facts itself, the same way `gh` would for a command that
--- *is* repo-context aware: **the host comes from the remote URL**, so the plugin never has
--- to ask. `config.github.host` overrides only the host, for the case a remote names an
--- internal alias (`git@git-internal.corp:...`) that `gh auth login` was not pointed at —
--- the same repository's owner/name still come from the remote. `GH_HOST` is honoured next,
--- the same environment variable `gh` itself reads "for commands ... where a hostname ...
--- cannot be inferred from the context of a local Git repository" (`gh help environment`).

local errors = require("nvim-diff.github.error")
local git_cmd = require("nvim-diff.git.cmd")

local M = {}

---@class NvimDiff.GitHub.Target
---@field host string
---@field owner string
---@field repo string

---@param rest string Everything after the host in a remote URL.
---@return string? owner
---@return string? repo
local function split_owner_repo(rest)
  rest = rest:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
  return rest:match("^([^/]+)/([^/]+)$")
end

--- Parse a git remote URL into a host and owner/repo. Handles the shapes a GitHub or GHES
--- remote actually takes: `https://host/owner/repo(.git)`, the scp-like
--- `[user@]host:owner/repo(.git)`, and `ssh://[user@]host[:port]/owner/repo(.git)`. Not a
--- general git-remote-URL parser — anything with a path deeper than `owner/repo` is not a
--- GitHub remote and is reported as unparseable rather than guessed at.
---@param url string
---@return NvimDiff.GitHub.Target? target `host` still needs the config/`GH_HOST` override applied.
local function parse_remote(url)
  url = vim.trim(url)
  local scheme, hostport, rest = url:match("^(%a[%w+.-]*)://([^/]+)/(.+)$")
  if scheme then
    local host = hostport:match("@([^@]+)$") or hostport
    host = host:match("^([^:]+)")
    local owner, repo = split_owner_repo(rest)
    if owner and repo then
      return { host = host, owner = owner, repo = repo }
    end
    return nil
  end

  local userhost, scp_rest = url:match("^([^/:@]+@?[^/:]*):(.+)$")
  if userhost then
    local host = userhost:match("@([^@]+)$") or userhost
    local owner, repo = split_owner_repo(scp_rest)
    if owner and repo then
      return { host = host, owner = owner, repo = repo }
    end
  end
  return nil
end
M._parse_remote = parse_remote

---@class NvimDiff.GitHub.ResolveOpts
---@field remote? string Defaults to `origin`.

--- The host, owner and repo `gh api` should target for `repo`.
---@param repo NvimDiff.Git.Repo
---@param opts? NvimDiff.GitHub.ResolveOpts
---@return NvimDiff.GitHub.Target? target
---@return NvimDiff.GitHub.Error? err `no_remote`, `bad_remote`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.resolve(repo, opts)
  opts = opts or {}
  local remote = opts.remote or "origin"
  local out, git_err = git_cmd.output(repo.toplevel, { "remote", "get-url", remote })
  if not out then
    return nil,
      errors.new(
        "no_remote",
        ("no %q remote to resolve a GitHub host from: %s"):format(
          remote,
          git_err and git_err.message or "unknown error"
        )
      )
  end

  local parsed = parse_remote(out)
  if not parsed then
    return nil,
      errors.new(
        "bad_remote",
        ("could not read a host and owner/repo from remote %q: %s"):format(remote, vim.trim(out))
      )
  end

  local config = require("nvim-diff.config").get()
  local host = config.github.host
  if not host or host == "" then
    host = vim.env.GH_HOST
  end
  if not host or host == "" then
    host = parsed.host
  end

  return { host = host, owner = parsed.owner, repo = parsed.repo }
end

return M
