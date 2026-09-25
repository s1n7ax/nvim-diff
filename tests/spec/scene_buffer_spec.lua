local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local buffer = require("nvim-diff.scene.buffer")
local config = require("nvim-diff.config")

local api = vim.api

---@param name? string
---@param extra? table
---@return integer
local function create(name, extra)
  return buffer.create(vim.tbl_extend("force", {
    lines = { "one", "two" },
    header = "── " .. (name or "x") .. " ──",
    name = name and ("nvim-diff://test/" .. name) or nil,
    keep = true,
  }, extra or {}))
end

---@param buf integer
---@return boolean
local function is_kept(buf)
  return vim.list_contains(buffer.kept(), buf)
end

--- Wipe whatever the previous test left kept.
local function drain()
  config.setup({ buffers = { lru_size = 0 } })
  for _, buf in ipairs(buffer.kept()) do
    buffer.release(buf)
  end
  config.reset()
end

describe("scene.buffer", function()
  before_each(drain)
  after_each(function()
    vim.cmd("silent! only")
    vim.cmd("enew")
    drain()
  end)

  it("wipes a buffer not asked to be kept, and an unnamed one, on release", function()
    local plain = create("plain", { keep = false })
    local unnamed = create(nil)
    expect.eq("wipe", vim.bo[plain].bufhidden)
    buffer.release(plain)
    buffer.release(unnamed)
    expect.falsy(api.nvim_buf_is_valid(plain))
    expect.falsy(api.nvim_buf_is_valid(unnamed))
    expect.eq({}, buffer.kept())
  end)

  it("keeps a released blob hidden and hands it back under the same name", function()
    local buf = create("a")
    expect.eq("hide", vim.bo[buf].bufhidden)
    buffer.release(buf)
    expect.truthy(api.nvim_buf_is_valid(buf))
    expect.eq({ buf }, buffer.kept())

    local again = create("a", { header = "── other label ──", trailer = true })
    expect.eq(buf, again)
    expect.eq({ "── other label ──", "one", "two", "" }, api.nvim_buf_get_lines(buf, 0, -1, false))
    expect.falsy(vim.bo[buf].modifiable)
    expect.falsy(vim.bo[buf].modified)

    buffer.release(buf)
    expect.eq(buf, create("a"))
    expect.eq({ "── a ──", "one", "two" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("replaces the content when a reused name's lines differ", function()
    local buf = create("a")
    buffer.release(buf)
    expect.eq(buf, create("a", { lines = { "one", "2", "two", "three" } }))
    expect.eq({ "── a ──", "one", "2", "two", "three" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("never hands one buffer out twice, shown or not", function()
    local a = create("a")
    -- Not shown yet (a pair builds both sides first) — still taken.
    local b = create("a")
    expect.truthy(a ~= b)
    expect.eq("", api.nvim_buf_get_name(b))
    expect.falsy(is_kept(b))

    api.nvim_win_set_buf(0, a)
    buffer.release(a)
    local c = create("a")
    expect.truthy(c ~= a)
    expect.eq("", api.nvim_buf_get_name(c))
    buffer.release(b)
    buffer.release(c)
    expect.falsy(api.nvim_buf_is_valid(b))
    expect.falsy(api.nvim_buf_is_valid(c))

    -- Once no window shows it, it is free again.
    vim.cmd("enew")
    expect.eq(a, create("a"))
  end)

  it("scrubs keymaps and extmarks off a buffer when it is released", function()
    local buf = create("a")
    local ns = api.nvim_create_namespace("nvim-diff.test.scrub")
    api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = { { "x" } } })
    vim.keymap.set("n", "Q", "<Nop>", { buffer = buf })
    vim.keymap.set("x", "Q", "<Nop>", { buffer = buf })
    buffer.release(buf)
    expect.eq({}, api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}))
    expect.eq({}, api.nvim_buf_get_keymap(buf, "n"))
    expect.eq({}, api.nvim_buf_get_keymap(buf, "x"))
  end)

  it("evicts the least recently used blobs beyond buffers.lru_size", function()
    config.setup({ buffers = { lru_size = 2 } })
    local a, b = create("a"), create("b")
    buffer.release(a)
    buffer.release(b)
    expect.eq({ a, b }, buffer.kept())

    -- Using `a` again makes `b` the oldest.
    buffer.release(create("a"))
    expect.eq({ b, a }, buffer.kept())

    local c = create("c")
    buffer.release(c)
    expect.falsy(api.nvim_buf_is_valid(b))
    expect.eq({ a, c }, buffer.kept())
  end)

  it("counts blobs in use against the cap, but never evicts them", function()
    config.setup({ buffers = { lru_size = 1 } })
    local shown = create("shown")
    api.nvim_win_set_buf(0, shown)
    local held = create("held") -- handed out, in no window yet
    local idle = create("idle")
    buffer.release(idle)
    -- Three kept, cap one: only the released, unseen one can go.
    expect.falsy(api.nvim_buf_is_valid(idle))
    expect.truthy(api.nvim_buf_is_valid(shown))
    expect.truthy(api.nvim_buf_is_valid(held))

    -- Once `shown` leaves its window and `held` is released, the cap is met again.
    vim.cmd("enew")
    buffer.release(shown)
    buffer.release(held)
    expect.eq({ held }, buffer.kept())
  end)

  it("keeps nothing when buffers.lru_size is 0", function()
    config.setup({ buffers = { lru_size = 0 } })
    local buf = create("a")
    buffer.release(buf)
    expect.falsy(api.nvim_buf_is_valid(buf))
    expect.eq({}, buffer.kept())
  end)

  it("applies a smaller cap from the next release on", function()
    local a, b, c = create("a"), create("b"), create("c")
    for _, buf in ipairs({ a, b, c }) do
      buffer.release(buf)
    end
    expect.eq({ a, b, c }, buffer.kept())
    config.setup({ buffers = { lru_size = 1 } })
    buffer.release(create("b"))
    expect.eq({ b }, buffer.kept())
  end)

  it("forgets a kept buffer the user wiped", function()
    local buf = create("a")
    buffer.release(buf)
    vim.cmd.bwipeout(buf)
    expect.eq({}, buffer.kept())
    local fresh = create("a")
    expect.truthy(fresh ~= buf)
    expect.eq("nvim-diff://test/a", api.nvim_buf_get_name(fresh))
  end)
end)
