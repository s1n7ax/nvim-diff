--- Headless test runner.
---
---     nvim --clean --headless -l tests/runner.lua [pattern]
---
--- `pattern` is a Lua pattern matched against each test's full name. Exits non-zero when
--- anything fails, so `make test` is a usable gate.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.normalize(vim.fn.fnamemodify(script, ":p:h:h"))

vim.opt.runtimepath:prepend(root)
-- So specs can `require("tests.harness")` without the test code living in `lua/`.
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

local harness = require("tests.harness")

local filter = _G.arg and _G.arg[1] or nil
if filter == "" then
  filter = nil
end

local spec_files = vim.fn.glob(root .. "/tests/spec/*_spec.lua", false, true)
table.sort(spec_files)

for _, file in ipairs(spec_files) do
  harness.file = vim.fs.basename(file)
  local chunk, load_err = loadfile(file)
  if not chunk then
    io.stderr:write("failed to load " .. file .. ": " .. tostring(load_err) .. "\n")
    os.exit(1)
  end
  local ok, run_err = pcall(chunk)
  if not ok then
    io.stderr:write("failed to collect " .. file .. ": " .. tostring(run_err) .. "\n")
    os.exit(1)
  end
end

---@param text string
local function write(text)
  io.stdout:write(text)
  io.stdout:flush()
end

--- Keep the assertion message and the first few frames; drop the runner's own stack.
---@param err string
---@return string
local function format_error(err)
  local lines = {}
  local frames = 0
  for line in tostring(err):gmatch("[^\n]+") do
    if line:match("^%s*stack traceback:") then
      frames = 1
    elseif frames > 0 then
      if frames > 3 or line:match("tests/runner%.lua") then
        break
      end
      frames = frames + 1
      lines[#lines + 1] = "        " .. vim.trim(line)
    else
      lines[#lines + 1] = "      " .. line
    end
  end
  return table.concat(lines, "\n")
end

local passed, failed, skipped = 0, 0, 0
---@type string[]
local failures = {}
local current_suite = nil
local started = vim.uv.hrtime()

for _, test in ipairs(harness.tests) do
  if filter and not test.name:find(filter) then
    skipped = skipped + 1
  else
    if test.suite ~= current_suite then
      current_suite = test.suite
      write("\n" .. current_suite .. "\n")
    end

    local name = test.name:sub(#test.suite + 2)
    local ok, err = true, nil
    for _, before in ipairs(test.before) do
      if ok then
        ok, err = xpcall(before, debug.traceback)
      end
    end
    if ok then
      ok, err = xpcall(test.fn, debug.traceback)
    end
    for _, after in ipairs(test.after) do
      local after_ok, after_err = xpcall(after, debug.traceback)
      if ok and not after_ok then
        ok, err = false, after_err
      end
    end

    if ok then
      passed = passed + 1
      write("  ok   " .. name .. "\n")
    else
      failed = failed + 1
      write("  FAIL " .. name .. "\n" .. format_error(err) .. "\n")
      failures[#failures + 1] = test.file .. ": " .. test.name
    end
  end
end

local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

write(("\n%d passed, %d failed"):format(passed, failed))
if skipped > 0 then
  write((", %d filtered out"):format(skipped))
end
write((" in %.0f ms\n"):format(elapsed_ms))

if failed > 0 then
  write("\nfailed:\n")
  for _, name in ipairs(failures) do
    write("  " .. name .. "\n")
  end
end

os.exit(failed == 0 and 0 or 1)
