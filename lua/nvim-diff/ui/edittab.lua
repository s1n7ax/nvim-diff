--- One tabpage reused for every jump to a real file on disk, for editing.
---
--- A diff pane shows a copy of a file at a revision, never the file itself, so there is
--- nothing to edit there. `keymaps.view.edit_file` (`go`) opens the real file instead, in
--- a tabpage of its own, leaving the diff where it is. However many files are jumped to,
--- there is one such tabpage: the first jump opens it next to the view, later ones show
--- their file in it, and closing it by hand is fine — the next jump opens it again.
---
---     require("nvim-diff.ui.edittab").open({ path = "/repo/foo.lua", lnum = 12 })
---
--- A file already open in another window is the same buffer, so unsaved changes there come
--- along; the buffer the tab showed before is hidden rather than abandoned when it holds
--- unsaved changes, so a jump never loses an edit. A PR review's head pane opens the real
--- file read-only, in that same buffer; this tab makes it editable.

local log = require("nvim-diff.core.log")

local api = vim.api

local M = {}

--- The edit tabpage; nil until one opens, and again once the user closes it.
---@type integer?
local tab

--- The edit tabpage's window, or nil when there is none (never opened, or closed since).
---@return integer?
local function edit_window()
  if tab ~= nil and not api.nvim_tabpage_is_valid(tab) then
    tab = nil
  end
  return tab and api.nvim_tabpage_get_win(tab) or nil
end

--- Open the edit tabpage right after `from`, with `from`'s tab-local directory.
---@param from integer Tabpage the jump came from.
---@return integer win
local function open_tab(from)
  local nr = api.nvim_tabpage_get_number(from)
  local cwd = vim.fn.getcwd(-1, nr)
  local tcd = vim.fn.haslocaldir(-1, nr) == 1
  vim.cmd(("%dtabnew"):format(nr))
  if tcd and vim.fn.getcwd() ~= cwd then
    vim.cmd.tcd(vim.fn.fnameescape(cwd))
  end
  tab = api.nvim_get_current_tabpage()
  return api.nvim_get_current_win()
end

---@class NvimDiff.EditTabOpts
---@field path string Absolute path of the file on disk.
---@field lnum? integer Line to put the cursor on, clamped to the file; 1 when omitted.

--- Show `opts.path` in the edit tabpage, opening the tabpage first when there is none, and
--- put the cursor on `opts.lnum`. False, after an error, when the window cannot take the
--- buffer. A missing file is not an error here: it opens empty, as `:edit` would.
---@param opts NvimDiff.EditTabOpts
---@return boolean ok
function M.open(opts)
  local win = edit_window() or open_tab(api.nvim_get_current_tabpage())
  api.nvim_set_current_win(win)
  local buf = vim.fn.bufadd(opts.path)
  vim.fn.bufload(buf)
  local hidden = vim.o.hidden
  vim.o.hidden = true
  local ok, err = pcall(api.nvim_win_set_buf, win, buf)
  vim.o.hidden = hidden
  if not ok then
    log.error("cannot edit %s: %s", opts.path, tostring(err))
    return false
  end
  -- A PR review's head pane opens the real file read-only (`scene/filebuf.lua`); it is the
  -- same buffer, and editing is the point of this tab, so take it back.
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_set_option_value("readonly", false, { buf = buf })
  local last = api.nvim_buf_line_count(buf)
  local lnum = math.max(1, math.min(opts.lnum or 1, last))
  pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
  api.nvim_win_call(win, function()
    -- Open the user's folds over the line, as an LSP jump does.
    vim.cmd("silent! normal! zv")
  end)
  return true
end

--- Forget the retained tabpage. Exists for tests; the plugin never calls it.
function M.reset()
  tab = nil
end

return M
