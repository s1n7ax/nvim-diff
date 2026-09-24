local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local diffgen = require("tests.diffgen")
local line = require("nvim-diff.diff.line")
local pair_mod = require("nvim-diff.scene.pair")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api
local SIDES = { "old", "new" }

---@type NvimDiff.Pair?
local current

---@param old string[]
---@param new string[]
---@param extra? table
---@return NvimDiff.Pair
local function open(old, new, extra)
  current = pair_mod.open(vim.tbl_extend("force", {
    diff = line.diff(old, new),
    old = { lines = old, label = "a/f.txt" },
    new = { lines = new, label = "b/f.txt" },
  }, extra or {}))
  return current
end

--- Marks of one namespace, as `{ row, col, details }`.
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

--- Screen rows between the top of the buffer and buffer line `bl` (0 for the header),
--- measured by Neovim itself rather than by the row map.
---@param win integer
---@param bl integer
---@return integer
local function rows_before(win, bl)
  if bl <= 1 then
    return 0
  end
  return api.nvim_win_text_height(win, { start_row = 0, end_row = bl - 1, end_vcol = 0 }).all
end

--- Screen rows above the top of a window's view, measured by Neovim.
---@param win integer
---@return integer
local function rows_above_top(win)
  local v = api.nvim_win_call(win, vim.fn.winsaveview)
  return rows_before(win, v.topline) - v.topfill
end

describe("render.sidebyside", function()
  before_each(function()
    vim.o.background = "dark"
  end)

  after_each(function()
    if current then
      current:close()
      current = nil
    end
    vim.cmd("silent! only")
    vim.cmd("silent! tabonly")
  end)

  it("fills each pane with a header, the file's lines and no trailer when none is needed", function()
    local p = open({ "a", "b" }, { "a", "c" })
    expect.eq({ "── a/f.txt ──", "a", "b" }, api.nvim_buf_get_lines(p.bufs.old, 0, -1, false))
    expect.eq({ "── b/f.txt ──", "a", "c" }, api.nvim_buf_get_lines(p.bufs.new, 0, -1, false))
  end)

  it("appends an empty trailer to both panes when the file ends in filler", function()
    local p = open({ "a" }, { "a", "b", "c" })
    expect.eq({ "── a/f.txt ──", "a", "" }, api.nvim_buf_get_lines(p.bufs.old, 0, -1, false))
    expect.eq({ "── b/f.txt ──", "a", "b", "c", "" }, api.nvim_buf_get_lines(p.bufs.new, 0, -1, false))
  end)

  it("makes the panes read-only scratch buffers in aligned, unbound windows", function()
    local p = open({ "a", "b" }, { "a", "c" })
    for _, side in ipairs(SIDES) do
      local b, w = p.bufs[side], p.wins[side]
      expect.eq("nofile", vim.bo[b].buftype)
      expect.eq("wipe", vim.bo[b].bufhidden)
      expect.falsy(vim.bo[b].modifiable)
      expect.falsy(vim.bo[b].swapfile)
      expect.falsy(vim.bo[b].buflisted)
      expect.eq(-1, vim.bo[b].undolevels)
      expect.eq(b, api.nvim_win_get_buf(w))
      for _, opt in ipairs({ "diff", "scrollbind", "cursorbind", "wrap" }) do
        expect.falsy(vim.wo[w][opt], side .. " " .. opt)
      end
      expect.truthy(vim.wo[w].winfixbuf)
      expect.eq(0, vim.wo[w].foldminlines)
      expect.eq("manual", vim.wo[w].foldmethod)
      expect.matches("v:virtnum<0", vim.wo[w].statuscolumn)
    end
    -- Nothing leaked into the global values.
    expect.truthy(vim.go.wrap)
    expect.eq("", vim.go.statuscolumn)
  end)

  it("never uses the built-in diff highlight groups", function()
    local p = open(diffgen.files(7))
    for _, side in ipairs(SIDES) do
      for _, m in ipairs(marks(p.bufs[side], sidebyside.ns)) do
        expect.falsy(m.d.hl_group:find("^Diff"), m.d.hl_group)
        expect.matches("^NvimDiff", m.d.hl_group)
      end
    end
  end)

  it("paints the header as a full-width band", function()
    local p = open({ "a" }, { "b" })
    for _, side in ipairs(SIDES) do
      local m = marks(p.bufs[side], sidebyside.ns)[1]
      expect.eq(0, m.row)
      expect.eq("NvimDiffHeader", m.d.hl_group)
      expect.eq(1, m.d.end_row)
      expect.truthy(m.d.hl_eol)
    end
  end)

  it("paints every changed line by side and every changed token above it, and nothing else", function()
    for seed = 1, 20 do
      local old, new = diffgen.files(seed)
      local p = open(old, new)
      local d = p.diff
      for _, side in ipairs(SIDES) do
        local want_lines, want_tokens = {}, {}
        for _, h in ipairs(d.hunks) do
          for _, r in ipairs(h.rows) do
            if r[side] then
              want_lines[r[side]] = true
              if r.kind == "changed" then
                for _, span in ipairs(d.tokens[side][r[side]]) do
                  want_tokens[#want_tokens + 1] = ("%d:%d-%d"):format(r[side], span[1], span[2])
                end
              end
            end
          end
        end

        local line_group = side == "old" and "NvimDiffDelLine" or "NvimDiffAddLine"
        local token_group = side == "old" and "NvimDiffDelToken" or "NvimDiffAddToken"
        local got_lines, got_tokens = {}, {}
        for _, m in ipairs(marks(p.bufs[side], sidebyside.ns)) do
          if m.d.hl_group == line_group then
            expect.eq(0, m.col)
            expect.eq(m.row + 1, m.d.end_row)
            expect.eq(0, m.d.end_col)
            expect.truthy(m.d.hl_eol)
            expect.eq(sidebyside.PRIORITY_LINE, m.d.priority)
            got_lines[m.row] = true -- buffer row == file line: the header is row 0
          elseif m.d.hl_group == token_group then
            expect.eq(sidebyside.PRIORITY_TOKEN, m.d.priority)
            expect.eq(m.row, m.d.end_row)
            got_tokens[#got_tokens + 1] = ("%d:%d-%d"):format(m.row, m.col, m.d.end_col)
          else
            expect.eq("NvimDiffHeader", m.d.hl_group)
          end
        end
        table.sort(want_tokens)
        table.sort(got_tokens)
        expect.eq(want_lines, got_lines, ("seed %d %s lines"):format(seed, side))
        expect.eq(want_tokens, got_tokens, ("seed %d %s tokens"):format(seed, side))
      end
      p:close()
      current = nil
    end
  end)

  it("draws a wholly added line in one colour, with no token inside", function()
    local p = open({ "a" }, { "a", "brand new" })
    local groups = {}
    for _, m in ipairs(marks(p.bufs.new, sidebyside.ns)) do
      groups[#groups + 1] = m.row .. ":" .. m.d.hl_group
    end
    expect.eq({ "0:NvimDiffHeader", "2:NvimDiffAddLine" }, groups)
  end)

  it("keeps changed tokens visible above treesitter", function()
    local p = open({ "local x = 1" }, { "local x = 2" }, {
      old = { lines = { "local x = 1" }, label = "a", lang = "lua" },
      new = { lines = { "local x = 2" }, label = "b", lang = "lua" },
    })
    expect.truthy(vim.treesitter.highlighter.active[p.bufs.new], "treesitter did not attach")
    -- The token mark outranks treesitter's 100 and the line background's 150.
    local pos = vim.inspect_pos(p.bufs.new, 1, 10, { extmarks = true, treesitter = true, syntax = false })
    local token
    for _, e in ipairs(pos.extmarks) do
      if e.opts.hl_group == "NvimDiffAddToken" then
        token = e
      end
    end
    expect.truthy(token, "no token mark under the changed digit")
    expect.truthy(token.opts.priority > 100 and token.opts.priority > sidebyside.PRIORITY_LINE)
  end)

  it("merges each filler run into one extmark with one ┈ row per missing line", function()
    for seed = 1, 20 do
      local old, new = diffgen.files(seed)
      local p = open(old, new)
      for _, side in ipairs(SIDES) do
        local fillers = p.diff.fillers[side]
        local got = marks(p.bufs[side], sidebyside.ns_virt)
        expect.eq(#fillers, #got, ("seed %d %s"):format(seed, side))
        for i, f in ipairs(fillers) do
          local m = got[i]
          expect.eq(f.after, m.row) -- hangs from the line it follows; 0 = the header
          expect.eq(f.count, #m.d.virt_lines)
          expect.truthy(m.d.virt_lines_leftcol)
          for _, vl in ipairs(m.d.virt_lines) do
            expect.eq("NvimDiffFiller", vl[1][2])
            expect.eq("", (vl[1][1]:gsub("┈", "")))
          end
        end
      end
      p:close()
      current = nil
    end
  end)

  it("aligns every paired line and gives both panes the same height", function()
    for seed = 1, 40 do
      local old, new = diffgen.files(seed)
      local p = open(old, new)
      local d = p.diff
      for row = 1, d.rows do
        local o, n = d:line_at(row)
        if o and n then
          expect.eq(
            rows_before(p.wins.old, o + 1),
            rows_before(p.wins.new, n + 1),
            ("seed %d row %d (old %d, new %d)"):format(seed, row, o, n)
          )
        end
      end
      expect.eq(
        api.nvim_win_text_height(p.wins.old, {}).all,
        api.nvim_win_text_height(p.wins.new, {}).all,
        ("seed %d total height"):format(seed)
      )
      expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.old, {}).all)
      p:close()
      current = nil
    end
  end)

  it("numbers each pane with its own lines, blank on filler, header and trailer", function()
    local p = open({ "a", "b", "c" }, { "a", "x", "b", "c", "d" })
    vim.cmd("redraw")
    local rows = {}
    local pos = api.nvim_win_get_position(p.wins.old)
    local npos = api.nvim_win_get_position(p.wins.new)
    for r = 1, 8 do
      local l, rr = {}, {}
      for c = 1, 6 do
        l[#l + 1] = vim.fn.screenstring(pos[1] + r, pos[2] + c)
        rr[#rr + 1] = vim.fn.screenstring(npos[1] + r, npos[2] + c)
      end
      rows[r] = table.concat(l) .. "|" .. table.concat(rr)
    end
    expect.eq({
      "    ──|    ──",
      "  1 a |  1 a ",
      "┈┈┈┈┈┈|  2 x ",
      "  2 b |  3 b ",
      "  3 c |  4 c ",
      "┈┈┈┈┈┈|  5 d ",
      "      |      ", -- the trailer
      "~     |~     ",
    }, rows)
  end)

  it("puts the other pane at the same view row wherever one pane is scrolled", function()
    local checked, misaligned = 0, 0
    for seed = 1, 30 do
      local old, new = diffgen.files(seed, 150)
      local p = open(old, new)
      for _ = 1, 40 do
        local side = math.random() < 0.5 and "old" or "new"
        local other = side == "old" and "new" or "old"
        local v = math.random(0, p.map:max_top())
        local tl, tf = p.map:view_top(side, v)
        api.nvim_win_call(p.wins[side], function()
          vim.fn.winrestview({ topline = tl, topfill = tf, lnum = tl })
        end)
        p.sync:sync(p.wins[side])
        checked = checked + 1
        if rows_above_top(p.wins.old) ~= rows_above_top(p.wins.new) then
          misaligned = misaligned + 1
        end
        -- The follower's cursor is on screen, so entering it will not scroll it.
        local fv = api.nvim_win_call(p.wins[other], vim.fn.winsaveview)
        local ftop = p.map:top_view(other, fv.topline, fv.topfill)
        local cv = p.map:line_view(other, fv.lnum)
        expect.truthy(cv >= ftop and cv < ftop + api.nvim_win_get_height(p.wins[other]), "cursor off screen")
      end
      p:close()
      current = nil
    end
    expect.eq(0, misaligned, ("%d of %d scroll positions misaligned"):format(misaligned, checked))
  end)

  it("puts the follower's cursor on the counterpart line", function()
    local p = open({ "a", "b", "c", "d" }, { "a", "X", "Y", "b", "c", "d" })
    api.nvim_set_current_win(p.wins.new)
    api.nvim_win_set_cursor(p.wins.new, { 5, 0 }) -- new "b"
    p.sync:sync_cursor(p.wins.new)
    expect.eq(3, api.nvim_win_get_cursor(p.wins.old)[1]) -- old "b"
    api.nvim_win_set_cursor(p.wins.new, { 4, 0 }) -- new "Y", filler on old
    p.sync:sync_cursor(p.wins.new)
    expect.eq(2, api.nvim_win_get_cursor(p.wins.old)[1]) -- nearest line above: old "a"
  end)

  it("inserts a block with blank padding opposite, inside filler, and stays aligned", function()
    for seed = 1, 20 do
      local old, new = diffgen.files(seed)
      local p = open(old, new)
      local d = p.diff
      for i = 1, 4 do
        local rows = {}
        for k = 1, math.random(1, 4) do
          rows[k] = { { "thread " .. k, "NvimDiffThreadBody" } }
        end
        p:set_block(i, { row = math.random(0, d.rows), [i % 2 == 0 and "old" or "new"] = rows })
      end
      for row = 1, d.rows do
        local o, n = d:line_at(row)
        if o and n then
          expect.eq(
            rows_before(p.wins.old, o + 1),
            rows_before(p.wins.new, n + 1),
            ("seed %d row %d"):format(seed, row)
          )
        end
      end
      expect.eq(api.nvim_win_text_height(p.wins.old, {}).all, api.nvim_win_text_height(p.wins.new, {}).all)
      expect.eq(p.map:height(), api.nvim_win_text_height(p.wins.new, {}).all)
      -- One extmark per anchor line, never two.
      for _, side in ipairs(SIDES) do
        local seen = {}
        for _, m in ipairs(marks(p.bufs[side], sidebyside.ns_virt)) do
          expect.falsy(seen[m.row], ("seed %d: two virt marks on %s row %d"):format(seed, side, m.row))
          seen[m.row] = true
        end
      end
      for i = 1, 4 do
        p:remove_block(i)
      end
      expect.eq(#d.fillers.old, #marks(p.bufs.old, sidebyside.ns_virt))
      p:close()
      current = nil
    end
  end)

  it("orders filler and a block that share an anchor by display row", function()
    local p = open({ "a", "z" }, { "a", "b", "c", "z" })
    -- Display rows: 1 a/a, 2 -/b, 3 -/c, 4 z/z. A thread under new "b" splits old's filler.
    p:set_block("t", { row = 2, new = { { { "T1", "" } }, { { "T2", "" } } } })
    local m = marks(p.bufs.old, sidebyside.ns_virt)
    expect.eq(1, #m)
    local texts = {}
    for _, vl in ipairs(m[1].d.virt_lines) do
      texts[#texts + 1] = vl[1][1]:find("┈") and "fill" or (vl[1][1] == "" and "pad" or vl[1][1])
    end
    expect.eq({ "fill", "pad", "pad", "fill" }, texts)
  end)

  it("fires diff_buf_ready once per pane, with that pane current", function()
    local event = require("nvim-diff.core.event")
    local seen = {}
    local off = event.on("diff_buf_ready", function(buf, ctx)
      seen[#seen + 1] = { ctx.side, buf == api.nvim_get_current_buf() }
    end)
    open({ "a" }, { "b" })
    off()
    expect.eq({ { "old", true }, { "new", true } }, seen)
  end)

  it("closes both panes and wipes both buffers when one pane is closed", function()
    local p = open({ "a" }, { "b" })
    local bufs = { p.bufs.old, p.bufs.new }
    local other = p.wins.new
    api.nvim_win_close(p.wins.old, true)
    vim.wait(100, function()
      return p.closed
    end)
    expect.truthy(p.closed)
    expect.falsy(api.nvim_win_is_valid(other))
    for _, b in ipairs(bufs) do
      expect.falsy(api.nvim_buf_is_valid(b))
    end
    expect.falsy(pcall(api.nvim_get_autocmds, { group = "nvim-diff.pair." .. bufs[1] }), "pair autocmds left behind")
    current = nil
  end)
end)
