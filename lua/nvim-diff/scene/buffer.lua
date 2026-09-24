--- Diff pane buffers: read-only scratch buffers holding one side of a diff.
---
--- Layout, fixed for every renderer: buffer line 1 is the header (`virt_lines_above` on
--- row 0 never renders, so filler above the file's first line needs a real line to hang
--- from), the file's lines follow, and an optional empty trailer line ends it (see
--- `render/rowmap.lua` for when).

local api = vim.api

local M = {}

---@class NvimDiff.PaneBufOpts
---@field lines string[] The file's lines, no terminators.
---@field header string Text of buffer line 1.
---@field trailer? boolean Append the empty trailer line.
--- Buffer name, set **before** the content so concurrent requests for one blob dedupe on
--- it (`nvim-diff://<gitdir>/<rev>/<path>`). Unnamed when omitted.
---@field name? string
--- Treesitter language to highlight with. Started with `vim.treesitter.start` only — no
--- `filetype` is set, so no ftplugin can reach into the pane's window options.
---@field lang? string

--- Options every pane buffer carries. `modifiable` is set last, after the content.
local BUF_OPTIONS = {
  buftype = "nofile",
  bufhidden = "wipe",
  swapfile = false,
  buflisted = false,
  undolevels = -1,
}

--- Create a pane buffer.
---@param opts NvimDiff.PaneBufOpts
---@return integer buf
function M.create(opts)
  local buf = api.nvim_create_buf(false, true)
  for name, value in pairs(BUF_OPTIONS) do
    api.nvim_set_option_value(name, value, { buf = buf })
  end
  if opts.name then
    api.nvim_buf_set_name(buf, opts.name)
  end

  local text = { opts.header }
  for i, line in ipairs(opts.lines) do
    -- A NUL in a blob arrives as `\n` when split on newlines; the buffer stores NUL as NL.
    text[i + 1] = line:find("\n", 1, true) and line:gsub("\n", "\0") or line
  end
  if opts.trailer then
    text[#text + 1] = ""
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  api.nvim_set_option_value("modified", false, { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  if opts.lang then
    pcall(vim.treesitter.start, buf, opts.lang)
  end
  return buf
end

return M
