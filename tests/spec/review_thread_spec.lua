local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local line = require("nvim-diff.diff.line")
local thread = require("nvim-diff.review.thread")

local NONE = {}

--- A thread; `NONE` in `extra` removes that field.
---@param extra table
---@return NvimDiff.GitHub.Thread
local function T(extra)
  local x = vim.tbl_extend("force", {
    id = "T",
    path = "f.lua",
    side = "new",
    line = 2,
    resolved = false,
    outdated = false,
    subject = "line",
    comments = {
      { id = "c1", author = "alice", body = "why 9090?\nbecause", created_at = "2026-09-01T12:00:00Z" },
      { id = "c2", author = "bob", body = "ok", created_at = "2026-09-02T08:00:00Z" },
    },
  }, extra)
  for k, v in pairs(x) do
    if v == NONE then
      x[k] = nil
    end
  end
  return x
end

---@param vls NvimDiff.VirtLine[]
---@return string[]
local function texts(vls)
  return vim.tbl_map(thread.text, vls)
end

describe("review.thread", function()
  local d = line.diff({ "a", "b", "c" }, { "a", "B", "n", "c" })

  it("anchors a thread under its line on its own side, or says where it goes instead", function()
    expect.eq({ d:row_of("new", 2), "line" }, { thread.anchor(T({}), d) })
    expect.eq({ d:row_of("old", 3), "line" }, { thread.anchor(T({ side = "old", line = 3 }), d) })
    expect.eq({ nil, "outdated" }, { thread.anchor(T({ outdated = true }), d) })
    expect.eq({ nil, "outdated" }, { thread.anchor(T({ line = NONE, original_line = 9 }), d) })
    expect.eq({ nil, "file" }, { thread.anchor(T({ subject = "file", line = NONE }), d) })
    expect.eq({ nil, "off_file" }, { thread.anchor(T({ line = 5 }), d) })
    expect.eq({ nil, "off_file" }, { thread.anchor(T({ side = "old", line = 4 }), d) })
  end)

  it("collapses to one line: author, first line, reply count, state badge", function()
    local vl = thread.collapsed_line(T({}), { width = 80 })
    local text = thread.text(vl)
    expect.eq(80, vim.fn.strdisplaywidth(text))
    expect.matches("^╶▸ alice  why 9090%?  · 1 reply ─.-  UNRESOLVED $", text)
    expect.eq("NvimDiffThreadBorder", vl[1][2])
    expect.eq("NvimDiffThreadAuthor", vl[2][2])
    expect.eq({ " UNRESOLVED ", "NvimDiffThreadBadgeUnresolved" }, vl[#vl])
    local one = T({ comments = { { id = "c", author = "a", body = "x", created_at = "" } } })
    expect.matches("· 0 replies ", thread.text(thread.collapsed_line(one)))
  end)

  it("dims a resolved thread but for its green badge, and marks it with a check", function()
    local vl = thread.collapsed_line(T({ resolved = true, resolved_by = "carol" }))
    expect.matches("^╶▸ ✓ alice .*  ✓ RESOLVED $", thread.text(vl))
    for i, chunk in ipairs(vl) do
      if i == #vl then
        expect.eq("NvimDiffThreadBadgeResolved", chunk[2])
      else
        expect.truthy(chunk[2] == "" or chunk[2] == "NvimDiffThreadResolved", chunk[2])
      end
    end
  end)

  it("fills the width, dropping the meta, then the badge, before the excerpt when narrow", function()
    local long = T({ comments = { { id = "c", author = "alice", body = ("word "):rep(40), created_at = "" } } })
    local text = thread.text(thread.collapsed_line(long, { width = 70 }))
    expect.eq(70, vim.fn.strdisplaywidth(text))
    expect.matches("…  · 0 replies ─  UNRESOLVED $", text)
    expect.eq(
      "╶▸ alice  word word word w…  UNRESOLVED ",
      thread.text(thread.collapsed_line(long, { width = 40 }))
    )
    expect.eq("╶▸ alice  word word word word…", thread.text(thread.collapsed_line(long, { width = 30 })))
  end)

  it("expands to a bubble: meta and badge on top, every comment, bodies wrapped", function()
    local x = T({
      start_line = 1,
      comments = {
        { id = "c1", author = "alice", body = "one two three four five six", created_at = "2026-09-01T12:00:00Z" },
        { id = "c2", author = "bob", body = "\n\tok\r\n\n", created_at = "2026-09-02T08:00:00Z" },
      },
    })
    expect.eq({
      "╭─▾ L1–2 · 2 comm… ─ ─╮",
      "│ alice  2026-09-01   │",
      "│   one two three     │",
      "│   four five six     │",
      "├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤",
      "│ bob  2026-09-02     │",
      "│       ok            │",
      "╰─────────────────────╯",
    }, texts(thread.expanded_lines(x, { width = 23 })))
    local top = texts(thread.expanded_lines(T({ line = NONE, outdated = true, original_line = 40 }), {
      label = "outdated",
      width = 60,
    }))[1]
    expect.eq(60, vim.fn.strdisplaywidth(top))
    expect.matches("^╭─▾ outdated · L40 · 2 comments ─.-  UNRESOLVED  ─╮$", top)
    expect.eq(
      100,
      vim.fn.strdisplaywidth(texts(thread.expanded_lines(T({}), { width = 300 }))[1]),
      "a bubble stops growing at MAX_WIDTH"
    )
  end)

  it("wraps at words, splits a word longer than the width, and never loops on a wide character", function()
    expect.eq({ "aaa bb", "c" }, thread.wrap("aaa bb c", 6))
    expect.eq({ "abcd", "efgh", "ij" }, thread.wrap("abcdefghij", 4))
    expect.eq({ "界", "界" }, thread.wrap("界界", 1))
    expect.eq({ "(no text)" }, thread.body_lines("  \n\n"))
  end)
end)
