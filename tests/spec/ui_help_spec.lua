local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local help = require("nvim-diff.ui.help")

local api = vim.api

describe("key menu", function()
  local buf, ran

  before_each(function()
    config.reset()
    config.setup({ log = { level = "off" } })
    vim.cmd("silent! tabonly | silent! only")
    vim.g.mapleader = " "
    buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(0, buf)
    ran = {}
    vim.keymap.set("n", "<leader>cc", function()
      ran[#ran + 1] = "comment"
    end, { buffer = buf, desc = "nvim-diff: comment on this line" })
    vim.keymap.set("n", "]t", function()
      ran[#ran + 1] = "next"
    end, { buffer = buf, desc = "nvim-diff: next comment thread" })
    vim.keymap.set("n", "zE", "<Nop>", { buffer = buf, desc = "nvim-diff: folds are mirrored" })
    vim.keymap.set("n", "x", "<Nop>", { buffer = buf, desc = "not ours" })
    help.attach(buf)
  end)

  after_each(function()
    vim.g.mapleader = nil
    vim.cmd("silent! tabonly | silent! only")
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
    config.reset()
  end)

  it("lists the buffer's nvim-diff keys, the leader spelled out, by what they do", function()
    expect.eq(
      {
        { key = "<leader>cc", desc = "comment on this line" },
        { key = "]t", desc = "next comment thread" },
      },
      vim.tbl_map(function(item)
        return { key = item.key, desc = item.desc }
      end, help.items(buf))
    )
  end)

  it("maps the menu key once, and not at all when disabled", function()
    help.attach(buf)
    local n = 0
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
      n = n + (m.lhs == "?" and 1 or 0)
    end
    expect.eq(1, n)
    config.setup({ keymaps = { help = false } })
    local other = api.nvim_create_buf(false, true)
    help.attach(other)
    expect.eq(0, #api.nvim_buf_get_keymap(other, "n"))
    api.nvim_buf_delete(other, { force = true })
  end)

  it("opens a float over the buffer's keys, and runs the one picked there", function()
    local from = api.nvim_get_current_win()
    local menu = assert(help.open())
    expect.eq(menu.win, api.nvim_get_current_win())
    expect.eq("editor", api.nvim_win_get_config(menu.win).relative)
    local lines = api.nvim_buf_get_lines(menu.buf, 0, -1, false)
    expect.eq(2, #lines)
    expect.matches("^ %]t +next comment thread", lines[2])
    menu:run(2)
    vim.api.nvim_feedkeys("", "x", false)
    expect.eq(from, api.nvim_get_current_win())
    expect.falsy(api.nvim_win_is_valid(menu.win))
    expect.eq({ "next" }, ran)
  end)

  it("closes with q, back where it was opened", function()
    local from = api.nvim_get_current_win()
    local menu = assert(help.open())
    api.nvim_feedkeys("q", "x", false)
    expect.falsy(api.nvim_win_is_valid(menu.win))
    expect.eq(from, api.nvim_get_current_win())
  end)
end)
