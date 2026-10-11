--- A yes-or-no confirmation as a two-item `vim.ui.select` menu: `Yes` and `No`, the default
--- answer listed first so a picker that highlights the first item makes a bare Enter answer
--- the default. Only an explicit `Yes` is yes — `No`, dismissing the menu (`Esc`, closing
--- the picker) and the built-in fallback's empty Enter are all a no.
---
--- Blocking, so a caller keeps its boolean-returning `confirm`/`ask` shape. The built-in
--- fallback calls back inside `vim.ui.select`; snacks and telescope call back after it
--- returned, which `vim.wait` waits for, so the action still waits for the answer.

local M = {}

--- Ask `prompt`, returning the answer: true only for an explicit Yes.
---@param prompt string
---@param default boolean The answer a bare Enter picks.
---@return boolean yes
function M.confirm(prompt, default)
  local items = default and { "Yes", "No" } or { "No", "Yes" }
  local answered, answer = false, nil
  vim.ui.select(items, { prompt = prompt }, function(choice)
    answered = true
    answer = choice
  end)
  -- A floating picker answers after `vim.ui.select` returns; wait for it. The built-in
  -- fallback answers inline, so there is nothing to wait for.
  if not answered then
    vim.wait(math.huge, function()
      return answered
    end)
  end
  return answer == "Yes"
end

return M
