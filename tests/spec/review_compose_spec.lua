local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local compose = require("nvim-diff.review.compose")
local config = require("nvim-diff.config")

local api = vim.api

---@param buf integer
---@return string[]
local function errors_shown(buf)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, compose.ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      out[#out + 1] = vl[1][1]
    end
  end
  return out
end

---@param c NvimDiff.Compose
---@param lines string[]
local function type_text(c, lines)
  api.nvim_buf_set_lines(c.buf, 0, -1, false, lines)
end

describe("review compose", function()
  local real_confirm, home, open

  before_each(function()
    config.reset()
    config.setup({ log = { level = "off" } })
    real_confirm = compose.confirm
    vim.cmd("silent! tabonly | silent! only")
    home = api.nvim_get_current_win()
    open = {}
  end)

  after_each(function()
    vim.cmd.stopinsert()
    compose.confirm = real_confirm
    for _, c in ipairs(open) do
      if api.nvim_buf_is_valid(c.buf) then
        api.nvim_buf_delete(c.buf, { force = true })
      end
    end
    vim.cmd("silent! tabonly | silent! only")
    config.reset()
  end)

  ---@param opts? table
  ---@return NvimDiff.Compose c
  ---@return { texts: string[], done: string[] } seen
  local function start(opts)
    local seen = { texts = {}, done = {} }
    local c = compose.open(vim.tbl_extend("force", {
      header = "Comment on a.lua L12",
      on_submit = function(text)
        seen.texts[#seen.texts + 1] = text
        return true
      end,
      on_done = function(how)
        seen.done[#seen.done + 1] = how
      end,
    }, opts or {}))
    open[#open + 1] = c
    return c, seen
  end

  it("opens a markdown split across the bottom of the tab, focused, headed, never a file", function()
    vim.cmd("vsplit")
    local c = start()
    expect.eq(c.win, api.nvim_get_current_win())
    expect.eq(10, api.nvim_win_get_height(c.win))
    expect.eq("markdown", vim.bo[c.buf].filetype)
    expect.eq("acwrite", vim.bo[c.buf].buftype)
    expect.eq(false, vim.bo[c.buf].swapfile)
    expect.eq(true, vim.wo[c.win].spell)
    expect.matches("Comment on a%.lua L12", vim.wo[c.win].winbar)
    expect.matches("<C%-s> or :w post", vim.wo[c.win].winbar)
    -- Below both windows of the vertical split: the layout is a column with the split last.
    local layout = vim.fn.winlayout()
    expect.eq("col", layout[1])
    expect.eq({ "leaf", c.win }, layout[2][#layout[2]])
  end)

  it("posts the text on submit, closes and returns focus", function()
    local c, seen = start()
    type_text(c, { "first line", "", "second", "", "" })
    expect.eq(true, c:submit())
    expect.eq({ "first line\n\nsecond" }, seen.texts)
    expect.eq({ "posted" }, seen.done)
    expect.falsy(api.nvim_buf_is_valid(c.buf))
    expect.eq(home, api.nvim_get_current_win())
  end)

  it("posts on :w", function()
    local c, seen = start()
    type_text(c, { "via write" })
    vim.cmd("write")
    expect.eq({ "via write" }, seen.texts)
    expect.falsy(api.nvim_buf_is_valid(c.buf))
  end)

  it("keeps the split, the text and the error when the post fails", function()
    local c, seen = start({
      on_submit = function()
        return false, "Validation Failed: line must be part of the diff"
      end,
    })
    type_text(c, { "keep me" })
    expect.eq(false, c:submit())
    expect.truthy(api.nvim_win_is_valid(c.win))
    expect.eq({ "keep me" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
    expect.eq({ "✗ not posted: Validation Failed: line must be part of the diff" }, errors_shown(c.buf))
    expect.eq({}, seen.done)
    expect.eq(true, vim.bo[c.buf].modified, "still unsent")
  end)

  it("does not post an empty comment", function()
    local c, seen = start()
    type_text(c, { "  ", "" })
    expect.eq(false, c:submit())
    expect.eq({}, seen.texts)
    expect.eq({ "✗ not posted: the comment is empty" }, errors_shown(c.buf))
  end)

  it("cancels an empty split without asking", function()
    local asked = false
    compose.confirm = function()
      asked = true
      return false
    end
    local c, seen = start()
    expect.eq(true, c:cancel())
    expect.falsy(asked)
    expect.eq({ "cancelled" }, seen.done)
    expect.falsy(api.nvim_buf_is_valid(c.buf))
  end)

  it("asks before discarding text, and keeps it when told to", function()
    local answer = false
    compose.confirm = function()
      return answer
    end
    local c, seen = start()
    type_text(c, { "half a thought" })
    expect.eq(false, c:cancel())
    expect.truthy(api.nvim_win_is_valid(c.win))
    expect.eq({}, seen.done)
    answer = true
    expect.eq(true, c:cancel())
    expect.eq({ "cancelled" }, seen.done)
    expect.falsy(api.nvim_buf_is_valid(c.buf))
  end)

  it("maps submit and cancel in normal and insert mode", function()
    local c = start()
    for _, mode in ipairs({ "n", "i" }) do
      local descs = {}
      for _, m in ipairs(api.nvim_buf_get_keymap(c.buf, mode)) do
        descs[m.desc or ""] = m.lhs
      end
      expect.eq("<C-S>", descs["nvim-diff: post the comment"], mode)
      expect.eq("<C-C>", descs["nvim-diff: cancel the comment"], mode)
    end
  end)

  it("keeps a draft whose window was closed some other way, and shows it again", function()
    local c, seen = start()
    type_text(c, { "draft" })
    vim.cmd("quit")
    vim.wait(100, function()
      return c.win == nil
    end)
    expect.truthy(api.nvim_buf_is_valid(c.buf))
    expect.eq(true, c:is_open())
    expect.eq({}, seen.done)
    c:show()
    expect.eq(c.buf, api.nvim_win_get_buf(api.nvim_get_current_win()))
    expect.eq({ "draft" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
  end)

  it("lets an empty draft go with its window", function()
    local c, seen = start()
    vim.cmd("quit")
    expect.truthy(vim.wait(500, function()
      return not api.nvim_buf_is_valid(c.buf)
    end, 10))
    expect.eq({ "closed" }, seen.done)
  end)

  it("keeps an orphaned draft's text in a listed buffer and stops posting it", function()
    local c, seen = start()
    type_text(c, { "unsent" })
    local name = c:orphan()
    expect.eq(api.nvim_buf_get_name(c.buf), name)
    expect.eq(true, vim.bo[c.buf].buflisted)
    expect.eq({ "closed" }, seen.done)
    expect.eq(false, c:submit())
    expect.eq({}, seen.texts)
    expect.matches("review ended", vim.wo[c.win].winbar)
    vim.cmd("close")
    vim.wait(50)
    expect.truthy(api.nvim_buf_is_valid(c.buf), "survives its window")
  end)

  it("closes an empty split when orphaned", function()
    local c = start()
    expect.eq(nil, c:orphan())
    expect.falsy(api.nvim_buf_is_valid(c.buf))
  end)
end)
