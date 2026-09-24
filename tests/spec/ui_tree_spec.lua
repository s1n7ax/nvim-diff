local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local entry = require("nvim-diff.scene.entry")
local tree = require("nvim-diff.ui.tree")

---@param specs { [1]: string, [2]?: integer, [3]?: integer }[] path, additions, deletions
---@return NvimDiff.FileEntry[]
local function entries(specs)
  local changes = {}
  for i, s in ipairs(specs) do
    changes[i] = { path = s[1], status = "M", additions = s[2] or 1, deletions = s[3] or 0, binary = false }
  end
  return entry.list(changes).entries
end

--- Rows as short strings: `dir <name> <files> +a -d [folded]` or `file <name>`, indented.
---@param rows NvimDiff.TreeRow[]
---@return string[]
local function show(rows)
  local out = {}
  for i, row in ipairs(rows) do
    local pad = string.rep("  ", row.depth)
    if row.kind == "dir" then
      out[i] = ("%sdir %s %d +%d -%d%s"):format(
        pad,
        row.name,
        row.files,
        row.additions,
        row.deletions,
        row.collapsed and " folded" or ""
      )
    else
      out[i] = pad .. "file " .. row.name
    end
  end
  return out
end

describe("ui.tree", function()
  local list = entries({
    { "src/b.lua", 2, 1 },
    { "README.md", 1, 0 },
    { "src/a.lua", 3, 0 },
    { "lua/nvim-diff/scene/pair.lua", 5, 5 },
    { "lua/nvim-diff/scene/window.lua", 1, 1 },
    { "lua/nvim-diff/ui/hl.lua", 0, 4 },
  })

  it("groups by directory, directories first, flattening single-directory chains", function()
    local built = tree.build(list, { listing = "tree" })
    expect.eq({
      "dir lua/nvim-diff 3 +6 -10",
      "  dir scene 2 +6 -6",
      "    file pair.lua",
      "    file window.lua",
      "  dir ui 1 +0 -4",
      "    file hl.lua",
      "dir src 2 +5 -1",
      "  file a.lua",
      "  file b.lua",
      "file README.md",
    }, show(built.rows))
  end)

  it("walks files in display order and records each file's directories", function()
    local built = tree.build(list, { listing = "tree" })
    local order = vim.tbl_map(function(e)
      return e.path
    end, built.order)
    expect.eq({
      "lua/nvim-diff/scene/pair.lua",
      "lua/nvim-diff/scene/window.lua",
      "lua/nvim-diff/ui/hl.lua",
      "src/a.lua",
      "src/b.lua",
      "README.md",
    }, order)
    expect.eq({ "lua/nvim-diff", "lua/nvim-diff/scene" }, built.dirs[built.order[1]])
    expect.eq({}, built.dirs[built.order[6]])
  end)

  it("hides what is under a folded directory but keeps it in the walk order", function()
    local built = tree.build(list, { listing = "tree", collapsed = { ["lua/nvim-diff/scene"] = true } })
    expect.eq({
      "dir lua/nvim-diff 3 +6 -10",
      "  dir scene 2 +6 -6 folded",
      "  dir ui 1 +0 -4",
      "    file hl.lua",
      "dir src 2 +5 -1",
      "  file a.lua",
      "  file b.lua",
      "file README.md",
    }, show(built.rows))
    expect.eq(6, #built.order)
  end)

  it("folds every directory by default when asked to, and honours explicit unfolds", function()
    local built = tree.build(list, { listing = "tree", collapse_default = true, collapsed = { src = false } })
    expect.eq({
      "dir lua/nvim-diff 3 +6 -10 folded",
      "dir src 2 +5 -1",
      "  file a.lua",
      "  file b.lua",
      "file README.md",
    }, show(built.rows))
  end)

  it("lists every file flat, full paths, in the list's own order", function()
    local built = tree.build(list, { listing = "flat", collapse_default = true })
    expect.eq({
      "file src/b.lua",
      "file README.md",
      "file src/a.lua",
      "file lua/nvim-diff/scene/pair.lua",
      "file lua/nvim-diff/scene/window.lua",
      "file lua/nvim-diff/ui/hl.lua",
    }, show(built.rows))
    expect.eq("src", built.rows[1].dir)
    expect.eq("", built.rows[2].dir)
  end)

  it("counts a binary or untracked file in a directory without stats", function()
    local changes = {
      { path = "d/bin.png", status = "A", binary = true },
      { path = "d/new.txt", status = "?", binary = false },
      { path = "d/x.txt", status = "M", additions = 2, deletions = 3, binary = false },
    }
    local built = tree.build(entry.list(changes).entries, { listing = "tree" })
    expect.eq("dir d 3 +2 -3", show(built.rows)[1])
  end)
end)
