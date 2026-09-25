--- Whether `gh` is installed, and which hosts it can actually talk to.
---
--- `gh auth status --json hosts` is used rather than parsing the human-readable text a
--- terminal would show, because in `--json` mode `gh` **always exits 0** and reports each
--- host's real state (`success` or `error`) instead of collapsing everything into one exit
--- code (verified against a live token gh rejected: `state: "error"`, `active: true`,
--- exit 0). A token can be present but rejected — expired, revoked, wrong scopes — which is
--- a different fact from "never logged in", and worth telling apart from a caller that wants
--- to say something more useful than "not authenticated".

local cmd = require("nvim-diff.github.cmd")

local M = {}

---@class NvimDiff.GitHub.HostAuth
---@field host string
---@field authenticated boolean Some account on this host has a working token.
---@field login? string The authenticated (preferably active) account's login.
---@field active boolean Whether the authenticated account is the one `gh` will use by default.

---@class NvimDiff.GitHub.AuthStatus
---@field installed boolean
---@field version? string First line of `gh --version`.
---@field hosts NvimDiff.GitHub.HostAuth[] Every host `gh` knows about, sorted by host name.

--- `gh`'s install-and-auth state, independent of any one PR or repository.
---@return NvimDiff.GitHub.AuthStatus
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.status()
  local version_res = cmd.run({ "--version" })
  if not version_res or not version_res.spawned then
    return { installed = false, hosts = {} }
  end

  ---@type NvimDiff.GitHub.AuthStatus
  local status = {
    installed = true,
    version = vim.split(vim.trim(version_res.stdout), "\n")[1],
    hosts = {},
  }

  local auth_res = cmd.run({ "auth", "status", "--json", "hosts" })
  if not auth_res or not auth_res.spawned or vim.trim(auth_res.stdout) == "" then
    return status
  end
  local ok, decoded = pcall(vim.json.decode, auth_res.stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.hosts) ~= "table" then
    return status
  end

  for host, accounts in pairs(decoded.hosts) do
    ---@type table?
    local best
    for _, account in ipairs(accounts) do
      if account.state == "success" and (not best or account.active) then
        best = account
      end
    end
    status.hosts[#status.hosts + 1] = {
      host = host,
      authenticated = best ~= nil,
      login = best and best.login or nil,
      active = best ~= nil and best.active == true,
    }
  end
  table.sort(status.hosts, function(a, b)
    return a.host < b.host
  end)
  return status
end

--- Whether `status` shows a working credential for `host` (case-insensitive).
---@param status NvimDiff.GitHub.AuthStatus
---@param host string
---@return boolean
function M.is_authenticated(status, host)
  for _, entry in ipairs(status.hosts) do
    if entry.authenticated and entry.host:lower() == host:lower() then
      return true
    end
  end
  return false
end

return M
