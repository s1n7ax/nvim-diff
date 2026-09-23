--- The plugin's internal event bus.
---
--- This is deliberately not a public hook table: the set of events is closed, subscribing
--- to a name that is not in it is an error, and nothing is mirrored to `User` autocmds.
--- When a user-facing hook surface is added it will be built on top of this, not by
--- opening this up.
---
--- Handlers run in subscription order. A handler that throws is reported and skipped, so
--- one bad subscriber cannot abort a render half-way.

local api = vim.api

local M = {}

--- The events that exist. Anything else is a typo.
---
--- * `diff_buf_ready(bufnr, ctx)` — a diff buffer's content is in place and it may be
---   rendered into. Fired with `bufnr` current.
--- * `view_opened(view)` / `view_closed(view)` — a view's windows have been created, or
---   are about to be torn down. Fired with the view's main window current.
---@enum NvimDiff.Event
M.events = {
  DIFF_BUF_READY = "diff_buf_ready",
  VIEW_OPENED = "view_opened",
  VIEW_CLOSED = "view_closed",
}

---@type table<string, true>
local known = {}
for _, name in pairs(M.events) do
  known[name] = true
end

---@type table<string, function[]>
local handlers = {}

---@param name string
local function assert_known(name)
  if not known[name] then
    local names = vim.tbl_values(M.events)
    table.sort(names)
    error(("nvim-diff: unknown event `%s` (known: %s)"):format(tostring(name), table.concat(names, ", ")), 2)
  end
end

--- Subscribe to an event.
---@param name NvimDiff.Event|string
---@param fn function Called with the event's arguments.
---@return fun() unsubscribe Idempotent.
function M.on(name, fn)
  assert_known(name)
  vim.validate("fn", fn, "function")
  local list = handlers[name]
  if not list then
    list = {}
    handlers[name] = list
  end
  list[#list + 1] = fn
  local removed = false
  return function()
    if removed then
      return
    end
    removed = true
    for i, candidate in ipairs(list) do
      if candidate == fn then
        table.remove(list, i)
        return
      end
    end
  end
end

--- Subscribe to the next occurrence of an event only.
---@param name NvimDiff.Event|string
---@param fn function
---@return fun() unsubscribe
function M.once(name, fn)
  vim.validate("fn", fn, "function")
  local unsubscribe
  unsubscribe = M.on(name, function(...)
    unsubscribe()
    fn(...)
  end)
  return unsubscribe
end

--- Fire an event in the current buffer and window.
---@param name NvimDiff.Event|string
---@param ... any Event arguments.
function M.emit(name, ...)
  assert_known(name)
  local list = handlers[name]
  if not list or #list == 0 then
    return
  end
  -- Iterate a copy: a handler is allowed to unsubscribe itself or others.
  for _, fn in ipairs(vim.list_slice(list)) do
    local ok, err = xpcall(fn, debug.traceback, ...)
    if not ok then
      require("nvim-diff.core.log").error("handler for `%s` failed: %s", name, err)
    end
  end
end

---@class NvimDiff.EventContext
---@field win? integer Window to make current while handlers run.
---@field buf? integer Buffer to make current while handlers run.

--- Fire an event with a given window and buffer current.
---
--- `buf` should be the buffer displayed in `win`; when it is not, the window is entered
--- first and the buffer through `nvim_buf_call`, which may fall back to the hidden
--- autocommand window and leave `win` no longer current.
---@param ctx NvimDiff.EventContext
---@param name NvimDiff.Event|string
---@param ... any Event arguments.
function M.emit_in(ctx, name, ...)
  assert_known(name)
  local argc = select("#", ...)
  local argv = { ... }
  local function fire()
    M.emit(name, unpack(argv, 1, argc))
  end

  local win = ctx.win and api.nvim_win_is_valid(ctx.win) and ctx.win or nil
  local buf = ctx.buf and api.nvim_buf_is_valid(ctx.buf) and ctx.buf or nil

  if win and buf and api.nvim_win_get_buf(win) ~= buf then
    api.nvim_win_call(win, function()
      api.nvim_buf_call(buf, fire)
    end)
  elseif win then
    api.nvim_win_call(win, fire)
  elseif buf then
    api.nvim_buf_call(buf, fire)
  else
    fire()
  end
end

--- Drop subscribers. Exists for tests and for view teardown.
---@param name? NvimDiff.Event|string Every event when omitted.
function M.clear(name)
  if name == nil then
    handlers = {}
    return
  end
  assert_known(name)
  handlers[name] = nil
end

--- How many handlers are subscribed to an event.
---@param name NvimDiff.Event|string
---@return integer
function M.count(name)
  assert_known(name)
  return handlers[name] and #handlers[name] or 0
end

return M
