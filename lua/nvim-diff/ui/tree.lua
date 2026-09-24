--- The file panel's rows, as data: a directory tree or a flat list of file entries.
---
--- Pure — no buffers, no windows — so the grouping, flattening and roll-ups are tested
--- directly. `ui/panel.lua` turns these rows into text.
---
--- Tree listing: directories first, then files, each sorted bytewise by name; a chain of
--- directories that each hold exactly one directory and no file collapses into one row
--- (`lua/nvim-diff/scene`). Every directory row carries the roll-up of the files under it,
--- so a collapsed directory still says how much changed inside.
---
--- Flat listing: one row per file in the list's own (git) order, no directory rows.

local M = {}

---@alias NvimDiff.Listing "tree"|"flat"

---@class NvimDiff.TreeDirRow
---@field kind "dir"
---@field path string Full git path of the directory (of the last component when flattened).
---@field name string What the row shows: one component, or several joined by `/`.
---@field depth integer
---@field collapsed boolean
---@field files integer Files anywhere under it.
---@field additions integer
---@field deletions integer

---@class NvimDiff.TreeFileRow
---@field kind "file"
---@field entry NvimDiff.FileEntry
---@field name string File name in a tree; the full path in a flat list.
---@field dir string Parent directory of the path, `""` at the top.
---@field depth integer

---@alias NvimDiff.TreeRow NvimDiff.TreeDirRow|NvimDiff.TreeFileRow

---@class NvimDiff.TreeOpts
---@field listing NvimDiff.Listing
--- Directory path to collapsed. A directory absent from the table takes `collapse_default`.
---@field collapsed? table<string, boolean>
---@field collapse_default? boolean

---@class NvimDiff.Tree
---@field rows NvimDiff.TreeRow[] The rows to show; nothing under a collapsed directory.
---@field order NvimDiff.FileEntry[] Every entry in display order, collapsed or not — what next/prev walk.
---@field dirs table<NvimDiff.FileEntry, string[]> An entry's ancestor directory paths, outermost first.

---@param git_path string
---@return string
local function parent(git_path)
  return git_path:match("^(.*)/[^/]*$") or ""
end

---@param git_path string
---@return string
local function basename(git_path)
  return git_path:match("[^/]*$")
end

--- Build the rows for `entries`.
---@param entries NvimDiff.FileEntry[]
---@param opts NvimDiff.TreeOpts
---@return NvimDiff.Tree
function M.build(entries, opts)
  local collapsed = opts.collapsed or {}
  local default = opts.collapse_default or false

  if opts.listing == "flat" then
    local rows, dirs = {}, {}
    for i, entry in ipairs(entries) do
      rows[i] = { kind = "file", entry = entry, name = entry.path, dir = parent(entry.path), depth = 0 }
      dirs[entry] = {}
    end
    return { rows = rows, order = vim.list_slice(entries), dirs = dirs }
  end

  -- Build the directory tree.
  local root = { path = "", subdirs = {}, files = {} }
  for _, entry in ipairs(entries) do
    local node = root
    local dir = parent(entry.path)
    if dir ~= "" then
      local acc = nil
      for part in dir:gmatch("[^/]+") do
        acc = acc and (acc .. "/" .. part) or part
        local child = node.subdirs[part]
        if not child then
          child = { path = acc, subdirs = {}, files = {} }
          node.subdirs[part] = child
        end
        node = child
      end
    end
    node.files[#node.files + 1] = entry
  end

  ---@return integer files, integer additions, integer deletions
  local function rollup(node)
    local files, adds, dels = #node.files, 0, 0
    for _, entry in ipairs(node.files) do
      adds = adds + (entry.change.additions or 0)
      dels = dels + (entry.change.deletions or 0)
    end
    for _, child in pairs(node.subdirs) do
      local f, a, d = rollup(child)
      files, adds, dels = files + f, adds + a, dels + d
    end
    node.count, node.additions, node.deletions = files, adds, dels
    return files, adds, dels
  end
  rollup(root)

  local rows, order, dirs = {}, {}, {}

  local function walk(node, depth, visible, ancestors)
    local names = vim.tbl_keys(node.subdirs)
    table.sort(names)
    for _, name in ipairs(names) do
      local child = node.subdirs[name]
      local label = name
      -- Flatten a chain of single-directory directories into one row.
      while #child.files == 0 and vim.tbl_count(child.subdirs) == 1 do
        local only = next(child.subdirs)
        label = label .. "/" .. only
        child = child.subdirs[only]
      end
      local is_collapsed = collapsed[child.path]
      if is_collapsed == nil then
        is_collapsed = default
      end
      if visible then
        rows[#rows + 1] = {
          kind = "dir",
          path = child.path,
          name = label,
          depth = depth,
          collapsed = is_collapsed,
          files = child.count,
          additions = child.additions,
          deletions = child.deletions,
        }
      end
      local inner = vim.list_extend(vim.list_slice(ancestors), { child.path })
      walk(child, depth + 1, visible and not is_collapsed, inner)
    end

    local files = vim.list_slice(node.files)
    table.sort(files, function(a, b)
      return basename(a.path) < basename(b.path)
    end)
    for _, entry in ipairs(files) do
      order[#order + 1] = entry
      dirs[entry] = ancestors
      if visible then
        rows[#rows + 1] = { kind = "file", entry = entry, name = basename(entry.path), dir = node.path, depth = depth }
      end
    end
  end
  walk(root, 0, true, {})

  return { rows = rows, order = order, dirs = dirs }
end

return M
