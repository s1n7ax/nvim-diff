--- A throwaway `gh` for specs.
---
--- `tests/gitrepo.lua` gives git specs a real, throwaway repository to run against; there is
--- no throwaway GitHub to point `gh` at, so this gives `github/cmd.lua` specs the next best
--- thing — a real executable standing in for `gh`, so the tests still exercise the actual
--- subprocess boundary (argv building, the env allow-list, `-i` response parsing) rather than
--- mocking `github/cmd.lua` itself away.
---
--- `M.new(body)` takes the inside of a POSIX `case "$*" in ... esac` block and writes it to
--- a small shell script. Every call is logged (its `"$*"` and its own environment) before the
--- case runs, so a spec can assert on exactly what `github/cmd.lua` sent.

local M = {}

---@type string[]
local created = {}

---@param body string The inside of a `case "$*" in ... esac`, matching on `"$*"`.
---@return string bin Path to set as `config.github.bin`.
---@return fun(): string[] calls Every call's `"$*"`, in order, oldest first.
---@return fun(name: string): string? env A variable's value in the *last* call's environment.
function M.new(body)
  local dir = vim.fn.tempname() .. "-ghstub"
  vim.fn.mkdir(dir, "p")
  created[#created + 1] = dir
  local bin, calls_log, env_log = dir .. "/gh", dir .. "/calls.log", dir .. "/env.log"

  -- NUL-separated, not newline-separated: a logged call's own argv (a GraphQL query, say)
  -- may contain real newlines, and those must not be mistaken for record breaks.
  local script = table.concat({
    "#!/bin/sh",
    "printf '%s\\0' \"$*\" >> '" .. calls_log .. "'",
    "env > '" .. env_log .. "'",
    'case "$*" in',
    body,
    "esac",
  }, "\n")
  local fd = assert(io.open(bin, "w"))
  fd:write(script)
  fd:close()
  vim.uv.fs_chmod(bin, 448) -- 0700

  local function calls()
    if not vim.uv.fs_stat(calls_log) then
      return {}
    end
    local f = assert(io.open(calls_log, "rb"))
    local content = f:read("*a")
    f:close()
    local out = vim.split(content, "\0", { plain = true })
    if out[#out] == "" then
      out[#out] = nil
    end
    return out
  end

  local function env(name)
    if not vim.uv.fs_stat(env_log) then
      return nil
    end
    for line in io.lines(env_log) do
      local key, value = line:match("^([^=]+)=(.*)$")
      if key == name then
        return value
      end
    end
    return nil
  end

  return bin, calls, env
end

--- Delete every stub `new` made. Call from `after_each`.
function M.cleanup()
  for _, dir in ipairs(created) do
    vim.fn.delete(dir, "rf")
  end
  created = {}
end

return M
