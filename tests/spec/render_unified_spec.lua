local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local diffgen = require("tests.diffgen")
local fold = require("nvim-diff.render.fold")
local line = require("nvim-diff.diff.line")
local render = require("nvim-diff.render.unified")
local sidebyside = require("nvim-diff.render.sidebyside")
local unified_mod = require("nvim-diff.scene.unified")

local api = vim.api

---@type NvimDiff.Unified?
local current

---@param old string[]
---@param new string[]
---@param extra? table
---@return NvimDiff.Unified
local function open(old, new, extra)
  current = unified_mod.open(vim.tbl_extend("force", {
    diff = line.diff(old, new),
    old = { lines = old, label = "a/f.txt" },
    new = { lines = new, label = "b/f.txt" },
  }, extra or {}))
  return current
end

local function close()
  if current then
    current:close()
    current = nil
  end
end

---@param buf integer
---@param ns integer
---@return table[]
local function marks(buf, ns)
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], col = m[3], d = m[4] }
  end
  return out
end

--- The screen rows of a window, `cols` cells each.
---@param win integer
---@param cols integer
---@return string[]
local function screen(win, cols)
  vim.cmd("redraw")
  local pos = api.nvim_win_get_position(win)
  local rows = {}
  for r = 1, api.nvim_win_get_height(win) do
    local cells = {}
    for c = 1, cols do
      cells[#cells + 1] = vim.fn.screenstring(pos[1] + r, pos[2] + c)
    end
    rows[r] = table.concat(cells)
  end
  return rows
end

describe("render.unified", function()
  before_each(function()
    vim.o.background = "dark"
  end)

  after_each(function()
    close()
    vim.cmd("silent! only")
    vim.cmd("silent! tabonly")
  end)

  it("lays out unchanged lines once and each hunk as its old lines, then its new lines", function()
    local d = line.diff({ "a", "b", "c", "d", "e" }, { "a", "B", "c", "n1", "n2", "e" })
    local l = render.layout(d)
    local got = {}
    for _, x in ipairs(l.lines) do
      got[#got + 1] = ("%s %s/%s"):format(x.kind, tostring(x.old), tostring(x.new))
    end
    expect.eq({
      "context 1/1",
      "deleted 2/nil",
      "added nil/2",
      "context 3/3",
      "deleted 4/nil",
      "added nil/4",
      "added nil/5",
      "context 5/6",
    }, got)
  end)

  it("puts every line of both files in the pane exactly once, in file order per side", function()
    for seed = 1, 40 do
      local old, new = diffgen.files(seed)
      local d = line.diff(old, new)
      local l = render.layout(d)
      local text = render.text(l, old, new)
      local seen = { old = 0, new = 0 }
      for i, x in ipairs(l.lines) do
        for _, side in ipairs({ "old", "new" }) do
          if x[side] then
            expect.eq(seen[side] + 1, x[side], ("seed %d: %s out of order"):format(seed, side))
            seen[side] = x[side]
            expect.eq(i, l.index[side][x[side]])
          end
        end
        expect.eq(x.kind == "deleted" and old[x.old] or new[x.new], text[i])
        if x.kind == "context" then
          expect.eq(old[x.old], new[x.new])
        end
      end
      expect.eq(#old, seen.old)
      expect.eq(#new, seen.new)
      -- No hunk line faces anything: the pane has as many lines as the file pair has rows,
      -- plus one extra per changed row.
      local changed = 0
      for _, h in ipairs(d.hunks) do
        for _, r in ipairs(h.rows) do
          changed = changed + (r.kind == "changed" and 1 or 0)
        end
      end
      expect.eq(d.rows + changed, #l.lines)
    end
  end)

  it("fills one read-only pane with a header and the unified text, no trailer", function()
    local u = open({ "a", "b" }, { "a", "c", "d" })
    expect.eq({ "── a/f.txt → b/f.txt ──", "a", "b", "c", "d" }, api.nvim_buf_get_lines(u.buf, 0, -1, false))
    expect.eq("nofile", vim.bo[u.buf].buftype)
    expect.falsy(vim.bo[u.buf].modifiable)
    for _, opt in ipairs({ "diff", "scrollbind", "cursorbind", "wrap" }) do
      expect.falsy(vim.wo[u.win][opt], opt)
    end
    expect.truthy(vim.wo[u.win].winfixbuf)
    expect.eq("", vim.go.statuscolumn)
    expect.eq("── a/f.txt ──", unified_mod.header("a/f.txt", "a/f.txt"))
  end)

  it("paints old lines red and new lines green with their tokens, by the same rules as side-by-side", function()
    for seed = 1, 20 do
      local old, new = diffgen.files(seed)
      local u = open(old, new)
      local d, l = u.diff, u.layout
      local want_lines, want_tokens = {}, {}
      for i, x in ipairs(l.lines) do
        if x.kind ~= "context" then
          local side = x.kind == "deleted" and "old" or "new"
          want_lines[i] = x.kind == "deleted" and "NvimDiffDelLine" or "NvimDiffAddLine"
          if x.changed then
            for _, span in ipairs(d.tokens[side][x[side]]) do
              want_tokens[#want_tokens + 1] = ("%d:%d-%d:%s"):format(
                i,
                span[1],
                span[2],
                side == "old" and "NvimDiffDelToken" or "NvimDiffAddToken"
              )
            end
          end
        end
      end
      local got_lines, got_tokens = {}, {}
      for _, m in ipairs(marks(u.buf, render.ns)) do
        expect.matches("^NvimDiff", m.d.hl_group)
        if m.d.hl_group:find("Line$") then
          expect.eq(m.row + 1, m.d.end_row)
          expect.eq(0, m.d.end_col)
          expect.truthy(m.d.hl_eol)
          expect.eq(sidebyside.PRIORITY_LINE, m.d.priority)
          got_lines[m.row] = m.d.hl_group
        elseif m.d.hl_group:find("Token$") then
          expect.eq(sidebyside.PRIORITY_TOKEN, m.d.priority)
          got_tokens[#got_tokens + 1] = ("%d:%d-%d:%s"):format(m.row, m.col, m.d.end_col, m.d.hl_group)
        else
          expect.eq("NvimDiffHeader", m.d.hl_group)
          expect.eq(0, m.row)
        end
      end
      table.sort(want_tokens)
      table.sort(got_tokens)
      expect.eq(want_lines, got_lines, ("seed %d lines"):format(seed))
      expect.eq(want_tokens, got_tokens, ("seed %d tokens"):format(seed))
      expect.eq(0, #marks(u.buf, render.ns_virt), "a unified pane has no filler")
      close()
    end
  end)

  it("draws a wholly added line in one colour, with no token inside", function()
    local u = open({ "a" }, { "a", "brand new" })
    local groups = {}
    for _, m in ipairs(marks(u.buf, render.ns)) do
      groups[#groups + 1] = m.row .. ":" .. m.d.hl_group
    end
    expect.eq({ "0:NvimDiffHeader", "2:NvimDiffAddLine" }, groups)
  end)

  it("shows both line numbers and a sign, blank on the header and on virtual rows", function()
    local u = open({ "a", "b", "c", "d", "e" }, { "a", "B x", "c", "d", "new1", "new2", "e" })
    u:set_block("t", { row = 2, new = { { { "THREAD", "" } } } })
    expect.eq({
      "          ── a/",
      "  1   1   a    ",
      "  2     - b    ",
      "      2 + B x  ",
      "THREAD         ",
      "  3   3   c    ",
      "  4   4   d    ",
      "      5 + new1 ",
      "      6 + new2 ",
      "  5   7   e    ",
      "~              ",
    }, vim.list_slice(screen(u.win, 15), 1, 11))
  end)

  it("hangs each side's block rows under that side's line, with no padding", function()
    local d = line.diff({ "a", "b", "c" }, { "a", "B", "c", "n" })
    local l = render.layout(d)
    -- Display rows: 1 a/a, 2 b/B (changed), 3 c/c, 4 -/n. Pane: a, b, B, c, n.
    local rows = render.virt_rows(l, {
      { row = 2, old = { { { "O", "" } } }, new = { { { "N", "" } } } },
      { row = 0, new = { { { "TOP", "" } } } },
      { row = 4, old = { { { "on-added", "" } } } }, -- no old line: under the new one
      { row = 2, new = { { { "N2", "" } } } },
    })
    local got = {}
    for _, r in ipairs(rows) do
      local texts = {}
      for _, vl in ipairs(r.lines) do
        texts[#texts + 1] = vl[1][1]
      end
      got[#got + 1] = r.anchor .. ":" .. table.concat(texts, ",")
    end
    expect.eq({ "0:TOP", "2:O", "3:N,N2", "5:on-added" }, got)
  end)

  it("keeps every line's rows in place as blocks come and go", function()
    for seed = 1, 10 do
      local old, new = diffgen.files(seed)
      local u = open(old, new, { fold = false })
      local blocks = {}
      for i = 1, 5 do
        local rows = {}
        for k = 1, math.random(1, 4) do
          rows[k] = { { "thread " .. k, "" } }
        end
        blocks[i] = { row = math.random(0, u.diff.rows), [i % 2 == 0 and "old" or "new"] = rows }
        u:set_block(i, blocks[i])
      end
      expect.eq(render.height(u.layout, blocks), api.nvim_win_text_height(u.win, {}).all)
      local seen = {}
      for _, m in ipairs(marks(u.buf, render.ns_virt)) do
        expect.falsy(seen[m.row], "two virt marks on one line")
        seen[m.row] = true
      end
      for i = 1, 5 do
        u:remove_block(i)
      end
      expect.eq(0, #marks(u.buf, render.ns_virt))
      expect.eq(1 + #u.layout.lines, api.nvim_win_text_height(u.win, {}).all)
      close()
    end
  end)

  it("computes a top that puts any line on any screen row, virtual rows and folds included", function()
    local checked, in_fold = 0, 0
    for seed = 1, 20 do
      local old, new = diffgen.files(seed, 60)
      -- Odd seeds unfolded; even seeds folded, with smaller context so more of it folds.
      local u = open(old, new, { fold = seed % 2 == 0 and { context = 1 } or false })
      for i = 1, 6 do
        local rows = {}
        for k = 1, math.random(1, 4) do
          rows[k] = { { "thread " .. k, "" } }
        end
        u:set_block(i, { row = math.random(0, u.diff.rows), [i % 2 == 0 and "old" or "new"] = rows })
      end
      local count = api.nvim_buf_line_count(u.buf)
      local height = api.nvim_win_get_height(u.win)
      local width = sidebyside.number_width(u.diff)
      for _ = 1, 30 do
        local bl = math.random(1, count)
        local winline = math.random(1, height)
        u:place(bl, winline)
        local view = api.nvim_win_call(u.win, vim.fn.winsaveview)
        expect.eq(bl, view.lnum)
        -- Unless the view is pinned at the top of the pane, screen row `winline` must show
        -- line `bl`: its fold's band, or its own numbers. Read off the screen, since
        -- `winline()` miscounts next to a closed fold.
        if view.topline > 1 or view.topfill > 0 or render.line_view(u.virt, bl, u.ranges) >= winline - 1 then
          local row = screen(u.win, 2 * width + 1)[winline]
          local what = ("seed %d bl %d winline %d: %q"):format(seed, bl, winline, row)
          if render.range_at(u.ranges, bl) then
            expect.truthy(vim.startswith(row, "···"), what)
            in_fold = in_fold + 1
          else
            local x = u.layout.lines[bl - 1]
            local o = x and x.old and tostring(x.old) or ""
            local n = x and x.new and tostring(x.new) or ""
            if bl == 1 then
              expect.matches("^%s+$", row)
            else
              expect.eq(("%" .. width .. "s %" .. width .. "s"):format(o, n), row, what)
            end
          end
          -- The pane's own count of the cursor's screen row agrees with the screen.
          expect.eq(winline, u:winline(), what)
          checked = checked + 1
        end
      end
      close()
    end
    expect.truthy(checked > 200, "too few positions checked")
    expect.truthy(in_fold > 20, "too few positions inside folds checked")
  end)

  it("covers each fold with one run of buffer lines, reformatted hunks whole", function()
    for seed = 1, 40 do
      local old, new = diffgen.files(seed)
      local d = line.diff(old, new)
      for i, h in ipairs(d.hunks) do
        h.formatting_only = i % 2 == 0
      end
      local l = render.layout(d)
      local prev = 1
      for _, f in ipairs(fold.compute(d, { context = 1 })) do
        local a, b = render.fold_lines(l, f)
        expect.truthy(a > prev, ("seed %d: folds overlap or touch the header"):format(seed))
        prev = b
        -- Exactly the lines of the fold's rows, both sides.
        local want = 0
        for row = f.first, f.last do
          local o, n = d:line_at(row)
          if f.kind == "context" then
            want = want + 1 -- unchanged: one line
          else
            want = want + (o and 1 or 0) + (n and 1 or 0)
          end
        end
        expect.eq(want, b - a + 1, ("seed %d fold %d"):format(seed, f.id))
        for bl = a, b do
          local x = l.lines[bl - 1]
          local row = x.old and d:row_of("old", x.old) or d:row_of("new", x.new)
          expect.truthy(row >= f.first and row <= f.last, ("seed %d: line %d outside its fold"):format(seed, bl))
        end
      end
    end
  end)

  it("maps the cursor to a side and a file line", function()
    local u = open({ "a", "b" }, { "a", "c" })
    local want = { { nil, nil }, { "new", 1 }, { "old", 2 }, { "new", 2 } }
    for bl, w in ipairs(want) do
      api.nvim_win_set_cursor(u.win, { bl, 0 })
      local side, lnum = u:cursor_pos()
      expect.eq(w[1], side)
      expect.eq(w[2], lnum)
    end
    api.nvim_win_set_cursor(u.win, { 2, 0 })
    expect.eq(1, u:cursor_line("old"))
    api.nvim_win_set_cursor(u.win, { 3, 0 })
    expect.eq(nil, u:cursor_line("new"))
    u:jump("new", 2)
    expect.eq(4, api.nvim_win_get_cursor(u.win)[1])
  end)

  it("fires diff_buf_ready with the pane current", function()
    local event = require("nvim-diff.core.event")
    local seen = {}
    local off = event.on("diff_buf_ready", function(buf, ctx)
      seen[#seen + 1] = { ctx.layout, buf == api.nvim_get_current_buf() }
    end)
    open({ "a" }, { "b" })
    off()
    expect.eq({ { "unified", true } }, seen)
  end)

  it("wipes its buffer when its window is closed", function()
    vim.cmd("vsplit")
    local u = open({ "a" }, { "b" }, { win = api.nvim_get_current_win() })
    local buf = u.buf
    api.nvim_win_close(u.win, true)
    vim.wait(100, function()
      return u.closed
    end)
    expect.truthy(u.closed)
    expect.falsy(api.nvim_buf_is_valid(buf))
    current = nil
  end)
end)
