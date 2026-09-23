local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local health = require("nvim-diff.health")

--- Capture what `:checkhealth` would print.
---@return table report
local function record()
  local report = { sections = {}, ok = {}, warn = {}, error = {}, info = {}, current = nil }
  local real = vim.health

  ---@param list table[]
  ---@return fun(msg: string, advice?: string[])
  local function collector(list)
    return function(msg, advice)
      local text = advice and (msg .. "\n" .. table.concat(advice, "\n")) or msg
      list[#list + 1] = { report.current, text }
    end
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.health = {
    start = function(name)
      report.sections[#report.sections + 1] = name
      report.current = name
    end,
    ok = collector(report.ok),
    warn = collector(report.warn),
    error = collector(report.error),
    info = collector(report.info),
  }
  report.restore = function()
    vim.health = real
  end
  return report
end

---@param entries table[]
---@param pattern string
---@return boolean
local function has(entries, pattern)
  for _, entry in ipairs(entries) do
    if tostring(entry[2]):find(pattern) then
      return true
    end
  end
  return false
end

describe("health", function()
  local report

  before_each(function()
    config.reset()
    report = record()
  end)

  after_each(function()
    report.restore()
    config.reset()
  end)

  it("reports every section", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.eq(
      { "Neovim", "Configuration", "git", "gh (GitHub PR review)", "treesitter (structural diff)", "PR worktrees" },
      report.sections
    )
  end)

  it("passes the Neovim checks on this version", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.eq({}, report.error)
    expect.truthy(has(report.ok, "`vim%.text%.diff` is available"))
  end)

  it("finds git and reports its version", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.truthy(has(report.ok, "^git %d+%.%d+%.%d+$"), vim.inspect(report.ok))
  end)

  it("errors when git is missing and warns when gh is", function()
    config.setup({
      git = { bin = "nvim-diff-no-such-binary" },
      github = { bin = "nvim-diff-no-such-binary" },
    })
    health.check()
    expect.truthy(has(report.error, "not found on PATH"), "a missing git is fatal")
    expect.truthy(has(report.warn, "PR review is unavailable"), "a missing gh is not")
  end)

  it("probes parsers with get_string_parser and counts them", function()
    config.setup({ github = { bin = "nvim-diff-no-such-binary" } })
    health.check()
    expect.truthy(
      has(report.ok, "probed parsers installed") or has(report.warn, "no parser found"),
      vim.inspect({ report.ok, report.warn })
    )
  end)

  it("reports the configuration it is running on", function()
    config.setup({
      layout = "unified",
      github = { bin = "nvim-diff-no-such-binary" },
      highlights = { NvimDiffAddLine = "DiffAdd" },
    })
    health.check()
    expect.truthy(has(report.ok, "`setup%(%)` has been called"))
    expect.truthy(has(report.info, "layout: unified"))
    expect.truthy(has(report.info, "highlight overrides: NvimDiffAddLine"))
  end)

  it("says so when setup() has not run", function()
    config.reset()
    health.check()
    expect.truthy(has(report.info, "has not been called"))
  end)

  describe("orphan worktrees", function()
    it("returns a list in a repository and an explanation outside one", function()
      local paths, err = health.orphan_worktrees()
      expect.falsy(err, tostring(err))
      expect.eq("table", type(paths))

      local cwd = vim.uv.cwd()
      vim.uv.chdir(vim.fs.normalize(vim.env.TMPDIR or "/tmp"))
      local outside, outside_err = health.orphan_worktrees()
      vim.uv.chdir(cwd)
      expect.eq({}, outside)
      expect.matches("not inside a git repository", tostring(outside_err))
    end)

    it("reports nothing when git itself is unavailable", function()
      config.setup({ git = { bin = "nvim-diff-no-such-binary" } })
      local paths, err = health.orphan_worktrees()
      expect.eq({}, paths)
      expect.matches("git is unavailable", tostring(err))
    end)
  end)
end)
