local t = require("tests.harness")
local describe, it, before_each, expect = t.describe, t.it, t.before_each, t.expect

local config = require("nvim-diff.config")

describe("config", function()
  before_each(function()
    config.reset()
  end)

  it("runs on defaults before setup()", function()
    expect.falsy(config.did_setup())
    expect.eq("side_by_side", config.get().layout)
    expect.eq(5000, config.get().thresholds.structural_lines)
  end)

  it("merges a nested option without dropping its siblings", function()
    config.setup({ thresholds = { defer_lines = 10 } })
    expect.eq(10, config.get().thresholds.defer_lines)
    expect.eq(5000, config.get().thresholds.structural_lines)
    expect.eq("side_by_side", config.get().layout)
    expect.truthy(config.did_setup())
  end)

  it("starts from the defaults on every call, so setup() is not cumulative", function()
    config.setup({ layout = "unified" })
    config.setup({ diff = { structural = false } })
    expect.eq("side_by_side", config.get().layout)
    expect.eq(false, config.get().diff.structural)
  end)

  it("returns the merged table", function()
    local merged = config.setup({ layout = "unified" })
    expect.eq("unified", merged.layout)
    expect.eq(merged, config.get())
  end)

  it("hands out a private copy of the defaults", function()
    local defaults = config.get_defaults()
    defaults.layout = "unified"
    expect.eq("side_by_side", config.get_defaults().layout)
    expect.eq("side_by_side", config.get().layout)
  end)

  it("accepts an absent or empty option table", function()
    expect.no_error(function()
      config.setup()
    end)
    expect.no_error(function()
      config.setup({})
    end)
  end)

  describe("validation", function()
    it("names an unknown top-level option and lists the valid ones", function()
      local err = expect.errors(function()
        config.setup({ layuot = "unified" })
      end)
      expect.matches("unknown option `layuot`", err)
      expect.matches("valid here:.*thresholds", err)
    end)

    it("names an unknown nested option with its full path", function()
      local err = expect.errors(function()
        config.setup({ thresholds = { defer_bytes = 10 } })
      end)
      expect.matches("unknown option `thresholds%.defer_bytes`", err)
    end)

    it("reports a wrong type with the path and the expected type", function()
      local err = expect.errors(function()
        config.setup({ thresholds = { defer_lines = "lots" } })
      end)
      expect.matches("`thresholds%.defer_lines`: expected number, got string", err)
    end)

    it("reports a branch given a scalar", function()
      local err = expect.errors(function()
        config.setup({ diff = true })
      end)
      expect.matches("`diff`: expected table, got boolean", err)
    end)

    it("reports a value outside an enum", function()
      local err = expect.errors(function()
        config.setup({ layout = "three_way" })
      end)
      expect.matches("`layout`: expected one of side_by_side, unified", err)
    end)

    it("rejects a fractional or out-of-range number", function()
      expect.matches(
        "expected a whole number",
        expect.errors(function()
          config.setup({ buffers = { lru_size = 1.5 } })
        end)
      )
      expect.matches(
        "expected at least 1",
        expect.errors(function()
          config.setup({ buffers = { lru_size = 0 } })
        end)
      )
    end)

    it("reports every problem at once", function()
      local errors = config.validate({
        layout = 42,
        nope = 1,
        thresholds = { defer_lines = "x" },
      })
      expect.eq(3, #errors, table.concat(errors, " | "))
    end)

    it("leaves the active config alone when setup() fails", function()
      config.setup({ layout = "unified" })
      pcall(config.setup, { layout = "sideways" })
      expect.eq("unified", config.get().layout)
    end)

    it("accepts user-chosen keys in the free-form highlights table", function()
      expect.no_error(function()
        config.setup({
          highlights = {
            NvimDiffAddLine = { bg = "#003300" },
            NvimDiffDelLine = "DiffDelete",
          },
        })
      end)
      expect.eq("DiffDelete", config.get().highlights.NvimDiffDelLine)
    end)

    it("still type-checks the values in the highlights table", function()
      expect.matches(
        "`highlights%.NvimDiffAddLine`: expected table or string, got number",
        expect.errors(function()
          config.setup({ highlights = { NvimDiffAddLine = 7 } })
        end)
      )
    end)

    it("accepts an option that has no default", function()
      config.setup({ github = { host = "ghe.example.com" } })
      expect.eq("ghe.example.com", config.get().github.host)
      expect.eq("gh", config.get().github.bin)
    end)

    it("rejects options that are not a table at all", function()
      expect.matches(
        "expected a table of options",
        expect.errors(function()
          config.setup("layout=unified")
        end)
      )
    end)
  end)
end)
