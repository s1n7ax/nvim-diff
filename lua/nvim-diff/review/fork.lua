--- PRs from forks (GitHub's `isCrossRepository`): the reviewer decides, per PR, whether
--- language servers may run on its code. Some servers run project code — rust-analyzer's
--- build scripts and proc macros, eslint's JS config, gopls' toolchain line — so a fork's
--- code gets no language server until the reviewer says yes.
---
--- The answer lives in the review (`views/review.lua`, `Review.lsp`) and nowhere else: it
--- lasts until the review ends, and reopening the PR asks again.
---
---     if fork.ask(pr) then ... end         -- `Start LSP? [y/N]`, Enter is no
---     local block = fork.block(slot, pr)   -- after a no: no server on the slot's files
---     block:lift({ start = true })         -- a yes after all
---
--- Yes or no, the language servers an earlier PR started in the slot are stopped before a
--- fork PR is checked out there (`core/lsp.lua` `stop_in`, mode `checkout`).

local config = require("nvim-diff.config")
local log = require("nvim-diff.core.log")
local lsp = require("nvim-diff.core.lsp")
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

--- After a no: keep every language server off fork PR `pr`'s review slot `slot` until a
--- yes or the review's end (`core/lsp.lua` `block`). A slot file opened any way — a picker,
--- `:edit`, `gf`, a quickfix entry, a jump into a new tabpage — starts none: the slot is the
--- review tabpage's cwd, and the user's config would start their servers there. The first
--- server kept off gets a notice naming the key that asks again; the rest only a debug one.
---@param slot string
---@param pr NvimDiff.GitHub.PR
---@return NvimDiff.LspBlock
function M.block(slot, pr)
  local root = path.real(slot)
  local told = false
  return lsp.block(slot, function(name, file)
    local what = ("%s off the review slot"):format(name)
    if file then
      what = ("%s off %s"):format(name, path.relative(path.real(file), root) or file)
    end
    if told then
      log.debug("PR #%d is from a fork: kept %s", pr.number, what)
      return
    end
    told = true
    local key = config.get().keymaps.review.start_lsp
    local again = type(key) == "string" and ("; %s asks again"):format(key) or ""
    log.warn("PR #%d is from a fork: language servers stay off its files (kept %s)%s", pr.number, what, again)
  end)
end

return M
