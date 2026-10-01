--- Language server clients by the folders they are rooted in: their root directory and
--- workspace folders. A review slot's head pane warns about a server rooted outside the
--- slot (`scene/filebuf.lua`); a review stops the servers rooted in its slot before a fork
--- PR is checked out there, and when it ends (`views/review.lua`).
---
---     lsp.outside(client, slot)      -- the client's roots that are not the slot or inside it
---     lsp.stop_in(slot, "checkout")  -- kill every client with a root in the slot, at once
---     lsp.stop_in(slot, "close")     -- stop the clients rooted only in the slot, gracefully
---
--- Nothing here loads `vim.lsp`: with it not loaded there is no client.

local path = require("nvim-diff.core.path")

local M = {}

--- The folders `client` is rooted in, resolved: its root directory and its workspace
--- folders. Empty for a client in single-file mode.
---@param client vim.lsp.Client
---@return string[]
function M.roots(client)
  local seen, list = {}, {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" then
      dir = path.real(dir)
      if not seen[dir] then
        seen[dir] = true
        list[#list + 1] = dir
      end
    end
  end
  add(client.root_dir)
  if type(client.workspace_folders) == "table" then
    for _, f in ipairs(client.workspace_folders) do
      add(f.uri and vim.uri_to_fname(f.uri) or f.name)
    end
  end
  return list
end

--- The roots of `client` that are neither `dir` nor inside it.
---@param client vim.lsp.Client
---@param dir string
---@return string[]
function M.outside(client, dir)
  local root = path.real(dir)
  return vim.tbl_filter(function(r)
    return not path.is_under(r, root)
  end, M.roots(client))
end

--- How long a server stopped in mode `close` gets to shut down before it is killed.
-- Measured: lua-language-server busy with a fresh workspace never answered `shutdown`, and
-- Neovim's default `exit_timeout` is never to force.
M.STOP_TIMEOUT_MS = 5000

---@alias NvimDiff.LspStopMode
---| "checkout" # before another PR is checked out into the folder
---| "close"    # the review ended

--- Stop this Neovim's language servers rooted in review slot `dir`, including servers still
--- starting up (a starting server's process may already be reading the slot), as `mode`
--- says:
---
--- * `checkout`: every server with any root in `dir`, one still shutting down after the last
---   review ended too — so none started for an earlier PR can index, or build, the next
---   one's code — killed at once: no shutdown to wait out while the checkout starts;
--- * `close`: every server rooted only in `dir` — at least one root, and all of them `dir`
---   or inside it; one also rooted elsewhere (the user's own project) keeps running — shut
---   down gracefully, and killed if still running after `STOP_TIMEOUT_MS` (or its own
---   shorter `exit_timeout`).
---@param dir string
---@param mode NvimDiff.LspStopMode
---@return integer stopped
function M.stop_in(dir, mode)
  assert(mode == "checkout" or mode == "close", "nvim-diff: unknown stop mode")
  -- Nothing has loaded `vim.lsp`: there is no client, and no need to load it here.
  if not package.loaded["vim.lsp"] then
    return 0
  end
  local root = path.real(dir)
  local stopped = 0
  -- `_uninitialized` is Neovim's own (package) filter for servers still starting; a Neovim
  -- without it lists only the started ones.
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    local roots = M.roots(client)
    local inside = #vim.tbl_filter(function(r)
      return path.is_under(r, root)
    end, roots)
    if mode == "checkout" then
      -- Not `is_stopped()`, which is true as soon as a graceful shutdown starts: a server
      -- still shutting down from the last review's end (up to `STOP_TIMEOUT_MS`) is running.
      if inside > 0 and not client.rpc.is_closing() then
        client:stop(true)
        stopped = stopped + 1
      end
    elseif inside > 0 and inside == #roots and not client:is_stopped() then
      local timeout = client.exit_timeout
      if type(timeout) ~= "number" or timeout > M.STOP_TIMEOUT_MS then
        timeout = M.STOP_TIMEOUT_MS
      end
      client:stop(timeout)
      stopped = stopped + 1
    end
  end
  return stopped
end

return M
