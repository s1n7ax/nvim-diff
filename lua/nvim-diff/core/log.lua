--- Level-filtered notifications.
---
--- Everything the user should see goes through here so `log.level` in the config is the
--- single volume knob. Messages are formatted lazily: below the active level a call costs
--- one table lookup and one comparison.

local M = {}

---@type table<string, integer>
local ORDER = {
  trace = 1,
  debug = 2,
  info = 3,
  warn = 4,
  error = 5,
  off = 6,
}

---@type table<string, integer>
local VIM_LEVEL = {
  trace = vim.log.levels.TRACE,
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

---@return integer
local function threshold()
  return ORDER[require("nvim-diff.config").get().log.level] or ORDER.warn
end

---@param level "trace"|"debug"|"info"|"warn"|"error"
---@param msg string Format string when extra arguments follow.
---@param ... any
local function log(level, msg, ...)
  if ORDER[level] < threshold() then
    return
  end
  local text = select("#", ...) > 0 and msg:format(...) or msg
  vim.schedule(function()
    vim.notify(text, VIM_LEVEL[level], { title = "nvim-diff" })
  end)
end

---@param msg string
---@param ... any
function M.trace(msg, ...)
  log("trace", msg, ...)
end

---@param msg string
---@param ... any
function M.debug(msg, ...)
  log("debug", msg, ...)
end

---@param msg string
---@param ... any
function M.info(msg, ...)
  log("info", msg, ...)
end

---@param msg string
---@param ... any
function M.warn(msg, ...)
  log("warn", msg, ...)
end

---@param msg string
---@param ... any
function M.error(msg, ...)
  log("error", msg, ...)
end

return M
