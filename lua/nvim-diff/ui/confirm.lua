--- A yes-or-no confirmation as a two-item `vim.ui.select` menu: `Yes` and `No`, the default
--- answer listed first so a picker that highlights the first item makes a bare Enter answer
--- the default. Only an explicit `Yes` is yes — `No`, dismissing the menu (`Esc`, closing
--- the picker) and the built-in fallback's empty Enter are all a no.
---
--- Asynchronous: `on_answer` runs from `vim.ui.select`'s callback, so the caller's
--- continuation runs on the answer and nothing blocks the main loop — a picker that answers
--- after `vim.ui.select` returns (snacks, telescope) keeps drawing and taking keys while the
--- menu is open. The built-in fallback calls back inside `vim.ui.select`.

local M = {}

--- Ask `prompt`, calling `on_answer` with the answer: true only for an explicit Yes.
---@param prompt string
---@param default boolean The answer a bare Enter picks; its item is listed first.
---@param on_answer fun(yes: boolean)
function M.confirm(prompt, default, on_answer)
  local items = default and { "Yes", "No" } or { "No", "Yes" }
  vim.ui.select(items, { prompt = prompt }, function(choice)
    on_answer(choice == "Yes")
  end)
end

return M
