-- luacheck configuration. `make lint` runs this over lua/, plugin/ and tests/.

std = "luajit"

read_globals = {
  "vim",
}

-- The option tables are the writable parts of `vim`, same split Neovim core uses.
globals = {
  "vim.b",
  "vim.bo",
  "vim.env",
  "vim.g",
  "vim.o",
  "vim.opt",
  "vim.w",
  "vim.wo",
}

-- stylua keeps lines at 120; luacheck should not disagree with it.
max_line_length = 120

ignore = {
  "212/_.*", -- unused argument starting with an underscore
  "213/_.*", -- unused loop variable starting with an underscore
}

exclude_files = {
  ".git",
  ".luacheckrc",
}

files["tests/"] = {
  -- The health spec replaces `vim.health` with a recorder.
  globals = { "vim.health" },
}
