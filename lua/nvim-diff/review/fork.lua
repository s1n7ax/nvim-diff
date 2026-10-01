--- PRs from forks (GitHub's `isCrossRepository`): the reviewer decides, per PR, whether
--- language servers may run on its code. Some servers run project code — rust-analyzer's
--- build scripts and proc macros, eslint's JS config, gopls' toolchain line — so a fork's
--- code gets no language server until the reviewer says yes.
---
--- The answer lives in the review (`views/review.lua`, `Review.lsp`) and nowhere else: it
--- lasts until the review ends, and reopening the PR asks again.
---
---     if fork.ask(pr) then ... end        -- `Start LSP? [y/N]`, Enter is no
---     fork.stop_clients(slot_path)        -- before a fork PR is checked out into the slot

local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")

local M = {}

--- Ask whether to start LSP on fork PR `pr`: y or yes starts it; Enter, Esc, `<C-c>` or
--- anything else is no. Replaceable, so a script can answer without a prompt.
---@param pr NvimDiff.GitHub.PR
---@return boolean yes
function M.ask(pr)
  local from = ""
  if pr.head.owner and pr.head.repo then
    from = (" (%s/%s)"):format(pr.head.owner, pr.head.repo)
  end
  local prompt = ("nvim-diff: PR #%d is from a fork%s. Start LSP? [y/N] "):format(pr.number, from)
  vim.fn.inputsave()
  local ok, answer = pcall(vim.fn.input, { prompt = prompt, cancelreturn = "" })
  vim.fn.inputrestore()
  -- The prompt and the answer stay on the command line otherwise.
  vim.api.nvim_echo({ { "" } }, false, {})
  if not ok or type(answer) ~= "string" then
    return false
  end
  answer = vim.trim(answer):lower()
  return answer == "y" or answer == "yes"
end

--- Whether language server `client` is rooted in `root`: its root directory or one of its
--- workspace folders is `root` or inside it.
---@param client vim.lsp.Client
---@param root string Resolved.
---@return boolean
local function rooted(client, root)
  local dirs = { client.root_dir }
  for _, f in ipairs(client.workspace_folders or {}) do
    dirs[#dirs + 1] = f.uri and vim.uri_to_fname(f.uri) or nil
  end
  for _, dir in pairs(dirs) do
    if type(dir) == "string" and dir ~= "" and path.is_under(path.real(dir), root) then
      return true
    end
  end
  return false
end

--- Stop, at once, this Neovim's language servers rooted in `dir`: before a fork PR is
--- checked out into review slot `dir`, so a server an earlier PR started there cannot
--- index, or build, the fork's code.
---@param dir string
---@return integer stopped
function M.stop_clients(dir)
  -- Nothing has loaded `vim.lsp`: there is no client, and no need to load it here.
  if not package.loaded["vim.lsp"] then
    return 0
  end
  local root = path.real(dir)
  local stopped = 0
  -- A server still starting up counts too: its process may already be reading the slot.
  -- `_uninitialized` is Neovim's own (package) filter for that; a Neovim without it only
  -- lists the started ones.
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    if rooted(client, root) and not client:is_stopped() then
      -- Forced: no graceful shutdown to wait out while the checkout starts.
      client:stop(true)
      stopped = stopped + 1
    end
  end
  if stopped > 0 then
    log.info("stopped %d language server(s) rooted in %s before checking a fork PR out there", stopped, root)
  end
  return stopped
end

return M
