local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local event = require("nvim-diff.core.event")

describe("event bus", function()
  before_each(function()
    event.clear()
  end)

  it("exposes exactly the three events the design fixes", function()
    local names = vim.tbl_values(event.events)
    table.sort(names)
    expect.eq({ "diff_buf_ready", "view_closed", "view_opened" }, names)
  end)

  it("calls handlers in subscription order with the emitted arguments", function()
    local seen = {}
    event.on(event.events.DIFF_BUF_READY, function(bufnr, ctx)
      seen[#seen + 1] = { "first", bufnr, ctx }
    end)
    event.on(event.events.DIFF_BUF_READY, function(bufnr)
      seen[#seen + 1] = { "second", bufnr }
    end)

    event.emit(event.events.DIFF_BUF_READY, 7, { rev = "b" })

    expect.eq({ { "first", 7, { rev = "b" } }, { "second", 7 } }, seen)
  end)

  it("passes nil arguments through", function()
    local argc = nil
    event.on(event.events.VIEW_CLOSED, function(...)
      argc = select("#", ...)
    end)
    event.emit(event.events.VIEW_CLOSED, nil, nil)
    expect.eq(2, argc)
  end)

  it("unsubscribes through the returned function, idempotently", function()
    local calls = 0
    local unsubscribe = event.on(event.events.VIEW_OPENED, function()
      calls = calls + 1
    end)

    event.emit(event.events.VIEW_OPENED)
    unsubscribe()
    unsubscribe()
    event.emit(event.events.VIEW_OPENED)

    expect.eq(1, calls)
    expect.eq(0, event.count(event.events.VIEW_OPENED))
  end)

  it("runs a `once` handler once", function()
    local calls = 0
    event.once(event.events.VIEW_OPENED, function()
      calls = calls + 1
    end)
    event.emit(event.events.VIEW_OPENED)
    event.emit(event.events.VIEW_OPENED)
    expect.eq(1, calls)
    expect.eq(0, event.count(event.events.VIEW_OPENED))
  end)

  it("lets a handler unsubscribe another one mid-emit", function()
    local calls = {}
    local unsubscribe_second
    event.on(event.events.VIEW_OPENED, function()
      calls[#calls + 1] = "first"
      unsubscribe_second()
    end)
    unsubscribe_second = event.on(event.events.VIEW_OPENED, function()
      calls[#calls + 1] = "second"
    end)

    event.emit(event.events.VIEW_OPENED)
    expect.eq({ "first", "second" }, calls, "the in-flight emit uses a snapshot")
    event.emit(event.events.VIEW_OPENED)
    expect.eq({ "first", "second", "first" }, calls)
  end)

  describe("with logging silenced", function()
    before_each(function()
      config.setup({ log = { level = "off" } })
    end)

    after_each(function()
      config.reset()
    end)

    it("keeps going when a handler throws", function()
      local reached = false
      event.on(event.events.VIEW_OPENED, function()
        error("handler blew up")
      end)
      event.on(event.events.VIEW_OPENED, function()
        reached = true
      end)

      expect.no_error(function()
        event.emit(event.events.VIEW_OPENED)
      end)
      expect.truthy(reached)
    end)
  end)

  it("refuses an unknown event name on subscribe and on emit", function()
    expect.matches(
      "unknown event `view_opend`",
      expect.errors(function()
        event.on("view_opend", function() end)
      end)
    )
    expect.matches(
      "unknown event `nope`",
      expect.errors(function()
        event.emit("nope")
      end)
    )
  end)

  it("emits nothing when no one is listening", function()
    expect.no_error(function()
      event.emit(event.events.VIEW_CLOSED, 1)
    end)
  end)

  describe("emit_in", function()
    local buf, win

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, { split = "right", win = 0 })
    end)

    after_each(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("makes the window and its buffer current for the handler", function()
      local seen_win, seen_buf
      event.on(event.events.DIFF_BUF_READY, function()
        seen_win = vim.api.nvim_get_current_win()
        seen_buf = vim.api.nvim_get_current_buf()
      end)

      local before = vim.api.nvim_get_current_win()
      event.emit_in({ win = win, buf = buf }, event.events.DIFF_BUF_READY, buf)

      expect.eq(win, seen_win)
      expect.eq(buf, seen_buf)
      expect.eq(before, vim.api.nvim_get_current_win(), "the caller's window is restored")
    end)

    it("makes only the buffer current when no window is given", function()
      local seen_buf
      event.on(event.events.DIFF_BUF_READY, function()
        seen_buf = vim.api.nvim_get_current_buf()
      end)
      event.emit_in({ buf = buf }, event.events.DIFF_BUF_READY, buf)
      expect.eq(buf, seen_buf)
    end)

    it("still emits when the window and buffer are gone", function()
      local calls = 0
      event.on(event.events.VIEW_CLOSED, function()
        calls = calls + 1
      end)
      event.emit_in({ win = 9999, buf = 9999 }, event.events.VIEW_CLOSED)
      expect.eq(1, calls)
    end)
  end)
end)
