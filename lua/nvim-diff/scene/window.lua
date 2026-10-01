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

--- Window options a pane sets besides `OPTIONS`: `pane`'s own and the folding ones
--- (`scene/folds.lua`).
local PANE_EXTRA = { "statuscolumn", "signcolumn", "winbar", "winfixbuf", "foldenable", "foldlevel" }

--- Every window option a pane sets.
---@type string[]
M.PANE_OPTIONS = vim.list.unique(vim.list_extend(vim.tbl_keys(M.OPTIONS), PANE_EXTRA))
table.sort(M.PANE_OPTIONS)

--- The window options a real file's pane (`scene/filebuf.lua`) hands back to the user's
--- values rather than the global ones, in the order they are set back: `foldexpr` (which
--- a pane leaves alone, but which a filetype plugin or an `LspAttach` handler may set with
--- `foldmethod`) before `foldmethod`, so an `expr` fold method starts on the right
--- expression. Not `diff` (it would put the window in diff mode) and not `winfixbuf` (the
--- window is about to show another buffer): those go back to the global value.
M.USER_OPTIONS = {
  "foldexpr",
  "foldenable",
  "foldlevel",
  "foldminlines",
  "foldcolumn",
  "scrollbind",
  "cursorbind",
  "wrap",
  "number",
  "relativenumber",
  "signcolumn",
  "spell",
  "list",
  "statuscolumn",
  "winbar",
  "foldmethod",
}

--- The fold buffer nvim-ufo keeps for `buf`, when ufo is loaded and has one. Internal API
--- of ufo's, so every use is guarded.
---@param buf integer
---@return table?
local function ufo_fold(buf)
  if not package.loaded["ufo"] then
    return nil
  end
  local ok, fb = pcall(function()
    return require("ufo.fold").get(buf)
  end)
  return ok and fb or nil
end

--- nvim-ufo replaces a window's manual folds with ones from its providers, which hides
--- changed rows and unmirrors the panes. Keep it attached, so its `foldtext` still draws
--- the folds, but with no providers: what its own `provider_selector` returning `''` does.
---@param buf integer
local function ufo_off(buf)
  local fb = ufo_fold(buf)
  if fb then
    fb.providers = { "" }
  end
end

--- Give nvim-ufo its fold providers for `buf` back once no pane shows it: ufo reads them
--- from the user's `provider_selector` again, and works the folds out the next time the
--- buffer shows in a window (marked pending: ufo does that only for a pending buffer).
--- Nothing is worked out now, so no late answer can land in a pane that takes the buffer
--- again meanwhile.
---@param buf integer
function M.ufo_restore(buf)
  local fb = ufo_fold(buf)
  if not fb then
    return
  end
  fb.providers = nil
  if fb.status ~= "stop" then
    fb.status = "pending"
  end
end

--- `win`'s values of `USER_OPTIONS`.
---@param win integer
---@return table<string, any>
function M.user_options(win)
  local values = {}
  for _, name in ipairs(M.USER_OPTIONS) do
    values[name] = api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  return values
end

---@class NvimDiff.PaneWinOpts
---@field statuscolumn string
--- A window-local `winbar` (the pane's header, when its buffer has no header line). Without
--- it, a pane header `winbar` found in the window is taken back to the global value.
---@field winbar? string
---@field signcolumn? string Default `"no"`.

--- Show `buf` in `win` and make `win` a diff pane. Returns the options (`USER_OPTIONS`)
--- `win` had for `buf` before the pane's own: what Neovim gave it from the last window the
--- buffer was in and what `BufWinEnter` handlers set, for `reset` to hand back. Nil when
--- they are a pane's, left by a pane that was never reset.
---@param win integer
---@param buf integer
---@param opts NvimDiff.PaneWinOpts
---@return table<string, any>? user
function M.pane(win, buf, opts)
  api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
  -- Before: ufo works the folds of a buffer it knows out on `BufWinEnter`. After: a buffer
  -- it attaches to there.
  ufo_off(buf)
  api.nvim_win_set_buf(win, buf)
  ufo_off(buf)
  local user = M.user_options(win)
  if user.statuscolumn:find("NvimDiffContextSeparator", 1, true) then
    user = nil
  elseif vim.startswith(user.winbar, sidebyside.WINBAR_START) then
    user.winbar = ""
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
  return user
end

--- Take a pane window back to the user's settings: its folds deleted, every option a pane
--- sets back to `user`'s value (`USER_OPTIONS`, from `pane`) or else to its global value
--- (`:setlocal {option}<`), the global highlights. For a real file's buffer
--- (`scene/filebuf.lua`): measured, Neovim gives a window newly showing a buffer the
--- options and manual folds of a window showing it, or of the one it was last shown in, so
--- the pane's would reach the user's own window on the file — and the user's (an `expr`
--- fold method, a statusline plugin's `statuscolumn`) reach it when handed back here.
---@param win integer
---@param user? table<string, any>
function M.reset(win, user)
  local names = {}
  for _, name in ipairs(M.PANE_OPTIONS) do
    if not (user and user[name] ~= nil) then
      names[#names + 1] = name .. "<"
    end
  end
  api.nvim_win_call(win, function()
    -- `zE` needs the manual folds the pane set, so before 'foldmethod' goes back.
    vim.cmd("silent! normal! zE")
    vim.cmd("silent! setlocal " .. table.concat(names, " "))
    if user then
      for _, name in ipairs(M.USER_OPTIONS) do
        if user[name] ~= nil then
          pcall(api.nvim_set_option_value, name, user[name], { win = win, scope = "local" })
        end
      end
    end
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
