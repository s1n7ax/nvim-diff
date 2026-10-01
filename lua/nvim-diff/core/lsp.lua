--- Language server clients by the folders they are rooted in: their root directory and
--- workspace folders. A review slot's head pane warns about a server rooted outside the
--- slot (`scene/filebuf.lua`), and ending the review stops the servers rooted in it
--- (`views/review.lua`).
---
---     lsp.outside(client, slot) -- the client's roots that are not the slot or inside it
---     lsp.stop_inside(slot)     -- stop the clients rooted only in the slot
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

--- How long a server stopped by `stop_inside` gets to shut down before it is killed.
-- Measured: lua-language-server busy with a fresh workspace never answered `shutdown`, and
-- Neovim's default `exit_timeout` is never to force.
M.STOP_TIMEOUT_MS = 5000

--- Stop this Neovim's language servers rooted only in `dir` — at least one root, and every
--- one of them `dir` or inside it — including servers still starting up. A server that is
--- also rooted elsewhere (the user's own project) keeps running. Gracefully, but a server
--- still running after `STOP_TIMEOUT_MS` (or its own shorter `exit_timeout`) is killed.
---@param dir string
---@return integer stopped
function M.stop_inside(dir)
  if not package.loaded["vim.lsp"] then
    return 0
  end
  local stopped = 0
  -- `_uninitialized` is Neovim's own (package) filter for servers still starting; a Neovim
  -- without it lists only the started ones.
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    if #M.roots(client) > 0 and #M.outside(client, dir) == 0 and not client:is_stopped() then
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
