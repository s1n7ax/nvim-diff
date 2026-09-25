local t = require("tests.harness")
local describe, it, after_each, expect = t.describe, t.it, t.after_each, t.expect

local comment = require("nvim-diff.review.comment")
local fileview = require("nvim-diff.scene.fileview")
local line = require("nvim-diff.diff.line")

--- 30 lines, changed at 2 and 28: commentable 1–5 and 25–30 on each side.
local OLD, NEW = {}, {}
for i = 1, 30 do
  OLD[i] = "l" .. i
  NEW[i] = "l" .. i
end
NEW[2] = "L2"
NEW[28] = "L28"

---@type NvimDiff.FileView?
local current

---@param layout NvimDiff.Layout
---@return NvimDiff.FileView
local function open(layout)
  current = fileview.open({
    diff = line.diff(OLD, NEW),
    old = { lines = OLD, label = "a/f.lua" },
    new = { lines = NEW, label = "b/f.lua" },
    mode = "line",
    layout = layout,
  })
  return current
end

describe("review comment", function()
  after_each(function()
    if current then
      current:close()
      current = nil
    end
    vim.cmd("silent! tabonly")
  end)

  it("anchors a line of either pane to its own side", function()
    local f = open("side_by_side")
    local wins = f.scene.wins
    -- Pane buffer line = file line + 1, for the header.
    expect.eq({ path = "f.lua", side = "new", line = 2 }, comment.target(f, "f.lua", wins.new, 3))
    expect.eq({ path = "f.lua", side = "old", line = 2 }, comment.target(f, "f.lua", wins.old, 3))
    expect.eq({ path = "f.lua", side = "old", line = 30 }, comment.target(f, "f.lua", wins.old, 31))
  end)

  it("turns a selection into a range, in either direction", function()
    local f = open("side_by_side")
    local want = { path = "f.lua", side = "new", line = 4, start_side = "new", start_line = 1 }
    expect.eq(want, comment.target(f, "f.lua", f.scene.wins.new, 2, 5))
    expect.eq(want, comment.target(f, "f.lua", f.scene.wins.new, 5, 2))
    expect.eq({ path = "f.lua", side = "new", line = 4 }, comment.target(f, "f.lua", f.scene.wins.new, 5, 5))
  end)

  it("refuses lines outside the diff, ranges across hunks, and the header", function()
    local f = open("side_by_side")
    local win = f.scene.wins.new
    local target, why = comment.target(f, "f.lua", win, 11)
    expect.falsy(target)
    expect.matches("lines in the diff", why)
    target, why = comment.target(f, "f.lua", win, 4, 27)
    expect.falsy(target)
    expect.matches("within one hunk", why)
    target, why = comment.target(f, "f.lua", win, 1)
    expect.falsy(target)
    expect.matches("no file line", why)
    expect.falsy((comment.target(f, "f.lua", vim.api.nvim_get_current_win() + 1000, 3)))
  end)

  it("in unified, anchors a deleted line to old, others to new, and ranges across sides", function()
    local f = open("unified")
    local u = f.scene --[[@as NvimDiff.Unified]]
    local deleted, added, ctx = u:buf_line("old", 2), u:buf_line("new", 2), u:buf_line("new", 3)
    expect.eq({ path = "f.lua", side = "old", line = 2 }, comment.target(f, "f.lua", u.win, deleted))
    expect.eq({ path = "f.lua", side = "new", line = 3 }, comment.target(f, "f.lua", u.win, ctx))
    expect.eq(
      { path = "f.lua", side = "new", line = 2, start_side = "old", start_line = 2 },
      comment.target(f, "f.lua", u.win, deleted, added)
    )
  end)

  it("names what a comment or a reply is on", function()
    expect.eq("Comment on f.lua L2", comment.header({ path = "f.lua", side = "new", line = 2 }))
    expect.eq("Comment on f.lua old L2", comment.header({ path = "f.lua", side = "old", line = 2 }))
    expect.eq(
      "Comment on f.lua L1–4",
      comment.header({ path = "f.lua", side = "new", line = 4, start_side = "new", start_line = 1 })
    )
    expect.eq(
      "Comment on f.lua old L2 – L2",
      comment.header({ path = "f.lua", side = "new", line = 2, start_side = "old", start_line = 2 })
    )
    local thread = {
      path = "f.lua",
      side = "new",
      line = 2,
      comments = { { author = "alice", body = "why is this\n  here at all, when the other one is enough" } },
    }
    expect.eq(
      "Reply to alice on f.lua L2: why is this here at all, when the other…",
      comment.reply_header(thread --[[@as NvimDiff.GitHub.Thread]], 40)
    )
    expect.eq("Edit your comment on f.lua L2", comment.edit_header(thread --[[@as NvimDiff.GitHub.Thread]]))
    local file = { path = "f.lua", subject = "file", comments = {} }
    expect.eq("Edit your comment on the file f.lua", comment.edit_header(file --[[@as NvimDiff.GitHub.Thread]]))
    expect.eq("Comment on the file f.lua", comment.file_header("f.lua"))
  end)

  it("finds the user's own comments, in order", function()
    local a =
      { id = "a", comments = { { id = "a1", viewer_did_author = false }, { id = "a2", viewer_did_author = true } } }
    local b = { id = "b", comments = { { id = "b1", viewer_did_author = true } } }
    local own = comment.own({ a, b } --[[@as NvimDiff.GitHub.Thread[] ]])
    expect.eq(
      { "a2", "b1" },
      vim.tbl_map(function(x)
        return x.comment.id
      end, own)
    )
    expect.eq(a, own[1].thread)
  end)

  it("suggests on the new side's lines only", function()
    local f = open("side_by_side")
    expect.eq({ lines = { "L2" } }, comment.suggestion_for_target(f, { path = "f.lua", side = "new", line = 2 }))
    expect.eq(
      { lines = { "l1", "L2", "l3" } },
      comment.suggestion_for_target(f, { path = "f.lua", side = "new", line = 3, start_side = "new", start_line = 1 })
    )
    expect.matches("new side only", comment.suggestion_for_target(f, { path = "f.lua", side = "old", line = 2 }).reason)
    local across = { path = "f.lua", side = "new", line = 2, start_side = "old", start_line = 2 }
    expect.matches("new side only", comment.suggestion_for_target(f, across).reason)
    local thread = { path = "f.lua", side = "new", line = 28, start_line = 27, subject = "line", comments = {} }
    expect.eq(
      { lines = { "l27", "L28" } },
      comment.suggestion_for_thread(f, "f.lua", thread --[[@as NvimDiff.GitHub.Thread]])
    )
    expect.matches(
      "not showing",
      comment.suggestion_for_thread(f, "g.lua", thread --[[@as NvimDiff.GitHub.Thread]]).reason
    )
    thread.outdated = true
    expect.matches(
      "no longer",
      comment.suggestion_for_thread(f, "f.lua", thread --[[@as NvimDiff.GitHub.Thread]]).reason
    )
    local file = { path = "f.lua", subject = "file", comments = {} }
    expect.matches(
      "file comment",
      comment.suggestion_for_thread(f, "f.lua", file --[[@as NvimDiff.GitHub.Thread]]).reason
    )
  end)
end)
