--- A test harness small enough to read in one sitting.
---
--- There is no busted and no luarocks on this toolchain, and vendoring mini.test would put
--- a second plugin in the repo to test a plugin that has no runtime dependencies. So:
--- `describe`/`it`/`before_each`/`after_each` plus an `expect` table, collected at require
--- time and run by `tests/runner.lua` inside `nvim --headless -l`.
---
--- Tests run in the real editor. `vim.api`, buffers and windows are all available, and a
--- test that needs one should create one rather than mock it.

local M = {}

---@class NvimDiff.Test
---@field name string Full name, suites joined with a space.
---@field fn fun()
---@field before fun()[]
---@field after fun()[]
---@field suite string
---@field file string

---@type NvimDiff.Test[]
M.tests = {}

--- Spec file currently being loaded. The runner sets it; tests are stamped with it.
M.file = "?"

---@type string[]
local suite_stack = {}
---@type table<integer, fun()[]>
local before_stack = {}
---@type table<integer, fun()[]>
local after_stack = {}

---@param stack table<integer, fun()[]>
---@return fun()[]
local function collect(stack)
  local out = {}
  for depth = 1, #suite_stack do
    for _, fn in ipairs(stack[depth] or {}) do
      out[#out + 1] = fn
    end
  end
  return out
end

--- Group tests. May nest.
---@param name string
---@param fn fun()
function M.describe(name, fn)
  suite_stack[#suite_stack + 1] = name
  local depth = #suite_stack
  before_stack[depth] = {}
  after_stack[depth] = {}
  local ok, err = pcall(fn)
  before_stack[depth] = nil
  after_stack[depth] = nil
  table.remove(suite_stack)
  if not ok then
    error(err, 0)
  end
end

--- Register a test.
---@param name string
---@param fn fun()
function M.it(name, fn)
  M.tests[#M.tests + 1] = {
    name = table.concat(suite_stack, " ") .. " " .. name,
    suite = table.concat(suite_stack, " "),
    file = M.file,
    fn = fn,
    before = collect(before_stack),
    after = collect(after_stack),
  }
end

--- Run before every test in the enclosing `describe`, outermost first.
---@param fn fun()
function M.before_each(fn)
  local depth = #suite_stack
  local list = before_stack[depth]
  list[#list + 1] = fn
end

--- Run after every test in the enclosing `describe`, outermost first.
---@param fn fun()
function M.after_each(fn)
  local depth = #suite_stack
  local list = after_stack[depth]
  list[#list + 1] = fn
end

---@param value any
---@return string
local function show(value)
  if type(value) == "string" then
    return ("%q"):format(value)
  end
  return vim.inspect(value)
end

---@param msg string
---@param ... any
local function fail(msg, ...)
  local text = select("#", ...) > 0 and msg:format(...) or msg
  -- Level 3: report the line in the spec file, not in here.
  error(debug.traceback(text, 3), 0)
end

M.expect = {}

--- Deep equality, with a readable diff on failure.
---@param expected any
---@param actual any
---@param context? string
function M.expect.eq(expected, actual, context)
  if not vim.deep_equal(expected, actual) then
    fail("expected %s\n     got %s%s", show(expected), show(actual), context and ("\n      (" .. context .. ")") or "")
  end
end

---@param unexpected any
---@param actual any
function M.expect.ne(unexpected, actual)
  if vim.deep_equal(unexpected, actual) then
    fail("expected anything but %s", show(unexpected))
  end
end

---@param value any
---@param context? string
function M.expect.truthy(value, context)
  if not value then
    fail("expected a truthy value, got %s%s", show(value), context and ("\n      (" .. context .. ")") or "")
  end
end

---@param value any
---@param context? string
function M.expect.falsy(value, context)
  if value then
    fail("expected a falsy value, got %s%s", show(value), context and ("\n      (" .. context .. ")") or "")
  end
end

--- Assert a Lua pattern matches.
---@param pattern string
---@param actual string
function M.expect.matches(pattern, actual)
  if type(actual) ~= "string" or not actual:find(pattern) then
    fail("expected a string matching %s\n     got %s", show(pattern), show(actual))
  end
end

--- Assert `fn` throws, and return the error for further assertions.
---@param fn fun()
---@param pattern? string Lua pattern the error message must contain.
---@return string error
function M.expect.errors(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    fail("expected an error, but the call returned")
  end
  err = type(err) == "string" and err or vim.inspect(err)
  if pattern and not err:find(pattern) then
    fail("expected an error matching %s\n     got %s", show(pattern), show(err))
  end
  return err
end

--- Assert `fn` does not throw, and return what it returned.
---@generic T
---@param fn fun(): T
---@return T
function M.expect.no_error(fn)
  local ok, result = pcall(fn)
  if not ok then
    fail("expected no error, got %s", tostring(result))
  end
  return result
end

return M
