--- Windows that give back what is opened in them: a PR review's panes, file panel, note and
--- thread list. Such a window is not 'winfixbuf', so whatever opens another buffer there —
--- `:edit`, a picker's pick (`:buffer`, `nvim_win_set_buf`), a quickfix entry, an LSP jump —
--- does not fail. Once the command is over the window gets its own buffer back, with the
--- window options, folds and view it had (Neovim keeps the first two per buffer and window),
--- and the owner is told where the jump went, to show it somewhere else.
---
---     catch.watch(win, buf, { on_jump = function(jump) ... end })
---
--- The buffer must outlive leaving the window: 'bufhidden' empty or `hide`, not `wipe`.
--- A window stops being watched when it closes, when `unwatch` is called, and when
--- `scene/window.lua` makes it a pane anew.

local api = vim.api

local M = {}

--- Where a jump out of a watched window went.
---@class NvimDiff.PaneJump
---@field buf integer The buffer it showed in the window.
---@field lnum integer The cursor there.
---@field col integer 0-based byte column.
--- The jump loaded `buf`: it was read from disk in the window, so nobody else had it.
---@field read boolean

---@class NvimDiff.CatchOpts
---@field on_jump fun(jump: NvimDiff.PaneJump)
--- Called with the window once it has its buffer and view back, before `on_jump`.
---@field on_back? fun(win: integer)

---@class NvimDiff.Catch
---@field buf integer
---@field opts NvimDiff.CatchOpts
---@field view? table The window's view (`winsaveview()`) as the buffer last left it.
---@field read table<integer, true> Buffers read from disk in the window: only a jump puts one there.
---@field pending boolean A jump is on its way in.

--- Watched windows.
---@type table<integer, NvimDiff.Catch>
local watched = {}

---@type integer?
local group

--- Give `win` its buffer back and tell the owner, once the jump that put another one there
--- is over: at the next cursor move, before the screen is redrawn, or the next tick,
--- whichever comes first. When the buffer comes in (`BufWinEnter`) the jump has not put the
--- cursor on its target yet.
---@param win integer
---@param c NvimDiff.Catch
local function back(win, c)
  if not c.pending then
    return
  end
  c.pending = false
  if watched[win] ~= c or not api.nvim_win_is_valid(win) or not api.nvim_buf_is_valid(c.buf) then
    return
  end
  local now = api.nvim_win_get_buf(win)
  if now == c.buf then
    c.read = {}
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  local jump = { buf = now, lnum = cursor[1], col = cursor[2], read = c.read[now] == true }
  c.read = {}
  -- Hidden, as with `:hide`: with 'nohidden' the jump's buffer would be unloaded on its way
  -- out, its language server detached (which redraws the screen, the window showing it).
  local hidden = vim.o.hidden
  vim.o.hidden = true
  local ok, err = pcall(api.nvim_win_set_buf, win, c.buf)
  vim.o.hidden = hidden
  if not ok then
    error(err, 0)
  end
  if c.view then
    local view = c.view
    api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end
  if c.opts.on_back then
    c.opts.on_back(win)
  end
  c.opts.on_jump(jump)
end

local function setup()
  if group then
    return
  end
  group = api.nvim_create_augroup("nvim-diff.catch", { clear = true })
  api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(args)
      -- Also when the cursor only goes to another window: the last one before a jump counts.
      local win = api.nvim_get_current_win()
      local c = watched[win]
      if c and args.buf == c.buf and not c.pending then
        c.view = vim.fn.winsaveview()
      end
    end,
  })
  api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      local c = watched[api.nvim_get_current_win()]
      if c and args.buf ~= c.buf then
        c.read[args.buf] = true
      end
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      -- `nvim_win_set_buf` on a window makes it current while its autocmds run.
      local win = api.nvim_get_current_win()
      local c = watched[win]
      if not c or c.pending or args.buf == c.buf then
        return
      end
      c.pending = true
      api.nvim_create_autocmd("CursorMoved", {
        group = group,
        once = true,
        callback = function()
          back(win, c)
        end,
      })
      vim.schedule(function()
        back(win, c)
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      watched[tonumber(args.match) or -1] = nil
    end,
  })
end

--- Watch `win`, which shows `buf`: take it off 'winfixbuf', and give back any other buffer
--- opened in it (see the module comment). Watching it again replaces the earlier watch.
---@param win integer
---@param buf integer
---@param opts NvimDiff.CatchOpts
function M.watch(win, buf, opts)
  setup()
  api.nvim_set_option_value("winfixbuf", false, { win = win, scope = "local" })
  watched[win] = { buf = buf, opts = opts, read = {}, pending = false }
end

--- Stop watching `win` — only for `buf`, when given: a scene closing leaves alone the watch
--- the next scene in the same window (a layout flip) set already. A jump already on its way
--- in stays where it went. No-op for a window not watched.
---@param win integer
---@param buf? integer
function M.unwatch(win, buf)
  local c = watched[win]
  if c and (buf == nil or c.buf == buf) then
    watched[win] = nil
  end
end

--- Whether `win` is watched.
---@param win integer
---@return boolean
function M.is_watched(win)
  return watched[win] ~= nil
end

return M
