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

  it("spins in the header while the post is on its way, and runs the post as a task", function()
    local during, c
    c = start({
      on_submit = function()
        require("nvim-diff.core.job").await({ "sleep", "0.2" })
        during = { posting = c.posting, winbar = vim.wo[c.win].winbar }
        return true
      end,
    })
    type_text(c, { "slow" })
    expect.eq(true, c:submit())
    expect.truthy(during.posting, "the spinner was running")
    expect.matches("posting the comment…", during.winbar)
    expect.eq(nil, c.posting)
  end)

  it("keeps the split with the error when the post raises", function()
    local c = start({
      on_submit = function()
        error("boom", 0)
      end,
    })
    type_text(c, { "x" })
    expect.eq(false, c:submit())
    expect.matches("boom", errors_shown(c.buf)[1])
    expect.eq(nil, c.posting)
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

  it("maps submit in normal and insert mode, cancel in normal mode only", function()
    local c = start()
    local descs = {}
    for _, mode in ipairs({ "n", "i" }) do
      descs[mode] = {}
      for _, m in ipairs(api.nvim_buf_get_keymap(c.buf, mode)) do
        descs[mode][m.desc or ""] = m.lhs
      end
      expect.eq("<C-S>", descs[mode]["nvim-diff: post the comment"], mode)
    end
    expect.eq("q", descs.n["nvim-diff: cancel the comment"])
    expect.eq(nil, descs.i["nvim-diff: cancel the comment"], "typing never cancels")
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

  describe("editing a posted comment", function()
    it("opens with its text, and cancels without asking while it is unchanged", function()
      local asked = false
      compose.confirm = function()
        asked = true
        return false
      end
      local c, seen = start({ lines = { "old words", "second" } })
      expect.eq({ "old words", "second" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
      expect.eq(false, c:is_changed())
      expect.eq(true, c:cancel())
      expect.falsy(asked)
      expect.eq({ "cancelled" }, seen.done)
    end)

    it("asks before discarding a change", function()
      local asked
      compose.confirm = function(prompt)
        asked = prompt
        return false
      end
      local c = start({ lines = { "old words" } })
      type_text(c, { "new words" })
      expect.eq(false, c:cancel())
      expect.eq("Discard this comment?", asked)
      expect.eq({ "new words" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
    end)

    it("lets an unchanged edit go with its window", function()
      local c = start({ lines = { "old words" } })
      vim.cmd("quit")
      expect.truthy(vim.wait(500, function()
        return not api.nvim_buf_is_valid(c.buf)
      end, 10))
    end)
  end)

  describe("a split where :w must not post", function()
    it("only warns on :w, posts empty text when allowed, and names itself", function()
      local c, seen = start({
        write_posts = false,
        allow_empty = true,
        noun = "review verdict",
        keys = { submit = "<C-s>", cancel = "<C-c>" },
      })
      vim.cmd("write")
      expect.eq({}, seen.texts)
      expect.matches("<C%-s> post · <C%-c> cancel", vim.wo[c.win].winbar)
      expect.falsy(vim.wo[c.win].winbar:find(":w", 1, true))
      expect.eq(true, c:submit())
      expect.eq({ "" }, seen.texts)
    end)
  end)

  describe("suggestion", function()
    ---@param buf integer
    ---@param mode string
    ---@return string?
    local function suggest_lhs(buf, mode)
      for _, m in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
        if m.desc == "nvim-diff: insert a suggestion of the commented lines" then
          return m.lhs
        end
      end
      return nil
    end

    it("is mapped only where there are commented lines, and named in the header", function()
      local plain = start()
      expect.eq(nil, suggest_lhs(plain.buf, "n"))
      plain:close()
      local c = start({ suggestion = { lines = { "x" } } })
      expect.eq("<C-G>s", suggest_lhs(c.buf, "n"))
      expect.eq("<C-G>s", suggest_lhs(c.buf, "i"))
      expect.matches("<C%-g>s suggestion", vim.wo[c.win].winbar)
    end)

    it("fills a blank line with a suggestion block and puts the cursor on its code", function()
      local c = start({ suggestion = { lines = { "local a = 1", "  return a" } } })
      vim.cmd.stopinsert()
      expect.eq(true, c:insert_suggestion())
      expect.eq({ "```suggestion", "local a = 1", "  return a", "```" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
      expect.eq({ 2, 0 }, api.nvim_win_get_cursor(c.win))
    end)

    it("goes under a line that has text, through the key", function()
      local c = start({ suggestion = { lines = { "b = 2" } } })
      vim.cmd.stopinsert()
      type_text(c, { "Rename this:" })
      api.nvim_win_set_cursor(c.win, { 1, 0 })
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-g>s", true, false, true), "x", false)
      expect.eq({ "Rename this:", "```suggestion", "b = 2", "```" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
    end)

    it("uses a longer fence when the lines hold one", function()
      expect.eq("```", compose.fence({ "a", "`b`" }))
      expect.eq("````", compose.fence({ "```lua", "x", "```" }))
      expect.eq("`````", compose.fence({ "  ````" }))
    end)

    it("inserts nothing where there are no lines to suggest on, and does not offer it", function()
      local c = start({ suggestion = { reason = "a suggestion replaces lines of the new side only" } })
      expect.falsy(vim.wo[c.win].winbar:find("suggestion", 1, true))
      expect.eq(false, c:insert_suggestion())
      expect.eq({ "" }, api.nvim_buf_get_lines(c.buf, 0, -1, false))
    end)
  end)
end)
