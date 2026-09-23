-- The harness testing itself. If these fail, no other result in the suite means anything.

local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

describe("harness", function()
  describe("expect", function()
    it("compares tables by value", function()
      expect.eq({ a = { 1, 2 } }, { a = { 1, 2 } })
      expect.ne({ a = 1 }, { a = 2 })
    end)

    it("fails on a mismatch", function()
      local err = expect.errors(function()
        expect.eq(1, 2)
      end)
      expect.matches("expected 1", err)
      expect.matches("got 2", err)
    end)

    it("reports the spec file in the failure", function()
      local err = expect.errors(function()
        expect.truthy(false)
      end)
      expect.matches("harness_spec%.lua", err)
    end)

    it("matches a pattern", function()
      expect.matches("^ab", "abc")
      expect.errors(function()
        expect.matches("^b", "abc")
      end)
    end)

    it("fails when a call that should throw does not", function()
      expect.matches(
        "expected an error",
        expect.errors(function()
          expect.errors(function() end)
        end)
      )
    end)

    it("returns what no_error returned", function()
      expect.eq(
        42,
        expect.no_error(function()
          return 42
        end)
      )
    end)
  end)

  describe("hooks", function()
    local log = {}

    before_each(function()
      log[#log + 1] = "outer-before"
    end)

    after_each(function()
      log[#log + 1] = "outer-after"
    end)

    describe("nested", function()
      before_each(function()
        log[#log + 1] = "inner-before"
      end)

      it("runs outer hooks before inner ones", function()
        expect.eq({ "outer-before", "inner-before" }, log)
        log = {}
      end)

      it("runs hooks again for the next test", function()
        expect.eq({ "outer-after", "outer-before", "inner-before" }, log)
        log = {}
      end)
    end)
  end)
end)
