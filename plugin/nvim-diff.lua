-- Startup entry point.
--
-- Nothing here requires the plugin's Lua. This file exists to hold the load guard and,
-- later, the user commands that pull the plugin in on first use. `:checkhealth nvim-diff`
-- resolves through 'runtimepath' and needs nothing from here, and `setup()` is optional,
-- so a lazy.nvim spec with no `event`/`cmd` still costs nothing at startup.

if vim.g.loaded_nvim_diff then
  return
end
vim.g.loaded_nvim_diff = 1
