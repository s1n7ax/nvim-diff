--- PRs from forks (GitHub's `isCrossRepository`): the reviewer decides, per PR, whether
--- language servers may run on its code. Some servers run project code — rust-analyzer's
--- build scripts and proc macros, eslint's JS config, gopls' toolchain line — so a fork's
--- code gets no language server until the reviewer says yes.
---
--- The answer lives in the review (`views/review.lua`, `Review.lsp`) and nowhere else: it
--- lasts until the review ends, and reopening the PR asks again.
---
---     if fork.ask(pr) then ... end -- `Start LSP? [y/N]`, Enter is no
---
--- Yes or no, the language servers an earlier PR started in the slot are stopped before a
--- fork PR is checked out there (`core/lsp.lua` `stop_in`, mode `checkout`).

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

return M
