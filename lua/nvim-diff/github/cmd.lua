--- The one place a `gh` process is built.
---
--- `gh` gets an **explicit environment allow-list**, not Neovim's full inherited
--- environment: unlike git (`git/cmd.lua`), which inherits everything because a dotfiles
--- setup may run Neovim with `GIT_DIR`/`GIT_WORK_TREE` set, `gh` has no equivalent need, and
--- a CLI that authenticates to a remote host is exactly the kind of child process that
--- should not see stray secrets sitting in the user's shell environment. The allow-list
--- covers what `gh` needs to find its own config and credentials, the `git` binary it shells
--- out to, an environment-supplied token, and the TLS/proxy configuration a GitHub
--- Enterprise Server host behind a corporate proxy or an internal CA commonly requires.
--- Every other inherited variable is stripped by mapping it to `false`, which is how
--- `core/job.lua`'s `env` option removes a name from the child's environment.
---
--- `GH_PROMPT_DISABLED` and `GH_NO_UPDATE_NOTIFIER` are forced on every call, the same way
--- `git/cmd.lua` forces `GIT_TERMINAL_PROMPT=0`: a `gh` call must never block on an
--- interactive prompt, and an update banner on stderr must never be mistaken for part of an
--- error message.
---
--- Every GraphQL call is routed through `M.graphql`, which sends the query text and its
--- variables as separate `-f`/`-F` arguments — never a query string built with
--- `string.format` — and carries `X-Github-Next-Global-ID: 1`, so every id GitHub hands back
--- is already in the new global format later steps will store and compare.

local errors = require("nvim-diff.github.error")
local job = require("nvim-diff.core.job")

local M = {}

--- Environment variables passed through to `gh` when Neovim itself has them set.
local ALLOWED = {
  -- locate gh's own config/credentials, and the `git` binary it shells out to
  HOME = true,
  USERPROFILE = true,
  PATH = true,
  Path = true,
  XDG_CONFIG_HOME = true,
  XDG_CACHE_HOME = true,
  GH_CONFIG_DIR = true,
  -- a token supplied through the environment rather than `gh auth login`
  GH_TOKEN = true,
  GITHUB_TOKEN = true,
  GH_ENTERPRISE_TOKEN = true,
  GITHUB_ENTERPRISE_TOKEN = true,
  -- honoured the same way it is for `gh` itself; `github/host.lua` also reads it directly
  -- when resolving a host, so this only matters for the odd command that reads it itself
  GH_HOST = true,
  -- TLS and proxy configuration a corporate GitHub Enterprise Server host commonly needs
  SSL_CERT_FILE = true,
  SSL_CERT_DIR = true,
  NODE_EXTRA_CA_CERTS = true,
  HTTPS_PROXY = true,
  HTTP_PROXY = true,
  NO_PROXY = true,
  https_proxy = true,
  http_proxy = true,
  no_proxy = true,
  NO_COLOR = true,
}

--- The `job.lua` env override that turns Neovim's inherited environment into an allow-list:
--- every currently-set name that is not in `ALLOWED` is mapped to `false`, which `job.lua`
--- reads as "remove this name" rather than "set it to the string `false`".
---@return table<string, string|false>
local function env()
  local overrides = {}
  for name in pairs(vim.uv.os_environ()) do
    if not ALLOWED[name] then
      overrides[name] = false
    end
  end
  overrides.GH_PROMPT_DISABLED = "1"
  overrides.GH_NO_UPDATE_NOTIFIER = "1"
  return overrides
end

--- Run `gh` and return the raw result. Only a failure to run at all is an error here; the
--- exit status is the caller's to interpret — a non-zero exit from `gh api` is an ordinary,
--- expected outcome (a 404, a bad token) that carries its own JSON body on stdout.
---@param args string[]
---@param opts? { timeout_ms?: integer }
---@return NvimDiff.Job.Result? result
---@return NvimDiff.GitHub.Error? err `spawn_failed` or `timeout`.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.run(args, opts)
  opts = opts or {}
  local config = require("nvim-diff.config").get()
  local argv = { config.github.bin }
  vim.list_extend(argv, args)
  local res = job.await(argv, {
    env = env(),
    timeout_ms = opts.timeout_ms or config.github.timeout_ms,
  })
  local extra = { cmd = job.describe(argv), stderr = res.stderr }
  if not res.spawned then
    return nil, errors.new("spawn_failed", "could not run gh: " .. res.stderr, extra)
  end
  if res.timed_out then
    return nil, errors.new("timeout", "gh " .. job.reason(res), extra)
  end
  return res
end

---@class NvimDiff.GitHub.Var
---@field flag "-f"|"-F" `-f` for a raw string (never let `gh` guess the type); `-F` for a
---value that must arrive as a GraphQL `Int`/`Boolean`.
---@field name string
---@field value string|number|boolean

---@class NvimDiff.GitHub.RequestOpts
---@field headers? string[] Extra `key: value` headers.
---@field vars? NvimDiff.GitHub.Var[] `-f`/`-F` fields, sent as `gh api` request parameters.
---@field timeout_ms? integer

---@class NvimDiff.GitHub.Response
---@field status? integer HTTP status code; nil when the header block did not parse.
---@field headers table<string, string> Lower-cased header names.
---@field body any Decoded JSON, or the raw text when it did not parse as JSON.

--- Split `gh api -i`'s output into its header block and body. The header block ends at the
--- first blank line; a response with no header block at all (a connection failure never
--- reaches the point of getting a response) has no blank-line split, and is reported to the
--- caller instead of parsed.
---@param raw string
---@return string? head
---@return string body
local function split_response(raw)
  local head, body = raw:match("^(.-)\r?\n\r?\n(.*)$")
  if not head then
    return nil, raw
  end
  return head, body
end

---@param head string
---@return integer? status
---@return table<string, string> headers
local function parse_headers(head)
  local status
  local headers = {}
  local first = true
  for line in (head .. "\n"):gmatch("(.-)\r?\n") do
    if first then
      status = tonumber(line:match("^HTTP/[%d.]+%s+(%d+)"))
      first = false
    else
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then
        headers[name:lower()] = value
      end
    end
  end
  return status, headers
end

--- `gh api --hostname <host> -i <endpoint>`, with `opts.vars` appended as `-f`/`-F` fields
--- and `opts.headers` as extra `-H` headers. `-i` is always on, so every response — success
--- or HTTP error — carries its status and headers back to the caller; a rate limit's
--- `Retry-After` only exists there.
---@param host string
---@param endpoint string `graphql`, or a REST path such as `repos/{owner}/{repo}/pulls/1/comments`.
---@param opts? NvimDiff.GitHub.RequestOpts
---@return NvimDiff.GitHub.Response? response
---@return NvimDiff.GitHub.Error? err `request_failed` (no response reached), `spawn_failed` or `timeout`.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.request(host, endpoint, opts)
  opts = opts or {}
  local args = { "api", "--hostname", host, "-i" }
  for _, header in ipairs(opts.headers or {}) do
    vim.list_extend(args, { "-H", header })
  end
  args[#args + 1] = endpoint
  for _, var in ipairs(opts.vars or {}) do
    vim.list_extend(args, { var.flag, ("%s=%s"):format(var.name, tostring(var.value)) })
  end

  local res, err = M.run(args, { timeout_ms = opts.timeout_ms })
  if not res then
    return nil, err
  end

  local head, body_text = split_response(res.stdout)
  if not head then
    local reason = job.reason(res)
    return nil,
      errors.new("request_failed", reason ~= "" and reason or vim.trim(res.stderr), {
        cmd = job.describe(res.cmd),
        stderr = res.stderr,
      })
  end
  local status, headers = parse_headers(head)
  local ok, decoded = pcall(vim.json.decode, body_text)
  return { status = status, headers = headers, body = ok and decoded or body_text }
end

---@param list table[]?
---@return string? message
local function first_message(list)
  return list and list[1] and list[1].message or nil
end

--- Turn a response into `data, nil` or `nil, err`, covering both shapes `gh api` can hand
--- back on failure: a GraphQL body (`{"data":..., "errors":[...]}`, HTTP 200 even on a
--- schema or NOT_FOUND error) and a plain REST-style error body
--- (`{"message":..., "status":"401"}`, a non-2xx HTTP status). Verified against the live
--- API for each status this function branches on (auth, bad field, missing repository/PR).
---@param response NvimDiff.GitHub.Response
---@return table? data
---@return NvimDiff.GitHub.Error? err
function M.classify(response)
  local status, headers, body = response.status, response.headers, response.body
  if type(body) ~= "table" then
    return nil, errors.new("api_error", "gh returned a response this client could not parse", { status = status })
  end

  if status and status >= 200 and status < 300 then
    if body.errors then
      local kind = "api_error"
      for _, one in ipairs(body.errors) do
        if one.type == "NOT_FOUND" then
          kind = "not_found"
          break
        end
      end
      return nil, errors.new(kind, first_message(body.errors) or "GraphQL error", { status = status })
    end
    return body.data or body, nil
  end

  local message = body.message or first_message(body.errors) or ("gh api returned HTTP %s"):format(tostring(status))
  if status == 401 then
    return nil, errors.new("not_authenticated", message, { status = status })
  end
  if status == 403 then
    local retry_after = tonumber(headers["retry-after"])
    if retry_after then
      return nil, errors.new("rate_limited", message, { status = status, retry_after = retry_after })
    end
    return nil, errors.new("forbidden", message, { status = status })
  end
  if status == 404 then
    return nil, errors.new("not_found", message, { status = status })
  end
  return nil, errors.new("api_error", message, { status = status })
end

--- The header GraphQL calls carry so every id in the response is already in GitHub's new
--- global node id format.
M.GRAPHQL_HEADERS = { "X-Github-Next-Global-ID: 1" }

--- Run a GraphQL query. `query` must be a static string — variables are the only thing that
--- may vary a call, sent as `-f`/`-F` fields, never interpolated into the query text.
---@param host string
---@param query string
---@param vars? NvimDiff.GitHub.Var[]
---@param opts? { timeout_ms?: integer }
---@return table? data The response's `data` object.
---@return NvimDiff.GitHub.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.graphql(host, query, vars, opts)
  opts = opts or {}
  local request_vars = { { flag = "-f", name = "query", value = query } }
  vim.list_extend(request_vars, vars or {})
  local response, err = M.request(host, "graphql", {
    headers = M.GRAPHQL_HEADERS,
    vars = request_vars,
    timeout_ms = opts.timeout_ms,
  })
  if not response then
    return nil, err
  end
  return M.classify(response)
end

return M
