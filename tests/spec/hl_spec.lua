local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local hl = require("nvim-diff.ui.hl")

---@param name string
---@param ns? integer
---@return table
local function get(name, ns)
  return vim.api.nvim_get_hl(ns or 0, { name = name })
end

describe("highlight groups", function()
  before_each(function()
    config.reset()
    vim.o.background = "dark"
    vim.cmd("highlight clear")
    hl.define()
  end)

  after_each(function()
    config.reset()
  end)

  it("defines a colour for every group it documents", function()
    for name in pairs(hl.groups) do
      local attrs = get(name)
      expect.truthy(
        attrs.bg or attrs.fg or attrs.link or attrs.bold,
        name .. " resolved to nothing: " .. vim.inspect(attrs)
      )
    end
  end)

  it("sets a background and no foreground on the diff groups", function()
    for _, name in ipairs({ "NvimDiffAddLine", "NvimDiffAddToken", "NvimDiffDelLine", "NvimDiffDelToken" }) do
      local attrs = get(name)
      expect.truthy(attrs.bg, name .. " has no background")
      expect.falsy(attrs.fg, name .. " sets a foreground, which would hide treesitter's colours")
    end
  end)

  it("leaves the built-in diff groups exactly as it found them", function()
    local builtins = { "DiffAdd", "DiffChange", "DiffText", "DiffDelete" }
    local before = {}
    for _, name in ipairs(builtins) do
      before[name] = get(name)
      expect.falsy(hl.groups[name], name .. " is in the plugin's own group table")
    end

    hl.define()

    for _, name in ipairs(builtins) do
      expect.eq(before[name], get(name), name .. " was redefined by the plugin")
    end
  end)

  it("remaps Folded to the separator band inside its own namespace only", function()
    expect.eq("NvimDiffContextSeparator", get("Folded", hl.ns).link)
    expect.falsy(get("Folded").link, "the global Folded must be left alone")
  end)

  it("yields to a group the colorscheme already defined", function()
    vim.api.nvim_set_hl(0, "NvimDiffAddLine", { bg = "#123456" })
    hl.define()
    expect.eq(tonumber("123456", 16), get("NvimDiffAddLine").bg)
  end)

  it("lets a config override win over the shipped default", function()
    config.setup({ highlights = { NvimDiffAddLine = { bg = "#654321" } } })
    hl.define()
    expect.eq(tonumber("654321", 16), get("NvimDiffAddLine").bg)
  end)

  it("treats a string override as a link", function()
    config.setup({ highlights = { NvimDiffFiller = "Comment" } })
    hl.define()
    expect.eq("Comment", get("NvimDiffFiller").link)
  end)

  it("follows the background option", function()
    vim.o.background = "light"
    vim.cmd("highlight clear")
    hl.define()
    local light = get("NvimDiffAddLine").bg
    vim.o.background = "dark"
    vim.cmd("highlight clear")
    hl.define()
    expect.ne(light, get("NvimDiffAddLine").bg)
  end)

  it("redefines its groups after a colorscheme change", function()
    hl.setup()
    vim.cmd("colorscheme default")
    expect.truthy(get("NvimDiffContextSeparator").bg, "the separator lost its colour across :colorscheme")
  end)

  it("binds a window to its namespace", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { split = "right", win = 0 })
    expect.no_error(function()
      hl.apply_window(win)
    end)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
