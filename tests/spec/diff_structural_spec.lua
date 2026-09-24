local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local line = require("nvim-diff.diff.line")
local structural = require("nvim-diff.diff.structural")

--- Line diff and structural diff of two Lua files.
---@param old string[]
---@param new string[]
---@param opts? NvimDiff.Diff.StructuralOpts
---@return NvimDiff.Diff? s
---@return string|NvimDiff.Diff why_or_line
local function sdiff(old, new, opts)
  local d = line.diff(old, new)
  local s, why = structural.diff(d, old, new, "lua", opts)
  return s, why or d
end

--- The text each span of `side`'s line `lnum` covers.
---@param s NvimDiff.Diff
---@param lines string[]
---@param side NvimDiff.Side
---@param lnum integer
---@return string[]?
local function lit(s, lines, side, lnum)
  local spans = s.tokens[side][lnum]
  if not spans then
    return nil
  end
  local out = {}
  for i, sp in ipairs(spans) do
    out[i] = lines[lnum]:sub(sp[1] + 1, sp[2])
  end
  return out
end

--- A Lua fixture whose `, ` separators all sit in code, never in strings or comments, so
--- breaking a line after any of them is a pure reformat.
local FIXTURE = {
  "local M = {}",
  "",
  "-- Add two numbers, then scale the sum by a factor that the caller chooses.",
  "function M.scale(a, b, factor)",
  "  local sum = a + b",
  "  return sum * (factor or 1)",
  "end",
  "",
  "function M.pairs(list, fn)",
  "  local out = {}",
  "  for i, v in ipairs(list) do",
  "    out[#out + 1] = fn(i, v, #list)",
  "  end",
  "  return out",
  "end",
  "",
  "local config = { width = 80, height = 24, title = 'main' }",
  "",
  "function M.describe(x, y)",
  "  if x > y then",
  "    return M.scale(x, y, 2)",
  "  end",
  "  return M.pairs({ x, y }, function(i, v, n)",
  "    return i * v + n",
  "  end)",
  "end",
  "",
  "M.config = config",
  "return M",
}

describe("diff.structural", function()
  it("keeps the line diff's hunks, rows and runs, and leaves the line diff alone", function()
    local old = { "local a = 1", "local b = 2", "local c = 3" }
    local new = { "local a = 1", "local b = 20", "local c = 3", "local d = 4" }
    local s, d = sdiff(old, new)
    assert(s)
    ---@cast d NvimDiff.Diff
    expect.eq("structural", s.token_source)
    expect.eq("line", d.token_source)
    expect.eq(d.rows, s.rows)
    expect.eq(d.unchanged, s.unchanged)
    expect.eq(d.fillers, s.fillers)
    expect.eq(#d.hunks, #s.hunks)
    for i, h in ipairs(d.hunks) do
      expect.eq(
        { h.old_start, h.old_count, h.new_start, h.new_count, h.row },
        { s.hunks[i].old_start, s.hunks[i].old_count, s.hunks[i].new_start, s.hunks[i].new_count, s.hunks[i].row }
      )
      expect.eq(h.rows, s.hunks[i].rows)
    end
    expect.eq({ "2" }, lit(s, old, "old", 2))
    expect.eq({ "20" }, lit(s, new, "new", 2))
    -- The lookups still work on the copy.
    expect.eq("changed", s:kind("new", 2))
    expect.eq(4, s:row_of("new", 4))
  end)

  it("marks a call split across lines as a pure reformat, with nothing lit", function()
    local old = { "local x = f(a, b)", "return x" }
    local new = { "local x = f(", "  a,", "  b", ")", "return x" }
    local s = sdiff(old, new)
    assert(s)
    expect.eq(1, #s.hunks)
    expect.truthy(s.hunks[1].formatting_only)
    expect.eq({}, s.tokens.old[1])
    expect.eq({}, s.tokens.new[1])
    expect.eq(nil, s.tokens.new[2])
  end)

  it("lights only the changed node when a reformat hides an edit", function()
    local old = { "vim.api.nvim_set_hl(0, 'NvimDiffAdd', { link = 'DiffAdd' })" }
    local new = { "vim.api.nvim_set_hl(", "  0,", "  'NvimDiffAdd',", "  { link = 'DiffAdded' }", ")" }
    local s = sdiff(old, new)
    assert(s)
    expect.falsy(s.hunks[1].formatting_only)
    expect.eq({ "'DiffAdd'" }, lit(s, old, "old", 1))
    -- Line 4 is partly new (the table around the string is not), so it carries a span.
    expect.eq({ "'DiffAdded'" }, lit(s, new, "new", 4))
    for _, lnum in ipairs({ 1, 2, 3, 5 }) do
      expect.eq(nil, lit(s, new, "new", lnum) and #lit(s, new, "new", lnum) > 0 or nil)
    end
  end)

  it("widens a change to the largest node that is wholly new, and no further", function()
    local old = { "local x = f(a)" }
    local new = { "local x = f(a, g(1, 2))" }
    local s = sdiff(old, new)
    assert(s)
    -- The comma is new but its argument list is not; the call `g(1, 2)` is new whole.
    expect.eq({ ",", "g(1, 2)" }, lit(s, new, "new", 1))
    expect.eq({}, lit(s, old, "old", 1))
  end)

  it("leaves a wholly new line uniform, with no bright token", function()
    local old = { "local a = 1" }
    local new = { "local a = 1", "local b = g(2)" }
    local s = sdiff(old, new)
    assert(s)
    expect.eq(nil, s.tokens.new[2])
    expect.falsy(s.hunks[1].formatting_only)
  end)

  it("treats rewrapped comments as formatting, and changed words as a change", function()
    local old = { "-- one two three", "-- four", "return 1" }
    local rewrapped = { "-- one two", "-- three four", "return 1" }
    local s = sdiff(old, rewrapped)
    assert(s)
    expect.truthy(s.hunks[1].formatting_only)

    local edited = { "-- one two", "-- 3 four", "return 1" }
    s = sdiff(old, edited)
    assert(s)
    expect.falsy(s.hunks[1].formatting_only)
    expect.eq({ "3" }, lit(s, edited, "new", 2))

    s = sdiff(old, rewrapped, { normalize_comments = false })
    assert(s)
    expect.falsy(s.hunks[1].formatting_only)
  end)

  it("never calls a hunk a reformat when a changed multi-line token reaches into it", function()
    local old = { "local s = [[", "abc", "def", "]]", "return s" }
    local new = { "local s = [[", "abc", "dXf", "]]", "return s" }
    local s = sdiff(old, new)
    assert(s)
    expect.eq(1, #s.hunks)
    expect.falsy(s.hunks[1].formatting_only)
    expect.eq({ "dXf" }, lit(s, new, "new", 3))
  end)

  it("does not collapse added or removed blank lines", function()
    local s = sdiff({ "local a = 1", "local b = 2" }, { "local a = 1", "", "", "local b = 2" })
    assert(s)
    expect.falsy(s.hunks[1].formatting_only)
  end)

  it("gives up with a reason on no parser, a syntax error, size and NUL bytes", function()
    local d = line.diff({ "a" }, { "b" })
    local s, why = structural.diff(d, { "a" }, { "b" }, "no_such_lang_here")
    expect.eq(nil, s)
    expect.matches("no parser", why)

    s, why = sdiff({ "local x = 1" }, { "local x = = 1" })
    expect.eq(nil, s)
    expect.eq("syntax error", why)

    s, why = sdiff({ "local x = 1", "local y = 2" }, { "local x = 2" }, { max_lines = 1 })
    expect.eq(nil, s)
    expect.matches("over 1 lines", why)

    s, why = sdiff({ "local x = 'a\nb'" }, { "local x = 1" })
    expect.eq(nil, s)
    expect.eq("NUL bytes", why)

    expect.truthy(structural.has_parser("lua"))
    expect.falsy(structural.has_parser("no_such_lang_here"))
  end)

  it("diffs empty sides and identical files", function()
    local s = sdiff({}, { "local a = 1" })
    assert(s)
    expect.eq(nil, s.tokens.new[1])
    s = sdiff(FIXTURE, FIXTURE)
    assert(s)
    expect.eq({}, s.hunks)
  end)

  it("calls every hunk of a random reformat formatting-only (random, 40 seeds)", function()
    for seed = 1, 40 do
      math.randomseed(seed)
      local new = {}
      for _, l in ipairs(FIXTURE) do
        local indent, body = l:match("^(%s*)(.*)$")
        if body ~= "" and math.random() < 0.3 then
          indent = (" "):rep(math.random(0, 6))
        end
        -- Break after some code commas; comments hold none by construction but the first.
        local parts = body:sub(1, 2) == "--" and { body } or vim.split(body, ", ", { plain = true })
        local cur = indent .. parts[1]
        for k = 2, #parts do
          if math.random() < 0.3 then
            new[#new + 1] = cur .. ","
            cur = indent .. "  " .. parts[k]
          else
            cur = cur .. ", " .. parts[k]
          end
        end
        new[#new + 1] = cur
      end
      local s, why = sdiff(FIXTURE, new)
      assert(s, why)
      for _, h in ipairs(s.hunks) do
        if h.old_count > 0 and h.new_count > 0 then
          expect.truthy(
            h.formatting_only,
            ("seed %d: hunk %d is not formatting-only\n%s\n%s"):format(
              seed,
              h.index,
              table.concat({ unpack(FIXTURE, h.old_start, h.old_start + h.old_count - 1) }, "\n"),
              table.concat({ unpack(new, h.new_start, h.new_start + h.new_count - 1) }, "\n")
            )
          )
        end
      end
      for _, side in ipairs({ "old", "new" }) do
        for lnum, spans in pairs(s.tokens[side]) do
          expect.eq({}, spans, ("seed %d: %s line %d lit"):format(seed, side, lnum))
        end
      end
    end
  end)

  it("keeps spans inside their lines, sorted and disjoint, on hunk lines only (random)", function()
    for seed = 1, 40 do
      math.randomseed(seed)
      local new = vim.deepcopy(FIXTURE)
      for _ = 1, math.random(1, 5) do
        local i = math.random(#new)
        local choice = math.random(3)
        if choice == 1 then
          new[i] = new[i]:gsub("%d+", function(n)
            return tostring(tonumber(n) + 1)
          end)
        elseif choice == 2 then
          table.insert(new, i, "local extra" .. i .. " = " .. i)
        else
          new[i] = new[i]:gsub("(%a+)", "%1x", 1)
        end
      end
      local d = line.diff(FIXTURE, new)
      local s, why = structural.diff(d, FIXTURE, new, "lua")
      if s then
        for _, side in ipairs({ "old", "new" }) do
          local lines = side == "old" and FIXTURE or new
          for lnum, spans in pairs(s.tokens[side]) do
            expect.truthy(
              s:kind(side, lnum),
              ("seed %d: %s line %d has tokens outside a hunk"):format(seed, side, lnum)
            )
            local prev = 0
            for _, sp in ipairs(spans) do
              expect.truthy(
                sp[1] >= prev and sp[1] < sp[2] and sp[2] <= #lines[lnum],
                ("seed %d: bad span %s on %s line %d"):format(seed, vim.inspect(sp), side, lnum)
              )
              prev = sp[2]
            end
          end
        end
      else
        expect.eq("syntax error", why, ("seed %d"):format(seed))
      end
    end
  end)
end)
