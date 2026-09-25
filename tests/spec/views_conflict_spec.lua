local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local child_mod = require("tests.child")
local config = require("nvim-diff.config")
local gitrepo = require("tests.gitrepo")
local views = require("nvim-diff.views.conflict")

local api = vim.api

---@param n integer
---@param edit table<integer, string|false> Line to replace (false: delete).
---@param insert? table<integer, string[]> Lines to add after a line.
---@return string
local function text(n, edit, insert)
  local out = {}
  for i = 1, n do
    local e = edit[i]
    if e == nil then
      out[#out + 1] = "l" .. i
    elseif e then
      out[#out + 1] = e
    end
    for _, l in ipairs(insert and insert[i] or {}) do
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n") .. "\n"
end

--- A repository stopped in a merge of `feature` into `main`. `f.txt` (40 lines) has two
--- conflicts — at l15, and at l30 where ours also adds a line — plus a change only ours made
--- (l5) and two only theirs made (l22-24 deleted, l38 changed).
---@param style? string merge.conflictStyle
---@return Test.Repo
local function fixture(style)
  local r = gitrepo.new()
  if style then
    r:git({ "config", "merge.conflictStyle", style })
  end
  r:write("f.txt", text(40, {}))
  r:write("clean.txt", "x\n")
  r:commit("base")
  r:git({ "checkout", "-q", "-b", "feature" })
  r:write(
    "f.txt",
    text(
      40,
      { [15] = "l15 theirs", [22] = false, [23] = false, [24] = false, [30] = "l30 theirs", [38] = "l38 theirs" }
    )
  )
  r:commit("theirs")
  r:git({ "checkout", "-q", "main" })
  r:write("f.txt", text(40, { [5] = "l5 ours", [15] = "l15 ours", [30] = "l30 ours" }, { [30] = { "ours extra" } }))
  r:commit("ours")
  local res = vim.system({ "git", "merge", "-q", "feature" }, { cwd = r.root }):wait()
  assert(res.code ~= 0, "the merge should conflict")
  return r
end

--- Like `fixture`, but with a second conflicted file, `g.txt` (one conflict, l1), and a
--- clean file `h.txt` that only ours touched — so `f.txt` and `g.txt` are the `U` entries.
---@return Test.Repo
local function two_files_fixture()
  local r = gitrepo.new()
  r:write("f.txt", text(40, {}))
  r:write("g.txt", "g1\n")
  r:write("h.txt", "h\n")
  r:commit("base")
  r:git({ "checkout", "-q", "-b", "feature" })
  r:write("f.txt", text(40, { [15] = "l15 theirs" }))
  r:write("g.txt", "g-theirs\n")
  r:commit("theirs")
  r:git({ "checkout", "-q", "main" })
  r:write("f.txt", text(40, { [15] = "l15 ours" }))
  r:write("g.txt", "g-ours\n")
  r:write("h.txt", "h-ours\n")
  r:commit("ours")
  local res = vim.system({ "git", "merge", "-q", "feature" }, { cwd = r.root }):wait()
  assert(res.code ~= 0, "the merge should conflict")
  return r
end

---@param buf integer
---@return string[]
local function lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- The file's line under a top pane's cursor (the header is buffer line 1).
---@param view NvimDiff.ConflictView
---@param side NvimDiff.MergeSide
---@return integer
local function pane_line(view, side)
  return api.nvim_win_get_cursor(view.wins[side])[1] - 1
end

describe("views.conflict", function()
  ---@type NvimDiff.ConflictView?
  local view
  ---@type NvimDiff.TestChild?
  local child

  after_each(function()
    if view then
      view:close()
      view = nil
    end
    if child then
      child:stop()
      child = nil
    end
    config.reset()
    vim.cmd("silent! %bwipeout!")
    gitrepo.cleanup()
  end)

  it("lays out ours | base | theirs above the real file", function()
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local tab = api.nvim_get_current_tabpage()
    expect.eq(4, #api.nvim_tabpage_list_wins(tab))

    local pos = {}
    for _, key in ipairs({ "ours", "base", "theirs", "result" }) do
      pos[key] = api.nvim_win_get_position(view.wins[key])
    end
    expect.eq(pos.ours[1], pos.base[1])
    expect.eq(pos.ours[1], pos.theirs[1])
    expect.truthy(pos.ours[2] < pos.base[2] and pos.base[2] < pos.theirs[2], "left to right")
    expect.truthy(pos.result[1] > pos.ours[1], "result below")

    expect.matches("^── ours %(HEAD%) · f%.txt ──$", lines(view.bufs.ours)[1])
    expect.matches("^── base · f%.txt ──$", lines(view.bufs.base)[1])
    expect.matches("^── theirs %(MERGE_HEAD %x+%) · f%.txt ──$", lines(view.bufs.theirs)[1])
    expect.eq("l15 ours", lines(view.bufs.ours)[16])
    expect.eq("l15 theirs", lines(view.bufs.theirs)[16])

    expect.eq(r.root .. "/f.txt", api.nvim_buf_get_name(view.result_buf))
    expect.eq("", vim.bo[view.result_buf].buftype)
    expect.truthy(vim.bo[view.result_buf].modifiable)
    expect.eq(view.wins.result, api.nvim_get_current_win())
    for _, side in ipairs({ "ours", "base", "theirs" }) do
      expect.falsy(vim.bo[view.bufs[side]].modifiable, side)
      expect.falsy(vim.wo[view.wins[side]].diff, side)
    end
  end)

  it("colours each side against the base", function()
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local ns = require("nvim-diff.render.sidebyside").ns
    ---@param side string
    ---@return table<integer, string>
    local function line_groups(side)
      local out = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(view.bufs[side], ns, 0, -1, { details = true })) do
        if m[4].hl_eol then
          out[m[2]] = m[4].hl_group
        end
      end
      return out
    end
    local ours, base, theirs = line_groups("ours"), line_groups("base"), line_groups("theirs")
    -- l5: only ours changed it.
    expect.eq("NvimDiffAddLine", ours[5])
    expect.eq("NvimDiffDelLine", base[5])
    expect.eq(nil, theirs[5])
    -- l38: only theirs (three lines shorter there).
    expect.eq(nil, ours[39])
    expect.eq("NvimDiffDelLine", base[38])
    expect.eq("NvimDiffAddLine", theirs[35])
    -- l15: both.
    expect.eq("NvimDiffAddLine", ours[15])
    expect.eq("NvimDiffAddLine", theirs[15])
  end)

  it("starts on the first conflict and scrolls the top panes to it", function()
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local regions = require("nvim-diff.git.conflict").parse(lines(view.result_buf))
    expect.eq(2, #regions)
    expect.eq(regions[1].first, api.nvim_win_get_cursor(view.wins.result)[1])
    expect.eq(15, pane_line(view, "ours"))
    -- The corrector keeps the other panes' cursors on the same display row.
    expect.eq(15, pane_line(view, "base"))
    expect.eq(15, pane_line(view, "theirs"))
  end)

  it("steps between conflicts, wrapping", function()
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local regions = require("nvim-diff.git.conflict").parse(lines(view.result_buf))
    local function at()
      return api.nvim_win_get_cursor(view.wins.result)[1]
    end
    expect.truthy(view:next_conflict())
    expect.eq(regions[2].first, at())
    expect.eq(30, pane_line(view, "ours"))
    expect.eq(27, pane_line(view, "theirs"))
    expect.truthy(view:next_conflict())
    expect.eq(regions[1].first, at())
    expect.truthy(view:prev_conflict())
    expect.eq(regions[2].first, at())
    -- From between the two, prev goes to the first.
    api.nvim_win_set_cursor(view.wins.result, { regions[1].last + 2, 0 })
    expect.truthy(view:prev_conflict())
    expect.eq(regions[1].first, at())
  end)

  it("takes ours, theirs, both or none, undoably", function()
    config.setup({ log = { level = "off" } }) -- the refusals warn
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local conflict = require("nvim-diff.git.conflict")
    local before = lines(view.result_buf)
    local first = conflict.parse(before)[1].first

    expect.truthy(view:take("theirs"))
    local after = lines(view.result_buf)
    expect.eq("l15 theirs", after[first])
    expect.eq(1, #conflict.parse(after))
    expect.eq(#before - 4, #after)
    expect.truthy(vim.bo[view.result_buf].modified)

    vim.cmd("silent undo")
    expect.eq(before, lines(view.result_buf))

    api.nvim_win_set_cursor(view.wins.result, { first, 0 })
    expect.truthy(view:take("both"))
    expect.eq({ "l15 ours", "l15 theirs", "l16" }, vim.list_slice(lines(view.result_buf), first, first + 2))
    view:next_conflict()
    expect.truthy(view:take("ours"))
    expect.eq(0, #conflict.parse(lines(view.result_buf)))
    expect.falsy(view:take("none"), "no conflict under the cursor")
    expect.falsy(view:next_conflict())
  end)

  it("takes the base only from a conflict written with one", function()
    config.setup({ log = { level = "off" } }) -- the refusals warn
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    expect.falsy(view:take("base"))
    view:close()

    r = fixture("diff3")
    view = views.open({ path = r.root .. "/f.txt" })
    local first = api.nvim_win_get_cursor(view.wins.result)[1]
    expect.truthy(view:take("base"))
    expect.eq("l15", lines(view.result_buf)[first])
    -- No base section left to follow: the next conflict is found by its ours text.
    view:next_conflict()
    expect.eq(30, pane_line(view, "ours"))
  end)

  it("marks the conflicts in the result and keeps the marks current", function()
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local function marked()
      local out = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(view.result_buf, views.ns, 0, -1, { details = true })) do
        out[#out + 1] = m[4].hl_group
      end
      return out
    end
    local groups = marked()
    expect.eq(10, #groups) -- two conflicts: 3 markers + 2 sections each
    expect.truthy(vim.tbl_contains(groups, "NvimDiffConflictOurs"))
    expect.truthy(vim.tbl_contains(groups, "NvimDiffConflictTheirs"))
    view:take("ours")
    expect.eq(5, #marked())
  end)

  it("maps the keys in all four windows and removes them from the file on close", function()
    local r = fixture()
    config.setup({ keymaps = { conflict = { take_none = false, take_ours = "<leader>xo" } } })
    view = views.open({ path = r.root .. "/f.txt" })
    local function mapped(buf, lhs)
      return api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n") ~= ""
      end)
    end
    for _, buf in ipairs({ view.bufs.ours, view.bufs.base, view.bufs.theirs, view.result_buf }) do
      expect.truthy(mapped(buf, "]x"))
      expect.truthy(mapped(buf, "<leader>xo"))
      expect.truthy(mapped(buf, "<leader>ct"))
      expect.falsy(mapped(buf, "dx"))
    end

    local result, stage = view.result_buf, view.bufs.ours
    view:take("theirs")
    view:close()
    view = nil
    expect.falsy(api.nvim_buf_is_valid(stage))
    expect.truthy(api.nvim_buf_is_valid(result))
    expect.truthy(vim.bo[result].modified, "edits survive the close")
    expect.falsy(mapped(result, "]x"))
    expect.eq(0, #api.nvim_buf_get_extmarks(result, views.ns, 0, -1, {}))
  end)

  it("refuses a file that is not conflicted", function()
    local r = fixture()
    expect.errors(function()
      views.open({ path = r.root .. "/clean.txt" })
    end, "not in a conflicted state")
  end)

  it("lists every conflicted file by default, or takes an explicit list", function()
    local r = two_files_fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    expect.eq({ "f.txt", "g.txt" }, view.files)
    view:close()

    view = views.open({ path = r.root .. "/f.txt", files = { "g.txt", "f.txt" } })
    expect.eq({ "g.txt", "f.txt" }, view.files)
  end)

  it("steps to the next/previous conflicted file in place, keeping the tab and windows", function()
    local r = two_files_fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local tab, wins = view.tab, vim.deepcopy(view.wins)
    local conflict = require("nvim-diff.git.conflict")

    expect.truthy(view:next_file())
    expect.eq("g.txt", view.git_path)
    expect.eq(tab, view.tab)
    expect.eq(wins, view.wins)
    expect.eq(r.root .. "/g.txt", api.nvim_buf_get_name(view.result_buf))
    expect.eq(view.wins.result, api.nvim_get_current_win())
    expect.eq(1, #conflict.parse(lines(view.result_buf)))
    -- The view still works on the new file: take, undo, paint.
    expect.truthy(view:take("theirs"))
    expect.eq("g-theirs", lines(view.result_buf)[1])
    expect.eq(0, #conflict.parse(lines(view.result_buf)))

    expect.truthy(view:prev_file())
    expect.eq("f.txt", view.git_path)
    expect.eq(tab, view.tab)
    expect.eq(wins, view.wins)
    expect.eq(1, #conflict.parse(lines(view.result_buf)))

    -- Wraps: prev from the first goes to the last.
    expect.truthy(view:prev_file())
    expect.eq("g.txt", view.git_path)
  end)

  it("warns instead of stepping when only one file is conflicted", function()
    config.setup({ log = { level = "off" } }) -- the warning
    local r = fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    expect.eq({ "f.txt" }, view.files)
    expect.falsy(view:next_file())
    expect.eq("f.txt", view.git_path)
    expect.falsy(view:prev_file())
  end)

  it("maps next_file/prev_file (keymaps.view) in all four windows", function()
    local r = two_files_fixture()
    view = views.open({ path = r.root .. "/f.txt" })
    local function mapped(buf, lhs)
      return api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n") ~= ""
      end)
    end
    for _, buf in ipairs({ view.bufs.ours, view.bufs.base, view.bufs.theirs, view.result_buf }) do
      expect.truthy(mapped(buf, "<Tab>"))
      expect.truthy(mapped(buf, "<S-Tab>"))
    end

    api.nvim_set_current_win(view.wins.result)
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Tab>", true, false, true), "x", false)
    expect.eq("g.txt", view.git_path)
  end)

  it("keeps the three panes on the same rows through real scrolling", function()
    local r = fixture()
    child = child_mod.spawn()
    child:lua(
      [[
      local file = ...
      _G.V = require("nvim-diff.views.conflict").open({ path = file })
      local m = V.merge
      local width = require("nvim-diff.render.threeway").number_width(m)
      local function read(win)
        local pos = vim.api.nvim_win_get_position(win)
        local out = {}
        for r = 1, vim.api.nvim_win_get_height(win) do
          local row, col = pos[1] + r, pos[2] + 1
          local num = {}
          for c = col, col + width - 1 do
            num[#num + 1] = vim.fn.screenstring(row, c)
          end
          local n = table.concat(num):match("%d+")
          local first = vim.fn.screenstring(row, col)
          if first == "┈" then
            out[r] = "F"
          elseif first == "~" then
            out[r] = "~"
          elseif n then
            out[r] = tonumber(n)
          elseif vim.fn.screenstring(row, col + width + 1) == "─" then
            out[r] = "H"
          else
            out[r] = "B"
          end
        end
        return out
      end
      function _G.check()
        vim.cmd("redraw")
        local sides = { "ours", "base", "theirs" }
        local cols = {}
        for i, side in ipairs(sides) do
          cols[i] = read(V.wins[side])
        end
        local bad = {}
        for r = 1, #cols[1] do
          local d
          local ok = true
          for i, side in ipairs(sides) do
            local x = cols[i][r]
            if type(x) == "number" then
              local dx = m.row_of[side][x]
              ok = ok and (d == nil or d == dx)
              d = dx
            end
          end
          for i, side in ipairs(sides) do
            local x = cols[i][r]
            if x == "F" then
              ok = ok and d ~= nil and m:line_at(side, d) == nil
            elseif type(x) ~= "number" then
              ok = ok and d == nil and x == cols[1][r]
            end
          end
          if not ok then
            local a, b, c = tostring(cols[1][r]), tostring(cols[2][r]), tostring(cols[3][r])
            bad[#bad + 1] = ("row %d: %s | %s | %s"):format(r, a, b, c)
          end
        end
        return bad
      end
    ]],
      r.root .. "/f.txt"
    )
    local keys = { "<C-e>", "<C-y>", "3<C-e>", "<C-d>", "<C-u>", "j", "k", "7j", "9k", "G", "gg", "zt", "zb", "zz" }
    local wins = { "<C-w>t", "<C-w>l", "<C-w>l" }
    math.randomseed(7)
    local ops, misaligned, failures = 0, 0, {}
    for _ = 1, 150 do
      local label
      if math.random() < 0.15 then
        label = wins[math.random(#wins)]
      elseif math.random() < 0.1 then
        label = "]x"
      else
        label = keys[math.random(#keys)]
      end
      child:input(label)
      ops = ops + 1
      local bad = child:lua("return _G.check()")
      if #bad > 0 then
        misaligned = misaligned + 1
        if #failures < 5 then
          failures[#failures + 1] = label .. ": " .. bad[1]
        end
      end
    end
    io.stdout:write(("       measured: %d/%d ops misaligned\n"):format(misaligned, ops))
    expect.eq(0, misaligned, table.concat(failures, "\n      "))
  end)
end)

describe("views.conflict command", function()
  local event = require("nvim-diff.core.event")
  local cwd
  local notified
  local opened
  local off

  before_each(function()
    cwd = vim.uv.cwd()
    vim.g.loaded_nvim_diff = nil
    vim.cmd.runtime("plugin/nvim-diff.lua")
    notified = {}
    local notify = vim.notify
    vim.notify = function(msg, level) -- luacheck: ignore 122
      notified[#notified + 1] = { msg, level }
    end
    notified.restore = function()
      vim.notify = notify -- luacheck: ignore 122
    end
    opened = {}
    off = event.on(event.events.VIEW_OPENED, function(v)
      opened[#opened + 1] = v
    end)
  end)

  after_each(function()
    off()
    for _, v in ipairs(opened) do
      pcall(function()
        v:close()
      end)
    end
    notified.restore()
    vim.cmd.cd(cwd)
    vim.cmd("silent! %bwipeout!")
    gitrepo.cleanup()
    config.reset()
  end)

  it(":NvimDiffConflict opens the current file when it is conflicted", function()
    local r = fixture()
    vim.cmd.cd(r.root)
    vim.cmd("edit f.txt")
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("NvimDiffConflict")
    expect.eq(tabs + 1, #api.nvim_list_tabpages())
    expect.eq(1, #opened)
    expect.eq("f.txt", opened[1].git_path)
    expect.eq({}, { unpack(notified) })
  end)

  it(":NvimDiffConflict path opens that file", function()
    local r = fixture()
    vim.cmd.cd(r.root)
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("NvimDiffConflict f.txt")
    expect.eq(tabs + 1, #api.nvim_list_tabpages())
    expect.eq(1, #opened)
    expect.eq("f.txt", opened[1].git_path)
    expect.eq({}, { unpack(notified) })
  end)

  it(":NvimDiffConflict reports a file that is not conflicted, and opens nothing", function()
    local r = fixture()
    vim.cmd.cd(r.root)
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("NvimDiffConflict clean.txt")
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.eq(0, #opened)
    expect.eq(1, #notified)
    expect.matches("not in a conflicted state", notified[1][1])
    expect.eq(vim.log.levels.ERROR, notified[1][2])
  end)
end)
