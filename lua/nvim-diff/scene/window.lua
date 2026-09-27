--- Diff pane windows: the window-local options that keep two panes aligned.
---
--- Every option is set with `scope = "local"` (`:setlocal`), so nothing leaks into the
--- global value or into windows the user opens later — except through a buffer that
--- outlives the pane, which `reset` handles. The global-only options that affect diffs
--- (`diffopt`, `diffexpr`, `scrollopt`, `splitkeep`) are never touched.

local hl = require("nvim-diff.ui.hl")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

local M = {}

--- Options every pane window carries.
---
--- * `diff` off: the plugin renders diffs itself; native diff highlights beat extmarks.
--- * `scrollbind`/`cursorbind` off: they fight the corrector (`scene/scrollsync.lua`), and
---   `cursorbind` pairs raw line numbers, which drift after the first hunk.
--- * `wrap` off: a long line on one side only would take more screen rows there.
--- * folds manual with `foldminlines = 0`, so a one-line fold closes; context folding owns
---   the rest of the fold options.
--- * `number` on only so `statuscolumn` has a column to draw in.
M.OPTIONS = {
  diff = false,
  scrollbind = false,
  cursorbind = false,
  wrap = false,
  foldmethod = "manual",
  foldcolumn = "0",
  foldminlines = 0,
  number = true,
  relativenumber = false,
  signcolumn = "no",
  spell = false,
  list = false,
}

---@class NvimDiff.PaneWinOpts
---@field statuscolumn string
--- A window-local `winbar` (the pane's header, when its buffer has no header line). Without
--- it, a pane header `winbar` found in the window is taken back to the global value.
---@field winbar? string
---@field signcolumn? string Default `"no"`.

--- Show `buf` in `win` and make `win` a diff pane.
---@param win integer
---@param buf integer
---@param opts NvimDiff.PaneWinOpts
function M.pane(win, buf, opts)
  api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
  api.nvim_win_set_buf(win, buf)
  -- nvim-ufo attaches on `BufWinEnter` and replaces a window's manual folds with ones from
  -- its providers, which hides changed rows and unmirrors the panes. Keep it attached, so
  -- its `foldtext` still draws the folds, but with no providers: what its own
  -- `provider_selector` returning `''` does.
  if package.loaded["ufo"] then
    pcall(function()
      local fb = require("ufo.fold").get(buf)
      if fb then
        fb.providers = { "" }
      end
    end)
  end
  for name, value in pairs(M.OPTIONS) do
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  api.nvim_set_option_value("statuscolumn", opts.statuscolumn, { win = win, scope = "local" })
  if opts.signcolumn then
    api.nvim_set_option_value("signcolumn", opts.signcolumn, { win = win, scope = "local" })
  end
  if opts.winbar then
    api.nvim_set_option_value("winbar", opts.winbar, { win = win, scope = "local" })
  elseif
    vim.startswith(api.nvim_get_option_value("winbar", { win = win, scope = "local" }), sidebyside.WINBAR_START)
  then
    -- Left by a pane with no header line: the window was reused (a layout flip), or the
    -- buffer is a kept one and Neovim restored the window options it last had. An empty
    -- local value falls back to the global one.
    api.nvim_set_option_value("winbar", "", { win = win, scope = "local" })
  end
  api.nvim_set_option_value("winfixbuf", true, { win = win, scope = "local" })
  hl.apply_window(win)
end

--- Window options a pane sets besides `OPTIONS`: `pane`'s own and the folding ones
--- (`scene/folds.lua`).
local PANE_EXTRA = { "statuscolumn", "signcolumn", "winbar", "winfixbuf", "foldenable", "foldlevel" }

--- Take a pane window back to the user's settings: its folds deleted, every option a pane
--- sets back to its global value (`:setlocal {option}<`), the global highlights. For a real
--- file's buffer (`scene/filebuf.lua`): measured, Neovim gives a window newly showing a
--- buffer the options and manual folds of a window showing it, or of the one it was last
--- shown in, so the pane's would reach the user's own window on the file.
---@param win integer
function M.reset(win)
  local names = vim.list_extend(vim.tbl_keys(M.OPTIONS), PANE_EXTRA)
  for i, name in ipairs(names) do
    names[i] = name .. "<"
  end
  api.nvim_win_call(win, function()
    -- `zE` needs the manual folds the pane set, so before 'foldmethod' goes back.
    vim.cmd("silent! normal! zE")
    vim.cmd("silent! setlocal " .. table.concat(names, " "))
  end)
  api.nvim_win_set_hl_ns(win, 0)
end

--- An empty throwaway buffer, wiped as soon as it is replaced: what a window a scene gives
--- up (but does not close) shows until the next scene takes it.
---@return integer buf
function M.scratch()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  return buf
end

return M
