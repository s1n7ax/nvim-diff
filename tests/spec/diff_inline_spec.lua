local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local inline = require("nvim-diff.diff.inline")

--- The text each span covers, so a failure reads as words rather than column numbers.
---@param line string
---@param spans NvimDiff.Diff.Span[]
---@return string[]
local function covered(line, spans)
  local out = {}
  for i, s in ipairs(spans) do
    out[i] = line:sub(s[1] + 1, s[2])
  end
  return out
end

describe("diff.inline tokenize", function()
  it("splits into words, blank runs and single punctuation", function()
    local texts, starts, ends = inline.tokenize("local x_1 = f(a,  b)")
    expect.eq({ "local", " ", "x_1", " ", "=", " ", "f", "(", "a", ",", "  ", "b", ")" }, texts)
    expect.eq(0, starts[1])
    expect.eq(5, ends[1])
    expect.eq(20, ends[#ends])
  end)

  it("keeps a multi-byte character inside one token", function()
    local texts = inline.tokenize("naïve café")
    expect.eq({ "naïve", " ", "café" }, texts)
  end)

  it("keeps a newline (a buffer NUL) as a token of its own", function()
    local texts = inline.tokenize("a\n b")
    expect.eq({ "a", "\n", " ", "b" }, texts)
  end)
end)

describe("diff.inline spans", function()
  it("returns nothing for identical lines", function()
    local a, b = inline.spans("same", "same")
    expect.eq({}, a)
    expect.eq({}, b)
  end)

  it("lights up only the changed token", function()
    local old, new = "  port = 8080,", "  port = 9090,"
    local a, b = inline.spans(old, new)
    expect.eq({ "8080" }, covered(old, a))
    expect.eq({ "9090" }, covered(new, b))
  end)

  it("returns 0-based end-exclusive byte columns", function()
    local a, b = inline.spans("x = 1", "x = 22")
    expect.eq({ { 4, 5 } }, a)
    expect.eq({ { 4, 6 } }, b)
  end)

  it("leaves the old side empty for a pure insertion", function()
    local old, new = "f(a)", "f(a, b)"
    local a, b = inline.spans(old, new)
    expect.eq({}, a)
    expect.eq({ ", b" }, covered(new, b))
  end)

  it("leaves the new side empty for a pure deletion", function()
    local old, new = "call(x, y)", "call(x)"
    local a, b = inline.spans(old, new)
    expect.eq({ ", y" }, covered(old, a))
    expect.eq({}, b)
  end)

  it("finds several separate changes on one line", function()
    local old = "local a = foo(1, bar, 3)"
    local new = "local b = foo(1, baz, 3)"
    local a, b = inline.spans(old, new)
    expect.eq({ "a", "bar" }, covered(old, a))
    expect.eq({ "b", "baz" }, covered(new, b))
  end)

  it("treats a whitespace-only change as a change to the blank run", function()
    local old, new = "a = 1", "a  = 1"
    local a, b = inline.spans(old, new)
    expect.eq({ " " }, covered(old, a))
    expect.eq({ "  " }, covered(new, b))
  end)

  it("never splits a multi-byte character", function()
    local old, new = "x = 'héllo'", "x = 'hèllo'"
    local a, b = inline.spans(old, new)
    expect.eq({ "héllo" }, covered(old, a))
    expect.eq({ "hèllo" }, covered(new, b))
  end)

  it("survives a newline inside a line", function()
    local old, new = "a\nb c", "a\nb d"
    local a, b = inline.spans(old, new)
    expect.eq({ "c" }, covered(old, a))
    expect.eq({ "d" }, covered(new, b))
  end)

  it("does not confuse an escaped newline with a literal backslash-n", function()
    local old, new = "x \\n y", "x \n y"
    local a, b = inline.spans(old, new)
    expect.eq({ "\\n" }, covered(old, a))
    expect.eq({ "\n" }, covered(new, b))
  end)

  it("reports the differing middle as one span above max_bytes", function()
    local old = ("a"):rep(50) .. "X" .. ("b"):rep(50)
    local new = ("a"):rep(50) .. "YZ" .. ("b"):rep(50)
    local a, b = inline.spans(old, new, { max_bytes = 20 })
    expect.eq({ { 50, 51 } }, a)
    expect.eq({ { 50, 52 } }, b)
  end)

  it("pulls the rough span back onto character boundaries", function()
    -- é is C3 A9, è is C3 A8: the common byte prefix ends mid-character.
    local a, b = inline.spans("é", "è", { max_bytes = 0 })
    expect.eq({ { 0, 2 } }, a)
    expect.eq({ { 0, 2 } }, b)
  end)
end)
