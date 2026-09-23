-- A Neovim that has nvim-diff and nothing else:
--
--     nvim --clean -u tests/minimal_init.lua
--
-- Useful for `:checkhealth nvim-diff` and for reproducing a bug report without the user's
-- configuration in the way.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ":p:h:h"))

vim.opt.runtimepath:prepend(root)
vim.opt.packpath = {}

require("nvim-diff").setup()
