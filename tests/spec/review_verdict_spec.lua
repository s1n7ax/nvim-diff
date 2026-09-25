local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local config = require("nvim-diff.config")
local ghstub = require("tests.ghstub")
local review_mod = require("nvim-diff.views.review")
local verdict = require("nvim-diff.review.verdict")

local api = vim.api

---@param status string
---@param body string A JSON object on one line, with no single quote in it.
---@return string
local function reply(status, body)
  return ("    printf 'HTTP/2.0 %s\\n\\n%%s\\n' '%s'\n    exit 0\n    ;;\n"):format(status, body)
end

local OK = '{"id":1,"state":"APPROVED"}'
local OWN = '{"message":"Unprocessable Entity","errors":["Can not approve your own pull request"]}'

--- Stands in for `views/review.lua`'s review: the verdict reads only these fields.
---@return NvimDiff.Review
local function fake_review()
  return {
    number = 7,
    pr = {
      id = "PR_kwDO7",
      number = 7,
      head = { oid = "h3ad" },
      base = { oid = "b0b0" },
      target = { host = "github.com", owner = "octocat", repo = "hello-world" },
    },
    valid = true,
    is_valid = function(self)
      return self.valid
    end,
  } --[[@as NvimDiff.Review]]
end

---@param buf integer
---@return table<string, string> lhs by desc
local function maps(buf, mode)
  local out = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
    if map.desc then
      out[map.desc] = map.lhs
    end
  end
  return out
end

describe("review verdict", function()
  local real_confirm, real_get, real_notify

  before_each(function()
    config.reset()
    real_confirm, real_get, real_notify = verdict.confirm, review_mod.get, vim.notify
    vim.notify = function() end -- luacheck: ignore 122
  end)

  after_each(function()
    verdict.confirm, review_mod.get, vim.notify = real_confirm, real_get, real_notify -- luacheck: ignore 122
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_get_name(buf):find("nvim-diff://verdict/", 1, true) then
        vim.bo[buf].modified = false
        pcall(api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.cmd("silent! only")
    config.reset()
    ghstub.cleanup()
  end)

  ---@param body string
  ---@return fun(): string[] calls
  local function stub(body)
    local bin, calls = ghstub.new("  *pulls/7/reviews*)\n" .. body)
    config.setup({ github = { bin = bin }, log = { level = "off" } })
    return calls
  end

  it("opens a full-width markdown split at the bottom with a header naming the verdict", function()
    local left = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local v = verdict.open(fake_review(), "REQUEST_CHANGES")
    expect.eq(v.win, api.nvim_get_current_win())
    expect.eq(v.buf, api.nvim_win_get_buf(v.win))
    expect.eq(vim.o.columns, api.nvim_win_get_width(v.win), "under every window, not just one")
    expect.eq(verdict.HEIGHT, api.nvim_win_get_height(v.win))
    expect.eq("markdown", vim.bo[v.buf].filetype)
    expect.eq("acwrite", vim.bo[v.buf].buftype)
    expect.eq(true, vim.wo[v.win].spell)
    local bar = vim.wo[v.win].winbar
    expect.matches("Request changes PR #7", bar)
    expect.matches("summary required", bar)
    expect.matches("<C%-s> post · q cancel", bar)
    expect.eq("<C-S>", maps(v.buf, "n")["nvim-diff: post the review verdict to GitHub"])
    expect.eq("<C-S>", maps(v.buf, "i")["nvim-diff: post the review verdict to GitHub"])
    expect.eq("q", maps(v.buf, "n")["nvim-diff: cancel the review verdict"])
    expect.truthy(api.nvim_win_is_valid(left))
  end)

  it("posts the typed summary and closes the split", function()
    local calls = stub(reply("200 OK", OK))
    local v = verdict.open(fake_review(), "COMMENT")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "", "Looks good,", "one nit.", "" })

    local result = assert(v:post())
    expect.eq(1, result.id)
    expect.falsy(api.nvim_buf_is_valid(v.buf))
    expect.falsy(verdict.get(v.review))
    local sent = calls()
    expect.eq(1, #sent)
    expect.matches("%-f event=COMMENT", sent[1])
    expect.truthy(sent[1]:find("-f body=Looks good,\none nit.", 1, true), "blank edges trimmed")
  end)

  it("keeps the split, the text and the error when the post fails", function()
    stub(reply("422 Unprocessable Entity", OWN))
    local v = verdict.open(fake_review(), "APPROVE")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "ship it" })

    expect.falsy(v:post())
    expect.truthy(api.nvim_win_is_valid(v.win))
    expect.eq({ "ship it" }, api.nvim_buf_get_lines(v.buf, 0, -1, false))
    expect.matches("Can not approve your own pull request", vim.wo[v.win].winbar)
    expect.eq(v, verdict.get(v.review))
  end)

  it("keeps the split when a required summary is missing, without calling GitHub", function()
    local calls = stub(reply("200 OK", OK))
    local v = verdict.open(fake_review(), "REQUEST_CHANGES")
    expect.falsy(v:post())
    expect.truthy(api.nvim_win_is_valid(v.win))
    expect.matches("needs a summary", vim.wo[v.win].winbar)
    expect.eq(0, #calls())
  end)

  it("approves with no summary through the post key", function()
    local calls = stub(reply("200 OK", OK))
    local v = verdict.open(fake_review(), "APPROVE")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    expect.falsy(api.nvim_buf_is_valid(v.buf))
    expect.eq(1, #calls())
    expect.falsy(calls()[1]:find("body=", 1, true))
  end)

  it("cancels at once when nothing was typed", function()
    local asked = false
    verdict.confirm = function()
      asked = true
      return false
    end
    local v = verdict.open(fake_review(), "APPROVE")
    api.nvim_feedkeys("q", "x", false)
    expect.falsy(asked)
    expect.falsy(api.nvim_buf_is_valid(v.buf))
  end)

  it("asks before discarding typed text, and keeps it on no", function()
    local answer = false
    verdict.confirm = function()
      return answer
    end
    local v = verdict.open(fake_review(), "COMMENT")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "half a thought" })

    expect.eq(false, v:cancel())
    expect.eq({ "half a thought" }, api.nvim_buf_get_lines(v.buf, 0, -1, false))
    answer = true
    expect.eq(true, v:cancel())
    expect.falsy(api.nvim_buf_is_valid(v.buf))
  end)

  it("never posts on :w, and :q refuses to drop unsent text", function()
    local calls = stub(reply("200 OK", OK))
    local v = verdict.open(fake_review(), "COMMENT")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "draft" })
    vim.cmd("write")
    expect.eq(0, #calls())
    expect.falsy(pcall(vim.cmd, "quit"))
    expect.truthy(api.nvim_buf_is_valid(v.buf))
    expect.eq({ "draft" }, api.nvim_buf_get_lines(v.buf, 0, -1, false))
  end)

  it("reuses the open split and switches its verdict", function()
    local review = fake_review()
    local v = verdict.open(review, "COMMENT")
    api.nvim_buf_set_lines(v.buf, 0, -1, false, { "kept" })
    vim.cmd("wincmd p")
    local again = verdict.open(review, "APPROVE")
    expect.eq(v, again)
    expect.eq(v.win, api.nvim_get_current_win())
    expect.eq("APPROVE", v.event)
    expect.matches("Approve PR #7", vim.wo[v.win].winbar)
    expect.eq({ "kept" }, api.nvim_buf_get_lines(v.buf, 0, -1, false))
  end)

  it("does not post once the review has ended", function()
    local calls = stub(reply("200 OK", OK))
    local v = verdict.open(fake_review(), "APPROVE")
    v.review.valid = false
    expect.falsy(v:post())
    expect.eq(0, #calls())
    expect.matches("the review has ended", vim.wo[v.win].winbar)
  end)

  describe(":NvimDiffVerdict", function()
    before_each(function()
      vim.g.loaded_nvim_diff = nil
      vim.cmd.runtime("plugin/nvim-diff.lua")
    end)

    it("needs a review in the tab", function()
      local said
      vim.notify = function(m) -- luacheck: ignore 122
        said = m
      end
      review_mod.get = function()
        return nil
      end
      vim.cmd("NvimDiffVerdict approve")
      expect.matches("PR review", said)
      expect.eq(1, #api.nvim_list_wins())
    end)

    it("opens the split for the verdict named", function()
      local review = fake_review()
      review_mod.get = function()
        return review
      end
      vim.cmd("NvimDiffVerdict request-changes")
      local v = assert(verdict.get(review))
      expect.eq("REQUEST_CHANGES", v.event)
    end)

    it("rejects an unknown verdict", function()
      local said
      vim.notify = function(m) -- luacheck: ignore 122
        said = m
      end
      local review = fake_review()
      review_mod.get = function()
        return review
      end
      vim.cmd("NvimDiffVerdict merge")
      expect.matches("approve, request%-changes or comment", said)
      expect.falsy(verdict.get(review))
    end)

    it("asks which verdict when none is named", function()
      local review = fake_review()
      review_mod.get = function()
        return review
      end
      local real_select = vim.ui.select
      local offered
      vim.ui.select = function(items, opts, on_choice) -- luacheck: ignore 122
        offered = vim.tbl_map(opts.format_item, items)
        on_choice(items[3])
      end
      local ok, err = pcall(vim.cmd, "NvimDiffVerdict")
      vim.ui.select = real_select -- luacheck: ignore 122
      assert(ok, err)
      expect.eq({ "Approve", "Request changes", "Comment" }, offered)
      expect.eq("COMMENT", assert(verdict.get(review)).event)
    end)

    it("completes the three verdicts", function()
      expect.eq({ "approve", "request-changes", "comment" }, vim.fn.getcompletion("NvimDiffVerdict ", "cmdline"))
      expect.eq({ "request-changes" }, vim.fn.getcompletion("NvimDiffVerdict r", "cmdline"))
    end)
  end)
end)
