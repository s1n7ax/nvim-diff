--- nvim-diff: a diff, history, merge and GitHub PR review UI for Neovim.
---
--- `require("nvim-diff").setup(opts)` is optional; every module reads the defaults when it
--- has not been called. Submodules resolve lazily through this table, so
--- `require("nvim-diff").config` loads `nvim-diff.config` on first access and nothing else
--- is pulled in at startup.

local M = {}

--- Validate and apply user options, and define the plugin's highlight groups.
---@param opts NvimDiff.Config? Partial; anything omitted keeps its default.
---@return NvimDiff.Config config The merged configuration.
function M.setup(opts)
  local config = require("nvim-diff.config").setup(opts)
  require("nvim-diff.ui.hl").setup()
  return config
end

--- Whether the plugin can run here. Cheap; `:checkhealth nvim-diff` explains the failures.
---@return boolean ok
---@return string? reason
function M.is_supported()
  if vim.fn.has("nvim-0.12") ~= 1 then
    return false, "nvim-diff requires Neovim 0.12 or newer"
  end
  if type(vim.text) ~= "table" or type(vim.text.diff) ~= "function" then
    return false, "nvim-diff requires `vim.text.diff`"
  end
  return true
end

return setmetatable(M, {
  __index = function(t, key)
    local module = require("nvim-diff." .. key)
    rawset(t, key, module)
    return module
  end,
})
