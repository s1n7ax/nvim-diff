-- Startup entry point.
--
-- Nothing here requires the plugin's Lua. This file holds the load guard and the user
-- commands, which pull the plugin in on first use. `:checkhealth nvim-diff`
-- resolves through 'runtimepath' and needs nothing from here, and `setup()` is optional,
-- so a lazy.nvim spec with no `event`/`cmd` still costs nothing at startup.

if vim.g.loaded_nvim_diff then
  return
end
vim.g.loaded_nvim_diff = 1

vim.api.nvim_create_user_command("NvimDiffOpen", function(info)
  require("nvim-diff.commands.diff").run(info.fargs)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("nvim-diff.commands.diff").complete(arglead, cmdline)
  end,
  desc = "nvim-diff: diff the worktree, the index or two revisions",
})

vim.api.nvim_create_user_command("NvimDiffClose", function()
  require("nvim-diff.commands.diff").close()
end, { nargs = 0, desc = "nvim-diff: close the diff view in this tabpage" })

vim.api.nvim_create_user_command("NvimDiffHistory", function(args)
  require("nvim-diff.views.history").command(args.args)
end, {
  nargs = "?",
  complete = "file",
  desc = "nvim-diff: commit history of a file or directory (% = current file), or of the repository",
})
