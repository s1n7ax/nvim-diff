local t = require("tests.harness")
local describe, it, before_each, after_each, expect = t.describe, t.it, t.before_each, t.after_each, t.expect

local child_mod = require("tests.child")
local config = require("nvim-diff.config")
local event = require("nvim-diff.core.event")
local gitrepo = require("tests.gitrepo")
local panel_mod = require("nvim-diff.ui.panel")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local views = require("nvim-diff.views.diff")

local api = vim.api

--- A repository with a committed base and a worktree full of changes:
--- lua/nvim-diff/scene/{a,b}.lua modified/deleted, lua/other.lua renamed, lua/new.lua added
--- (staged), README.md modified, big.txt over a 20-line limit, untracked.txt untracked.
---@return Test.Repo repo
---@return string base
local function fixture()
  local r = gitrepo.new()
  r:write("README.md", "hello\n")
  r:write("lua/nvim-diff/scene/a.lua", "a\nb\nc\n")
  r:write("lua/nvim-diff/scene/b.lua", "x\n")
  r:write("lua/other.lua", "o\n")
  r:write("big.txt", string.rep("line\n", 30))
  local base = r:commit("base")
  r:write("README.md", "hello\nworld\n")
  r:write("lua/nvim-diff/scene/a.lua", "a\nB\nc\n")
  r:delete("lua/nvim-diff/scene/b.lua")
  r:write("lua/new.lua", "n\n")
  r:git({ "add", "lua/new.lua" })
  r:write("big.txt", string.rep("line\n", 29) .. "x\n")
  r:git({ "mv", "lua/other.lua", "lua/renamed.lua" })
  r:write("untracked.txt", "u\n")
  return r, base
end

--- The panel's text, from the first line.
---@param view NvimDiff.DiffView
---@return string[]
local function panel_lines(view)
  return api.nvim_buf_get_lines(view.panel.buf, 0, -1, false)
end

---@param view NvimDiff.DiffView
---@return string[]
local function order(view)
  return vim.tbl_map(function(e)
    return e.path
  end, view.tree.order)
end

---@param view NvimDiff.DiffView
---@param p string
---@return NvimDiff.FileEntry
local function find(view, p)
  for _, e in ipairs(view.list.entries) do
    if e.path == p then
      return e
    end
  end
  error("no entry " .. p)
end

describe("views.diff", function()
  ---@type NvimDiff.DiffView?
  local view
  ---@type Test.Repo
  local r
  local base

  ---@param opts? table
  ---@return NvimDiff.DiffView
  local function open(opts)
    local repo = assert(repo_mod.discover(r.root))
    view = views.open(vim.tbl_extend("force", {
      repo = repo,
      left = rev.commit(base, "main"),
      right = rev.worktree(),
    }, opts or {}))
    return view
  end

  before_each(function()
    config.setup({ thresholds = { defer_lines = 20 } })
    r, base = fixture()
  end)

  after_each(function()
    if view then
      view:close()
      view = nil
    end
    config.reset()
    gitrepo.cleanup()
  end)

  it("lists the files as a tree with status, stats, renames, deferral and totals", function()
    open()
    expect.eq({
      "main → worktree",
      "7 files  +4 -3",
      "▾ lua/",
      "  ▾ nvim-diff/scene/",
      "    M a.lua +1 -1",
      "    D b.lua +0 -1",
      "  A new.lua +1 -0",
      "  R renamed.lua ← other.lua +0 -0",
      "M README.md +1 -0",
      "M big.txt +1 -1 [deferred: 30 lines]",
      "? untracked.txt",
    }, panel_lines(view))
  end)

  it("opens the panel as a fixed-width, fixed-buffer window left of the diff area", function()
    open()
    local win = view.panel.win
    expect.eq(win, api.nvim_get_current_win())
    expect.eq(35, api.nvim_win_get_width(win))
    expect.eq(true, vim.wo[win].winfixwidth)
    expect.eq(true, vim.wo[win].winfixbuf)
    expect.eq(false, vim.wo[win].number)
    expect.eq("nofile", vim.bo[view.panel.buf].buftype)
    expect.eq(false, vim.bo[view.panel.buf].modifiable)
    local layout = vim.fn.winlayout()
    expect.eq("row", layout[1])
    expect.eq(win, layout[2][1][2])
    -- The cursor starts on the first row, not on the header.
    expect.eq(3, api.nvim_win_get_cursor(win)[1])
  end)

  it("opens the selected file in a side-by-side pair right of the panel", function()
    open()
    view:select(find(view, "lua/nvim-diff/scene/a.lua"))
    local pair = assert(view.file.scene)
    expect.eq(
      { "── a/lua/nvim-diff/scene/a.lua ──", "a", "b", "c" },
      api.nvim_buf_get_lines(pair.bufs.old, 0, -1, false)
    )
    expect.eq(
      { "── b/lua/nvim-diff/scene/a.lua ──", "a", "B", "c" },
      api.nvim_buf_get_lines(pair.bufs.new, 0, -1, false)
    )
    expect.eq(
      { "row", { { "leaf", view.panel.win }, { "leaf", pair.wins.old }, { "leaf", pair.wins.new } } },
      vim.fn.winlayout()
    )
    expect.eq(35, api.nvim_win_get_width(view.panel.win))
    expect.truthy(math.abs(api.nvim_win_get_width(pair.wins.old) - api.nvim_win_get_width(pair.wins.new)) <= 1)
    -- The focus stays where the selection came from.
    expect.eq(view.panel.win, api.nvim_get_current_win())
    -- The panel marks the file as current.
    local marks = api.nvim_buf_get_extmarks(view.panel.buf, panel_mod.current_ns, 0, -1, { details = true })
    expect.eq(1, #marks)
    expect.eq(4, marks[1][2]) -- line 5
    expect.eq("NvimDiffPanelSelected", marks[1][4].line_hl_group)
  end)

  it("reads added, deleted, renamed and untracked files from the right revisions", function()
    open()
    local function sides(p)
      view:select(find(view, p))
      -- A file on one side only opens unified; flip it to read the two sides apart.
      local status = view.current.change.status
      local one_sided = status == "A" or status == "D" or status == "?"
      expect.eq(one_sided and "unified" or "side_by_side", view.file.layout, p)
      view.file:set_layout("side_by_side")
      return {
        api.nvim_buf_get_lines(view.file.scene.bufs.old, 1, -1, false),
        api.nvim_buf_get_lines(view.file.scene.bufs.new, 1, -1, false),
      }
    end
    -- Filler at the end of a side adds an empty trailer line to both panes.
    expect.eq({ { "" }, { "n", "" } }, sides("lua/new.lua"))
    expect.eq({ { "x", "" }, { "" } }, sides("lua/nvim-diff/scene/b.lua"))
    expect.eq({ { "o" }, { "o" } }, sides("lua/renamed.lua"))
    expect.eq({ { "" }, { "u", "" } }, sides("untracked.txt"))
  end)

  it("steps through files in panel order, wrapping, from the panel or a pane", function()
    open()
    expect.eq({
      "lua/nvim-diff/scene/a.lua",
      "lua/nvim-diff/scene/b.lua",
      "lua/new.lua",
      "lua/renamed.lua",
      "README.md",
      "big.txt",
      "untracked.txt",
    }, order(view))
    view:next_file()
    expect.eq("lua/nvim-diff/scene/a.lua", view.current.path)
    view:prev_file()
    expect.eq("untracked.txt", view.current.path)
    view:next_file()
    expect.eq("lua/nvim-diff/scene/a.lua", view.current.path)
    -- From a pane, the cursor follows into the next diff: the new pair's same side, or
    -- the one pane of a file that exists on one side only (b.lua is deleted).
    api.nvim_set_current_win(view.file.scene.wins.old)
    view:next_file()
    expect.eq("lua/nvim-diff/scene/b.lua", view.current.path)
    expect.eq(view.file.scene.win, api.nvim_get_current_win())
    -- The panel cursor follows the current file.
    expect.eq(6, api.nvim_win_get_cursor(view.panel.win)[1])
    view:select(find(view, "lua/renamed.lua"))
    api.nvim_set_current_win(view.file.scene.wins.old)
    view:next_file()
    expect.eq("README.md", view.current.path)
    expect.eq(view.file.scene.wins.old, api.nvim_get_current_win())
  end)

  it("shows a deferred file as a note, and loads it only when asked", function()
    open()
    local big = find(view, "big.txt")
    expect.eq(true, big.deferred)
    expect.eq(30, big.lines)
    view:select(big)
    expect.eq(nil, view.file)
    local note = api.nvim_buf_get_lines(view.note_buf, 0, -1, false)
    expect.matches("30 lines, over the 20%-line limit", table.concat(note, "\n"))
    expect.eq({ "row", { { "leaf", view.panel.win }, { "leaf", view.note_win } } }, vim.fn.winlayout())

    view:load(big)
    expect.truthy(view.file)
    expect.eq(31, api.nvim_buf_line_count(view.file.scene.bufs.new))
    expect.eq("M big.txt +1 -1", panel_lines(view)[10])
    -- Once asked for, it stays loaded when revisited.
    view:next_file()
    view:prev_file()
    expect.truthy(view.file)
  end)

  it("summarises above the panel threshold: every directory starts folded", function()
    config.setup({ thresholds = { defer_lines = 20, panel_entries = 3 } })
    open()
    expect.eq({
      "main → worktree",
      "7 files  +4 -3",
      "Over 3 files: directories start folded.",
      "▸ lua/  4 files +2 -2",
      "M README.md +1 -0",
      "M big.txt +1 -1 [deferred: 30 lines]",
      "? untracked.txt",
    }, panel_lines(view))
    -- Selecting a file inside a folded directory unfolds the way to it.
    view:next_file()
    expect.eq("lua/nvim-diff/scene/a.lua", view.current.path)
    expect.eq("  ▾ nvim-diff/scene/", panel_lines(view)[5])
    expect.eq(6, api.nvim_win_get_cursor(view.panel.win)[1])
  end)

  it("folds and unfolds a directory, and switches to a flat listing", function()
    open()
    view:toggle_dir("lua/nvim-diff/scene")
    expect.eq("  ▸ nvim-diff/scene/  2 files +1 -2", panel_lines(view)[4])
    expect.eq("  A new.lua +1 -0", panel_lines(view)[5])
    view:toggle_dir("lua/nvim-diff/scene")
    expect.eq("    M a.lua +1 -1", panel_lines(view)[5])

    view:toggle_listing()
    expect.eq({
      "main → worktree",
      "7 files  +4 -3",
      "M README.md +1 -0",
      "M big.txt +1 -1 [deferred: 30 lines]",
      "A lua/new.lua +1 -0",
      "M lua/nvim-diff/scene/a.lua +1 -1",
      "D lua/nvim-diff/scene/b.lua +0 -1",
      "R lua/renamed.lua ← lua/other.lua +0 -0",
      "? untracked.txt",
    }, panel_lines(view))
    expect.eq("README.md", view.tree.order[1].path)
  end)

  it("shows viewed marks and an n/m viewed counter once entries carry viewed state", function()
    open()
    for _, e in ipairs(view.list.entries) do
      e.viewed = "unviewed"
    end
    view:set_viewed(find(view, "README.md"), "viewed")
    view:set_viewed(find(view, "big.txt"), "rechanged")
    local lines = panel_lines(view)
    expect.eq("7 files  +4 -3  1/7 viewed", lines[2])
    expect.eq("✓ M README.md +1 -0", lines[9])
    expect.eq("↻ M big.txt +1 -1 [deferred: 30 lines]", lines[10])
    expect.eq("      M a.lua +1 -1", lines[5]) -- unviewed: a blank mark cell
    -- The viewed file's name is drawn dimmed.
    local marks = api.nvim_buf_get_extmarks(view.panel.buf, panel_mod.ns, { 8, 0 }, { 8, -1 }, { details = true })
    local groups = vim.tbl_map(function(m)
      return m[4].hl_group
    end, marks)
    expect.truthy(vim.tbl_contains(groups, "NvimDiffPanelViewed"))
    expect.falsy(vim.tbl_contains(groups, "NvimDiffPanelPath"))
  end)

  it("morphs on refresh: unchanged entries and their diff survive, changes reload", function()
    open()
    local a = find(view, "lua/nvim-diff/scene/a.lua")
    local readme = find(view, "README.md")
    view:select(a)
    local file = view.file

    -- Nothing changed: same entries, same pair.
    local ops = assert(view:refresh())
    expect.eq(7, #ops)
    for _, op in ipairs(ops) do
      expect.eq("keep", op.op, op.entry.path)
    end
    expect.truthy(view.file == file, "an unchanged current file was reopened")

    -- Another file changes and one appears: the current diff is left alone.
    r:write("README.md", "hello\nthere\n") -- same +1 -0 stats, new content
    r:write("zzz.txt", "z\n")
    ops = assert(view:refresh())
    local kinds = {}
    for _, op in ipairs(ops) do
      kinds[op.entry.path] = op.op
    end
    expect.eq("update", kinds["README.md"])
    expect.eq("insert", kinds["zzz.txt"])
    expect.eq("keep", kinds["lua/nvim-diff/scene/a.lua"])
    expect.truthy(find(view, "README.md") == readme, "the README entry was rebuilt")
    expect.truthy(view.file == file, "an unchanged current file was reopened")
    expect.eq("? zzz.txt", panel_lines(view)[#panel_lines(view)])

    -- The current file changes: it reloads.
    r:write("lua/nvim-diff/scene/a.lua", "a\nC\nc\n")
    view:refresh()
    expect.truthy(view.file ~= file, "the changed current file was not reloaded")
    expect.eq("C", api.nvim_buf_get_lines(view.file.scene.bufs.new, 2, 3, false)[1])
    expect.truthy(view.current == a)

    -- The current file goes away: the selection moves to what took its place.
    r:write("lua/nvim-diff/scene/a.lua", "a\nb\nc\n")
    view:refresh()
    expect.eq("lua/nvim-diff/scene/b.lua", view.current.path)
  end)

  it("recovers when the user closes a pane: the next file opens beside the panel again", function()
    open()
    view:next_file()
    local pair = view.file.scene
    api.nvim_win_close(pair.wins.old, true)
    vim.wait(200, function()
      return pair.closed
    end)
    expect.eq(true, pair.closed)
    view:select(find(view, "README.md"))
    local wins = view.file.scene.wins
    expect.eq({ "row", { { "leaf", view.panel.win }, { "leaf", wins.old }, { "leaf", wins.new } } }, vim.fn.winlayout())
    expect.eq(35, api.nvim_win_get_width(view.panel.win))
  end)

  it("fires view_opened and view_closed, and closing removes its tab and buffers", function()
    local seen = {}
    local off1 = event.on(event.events.VIEW_OPENED, function(v)
      seen[#seen + 1] = { "opened", v, api.nvim_get_current_buf() }
    end)
    local off2 = event.on(event.events.VIEW_CLOSED, function(v)
      seen[#seen + 1] = { "closed", v, api.nvim_get_current_buf() }
    end)
    local tabs = #api.nvim_list_tabpages()
    open()
    local v, panel_buf = view, view.panel.buf
    view:next_file()
    local bufs = { view.file.scene.bufs.old, view.file.scene.bufs.new, view.note_buf }
    expect.eq(tabs + 1, #api.nvim_list_tabpages())
    view:close()
    view = nil
    off1()
    off2()
    expect.eq(tabs, #api.nvim_list_tabpages())
    expect.eq({ { "opened", v, panel_buf }, { "closed", v, panel_buf } }, seen)
    for _, b in ipairs(bufs) do
      expect.falsy(api.nvim_buf_is_valid(b), "buffer " .. b .. " survived")
    end
    expect.falsy(api.nvim_buf_is_valid(panel_buf))
  end)

  it("holds a fileview: the layout flips in place beside the panel, keys follow", function()
    open()
    view:select(find(view, "lua/nvim-diff/scene/a.lua"))
    local file = assert(view.file)
    expect.eq("side_by_side", file.layout)
    api.nvim_set_current_win(file.scene.wins.new)
    file:toggle()
    expect.eq("unified", file.layout)
    local win = file.scene.win
    expect.eq({ "row", { { "leaf", view.panel.win }, { "leaf", win } } }, vim.fn.winlayout())
    expect.eq(35, api.nvim_win_get_width(view.panel.win))
    expect.eq(
      "── a/lua/nvim-diff/scene/a.lua → b/lua/nvim-diff/scene/a.lua ──",
      vim.trim(api.nvim_buf_get_lines(file.scene.buf, 0, 1, false)[1])
    )
    -- The view's keys reach the new buffer.
    expect.truthy(api.nvim_buf_call(file.scene.buf, function()
      return vim.fn.maparg("<Tab>", "n") ~= ""
    end))

    -- Changing files from the unified pane keeps the cursor in the diff; the next file
    -- opens in the configured layout, and going back reopens the flipped one flipped.
    view:select(find(view, "README.md"))
    expect.eq("side_by_side", view.file.layout)
    expect.eq(view.file.scene.wins.new, api.nvim_get_current_win())
    view:select(find(view, "lua/nvim-diff/scene/a.lua"))
    expect.eq("unified", view.file.layout)
    expect.eq(view.file.scene.win, api.nvim_get_current_win())
    expect.eq(35, api.nvim_win_get_width(view.panel.win))

    -- And back to side-by-side, split beside the panel.
    view.file:toggle()
    local p = view.file.scene
    expect.eq(
      { "row", { { "leaf", view.panel.win }, { "leaf", p.wins.old }, { "leaf", p.wins.new } } },
      vim.fn.winlayout()
    )
    expect.eq(35, api.nvim_win_get_width(view.panel.win))
    expect.truthy(api.nvim_buf_call(p.bufs.old, function()
      return vim.fn.maparg("<Tab>", "n") ~= ""
    end))
  end)

  it("opens files unified when config.layout says so", function()
    config.setup({ thresholds = { defer_lines = 20 }, layout = "unified" })
    open()
    view:next_file()
    expect.eq("unified", view.file.layout)
    expect.eq({ "row", { { "leaf", view.panel.win }, { "leaf", view.file.scene.win } } }, vim.fn.winlayout())
    -- The cursor stays in the panel; a closed unified pane recovers like a pair does.
    expect.eq(view.panel.win, api.nvim_get_current_win())
    local u = view.file.scene
    api.nvim_win_close(u.win, true)
    vim.wait(200, function()
      return u.closed
    end)
    expect.eq(true, u.closed)
    view:next_file()
    expect.eq({ "row", { { "leaf", view.panel.win }, { "leaf", view.file.scene.win } } }, vim.fn.winlayout())
  end)

  it("opens the history of the line under the cursor, from whichever pane it is in", function()
    open()
    view:select(find(view, "lua/nvim-diff/scene/a.lua"))
    local file = assert(view.file)
    -- The key reaches every pane.
    expect.truthy(api.nvim_buf_call(file.scene.bufs.old, function()
      return vim.fn.maparg("gL", "n") ~= ""
    end))

    -- The old pane is a committed revision (`base`): buffer line 3 (line 2, after the
    -- mandatory header row) is "b".
    api.nvim_win_set_cursor(file.scene.wins.old, { 3, 0 })
    api.nvim_set_current_win(file.scene.wins.old)
    local line_view = view:line_history()
    expect.truthy(line_view)
    expect.eq("lua/nvim-diff/scene/a.lua", line_view.path)
    expect.eq(base, line_view.start.oid)
    expect.eq(2, line_view.line.start)
    line_view:close()

    -- The new pane is the worktree: no committed revision to walk from.
    api.nvim_set_current_win(file.scene.wins.new)
    api.nvim_win_set_cursor(file.scene.wins.new, { 3, 0 })
    expect.eq(nil, view:line_history())
  end)
end)

describe("views.diff, driven by real keystrokes", function()
  ---@type NvimDiff.TestChild?
  local child

  after_each(function()
    if child then
      child:stop()
      child = nil
    end
    gitrepo.cleanup()
  end)

  it("selects, steps, loads a deferred file and switches listing from the keyboard", function()
    local r, base = fixture()
    child = child_mod.spawn()
    child:lua(
      [[
      local root, base = ...
      vim.o.showtabline = 0
      require("nvim-diff.config").setup({ thresholds = { defer_lines = 20 } })
      local rev = require("nvim-diff.git.rev")
      _G.V = require("nvim-diff.views.diff").open({
        repo = require("nvim-diff.git.repo").discover(root),
        left = rev.commit(base, "main"),
        right = rev.worktree(),
      })
    ]],
      r.root,
      base
    )
    local function screen(rows)
      return vim.tbl_map(function(s)
        return (s:gsub("%s+$", ""))
      end, child:screen(1, rows, 1, 80))
    end

    local s = screen(12)
    expect.eq("main → worktree", s[1]:sub(1, #"main → worktree"))
    expect.matches("^  ▾ nvim%-diff/scene/ +│", s[4])
    expect.matches("^    M a%.lua %+1 %-1 +│", s[5])
    expect.matches("Select a file in the panel%.", table.concat(s, "\n"))

    -- <CR> on "a.lua" (line 5) opens the pair; the focus stays in the panel.
    child:input("jj<CR>")
    s = screen(4)
    expect.matches("│ *── a/lua/nvim%-dif.*│ *── b/lua/nvim%-dif", s[1])
    expect.matches("│ +1 a +│ +1 a", s[2])
    expect.matches("│ +2 b +│ +2 B", s[3])
    expect.eq(true, child:lua("return vim.api.nvim_get_current_win() == V.panel.win"))

    -- <Tab> from a pane moves to the next file and keeps the cursor in a pane: b.lua is
    -- deleted, so it opens as one unified pane.
    child:lua("vim.api.nvim_set_current_win(V.file.scene.wins.new)")
    child:input("<Tab>")
    expect.matches("│ +1 +%- x$", screen(2)[2])
    expect.eq(true, child:lua("return vim.api.nvim_get_current_win() == V.file.scene.win"))
    child:input("<S-Tab>")
    expect.matches("│ +1 a +│ +1 a", screen(2)[2])

    -- A deferred file: <CR> shows the note, <CR> again loads it.
    child:lua("vim.api.nvim_set_current_win(V.panel.win)")
    child:input("10G<CR>")
    s = screen(6)
    expect.matches("│  big%.txt", s[2])
    expect.matches("│  30 lines, over the 20%-line limit", s[4])
    child:input("<CR>")
    s = screen(2)
    expect.matches("│ *── a/big%.txt.*│ *── b/big%.txt", s[1])
    expect.matches("^M big%.txt %+1 %-1 +│", screen(10)[10])

    -- `i` flips to a flat listing, `i` again back to the tree.
    child:input("i")
    expect.matches("^A lua/new%.lua %+1 %-0", screen(5)[5])
    expect.matches("^M lua/nvim%-diff/scene/a%.lua %+1 %-1", screen(6)[6])
    child:input("i")
    expect.matches("^  ▾ nvim%-diff/scene/", screen(4)[4])

    -- <CR> on a directory folds it.
    child:input("4G<CR>")
    expect.matches("^  ▸ nvim%-diff/scene/  2 files %+1 %-2", screen(4)[4])
    expect.matches("^  A new%.lua", screen(5)[5])
  end)

  it("keeps the cursor off the header and refreshes with R", function()
    local r, base = fixture()
    child = child_mod.spawn()
    child:lua(
      [[
      local root, base = ...
      vim.o.showtabline = 0
      local rev = require("nvim-diff.git.rev")
      _G.V = require("nvim-diff.views.diff").open({
        repo = require("nvim-diff.git.repo").discover(root),
        left = rev.commit(base, "main"),
        right = rev.worktree(),
      })
    ]],
      r.root,
      base
    )
    child:input("gg")
    expect.eq(3, child:lua("return vim.api.nvim_win_get_cursor(0)[1]"))
    r:write("zzz.txt", "z\n")
    child:input("R")
    local s = child:screen(12, 12, 1, 35)[1]
    expect.matches("^%? zzz%.txt", s)
    expect.matches("^8 files", child:screen(2, 2, 1, 35)[1])
  end)

  it("folds context and flips layout with the diff keys in a panel diff", function()
    local r = gitrepo.new()
    local long = {}
    for i = 1, 40 do
      long[i] = "line " .. i
    end
    r:write("long.txt", table.concat(long, "\n") .. "\n")
    r:write("small.txt", "s\n")
    local base = r:commit("base")
    long[20] = "LINE 20"
    r:write("long.txt", table.concat(long, "\n") .. "\n")
    r:write("small.txt", "S\n")
    child = child_mod.spawn()
    child:lua(
      [[
      local root, base = ...
      vim.o.showtabline = 0
      local rev = require("nvim-diff.git.rev")
      _G.V = require("nvim-diff.views.diff").open({
        repo = require("nvim-diff.git.repo").discover(root),
        left = rev.commit(base, "main"),
        right = rev.worktree(),
      })
      V:next_file()
      vim.api.nvim_set_current_win(V.file.scene.wins.new)
    ]],
      r.root,
      base
    )
    local function screen(rows)
      return vim.tbl_map(function(s)
        return (s:gsub("%s+$", ""))
      end, child:screen(1, rows, 1, 80))
    end

    -- Both panes open folded: the top 16 lines behind one band each.
    local s = screen(3)
    expect.matches("│·.- 16 unchanged .-│·.- 16 unchanged", s[2])
    expect.matches("│ +17 line 17 +│ +17 line 17", s[3])
    -- zo reveals 10 more in both panes.
    child:input("2Gzo")
    s = screen(3)
    expect.matches("│·.- 6 unchanged .-│·.- 6 unchanged", s[2])
    expect.matches("│ +7 line 7 +│ +7 line 7", s[3])

    -- g<C-x> flips to unified in the same area; the panel keeps its width.
    child:input("g<C-x>")
    expect.matches("── a/long%.txt → b/long%.txt ──", screen(1)[1])
    expect.eq(2, child:lua("return #vim.api.nvim_tabpage_list_wins(0)"))
    expect.eq(35, child:lua("return vim.api.nvim_win_get_width(V.panel.win)"))
    expect.eq(true, child:lua("return vim.api.nvim_get_current_win() == V.file.scene.win"))

    -- <Tab> from the unified pane: the next file opens side-by-side, the cursor in it.
    child:input("<Tab>")
    expect.matches("│ *── a/small%.txt ──.*│ *── b/small%.txt ──", screen(1)[1])
    expect.eq(true, child:lua("return vim.api.nvim_get_current_win() == V.file.scene.wins.new"))
    -- <S-Tab> back: long.txt comes back unified, as it was left.
    child:input("<S-Tab>")
    expect.matches("── a/long%.txt → b/long%.txt ──", screen(1)[1])
    -- And g<C-x> takes it back to two panes. The zo expand is gone: <S-Tab> reopened the file.
    child:input("g<C-x>")
    s = screen(2)
    expect.matches("│ *── a/long%.txt ──.*│ *── b/long%.txt ──", s[1])
    expect.matches("│·.- 16 unchanged .-│·.- 16 unchanged", s[2])
  end)
end)
