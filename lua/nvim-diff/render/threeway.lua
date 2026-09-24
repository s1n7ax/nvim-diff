--- The three-way renderer: view rows and painting for the ours, base and theirs panes of a
--- merge (`diff/merge.lua`).
---
--- Same buffer layout as the side-by-side panes (`scene/buffer.lua`): header at line 1, the
--- file's lines after it, and an empty trailer line when the last display row is filler on
--- any pane. No folds and no inserted blocks, so view row `v` is display row `v` (0 is the
--- header, `rows + 1` the trailer) and the maths is small enough to live here rather than
--- in `render/rowmap.lua`.
---
--- Painting reuses the side-by-side namespaces, groups and priority band: changed lines are
--- a range extmark at 150, tokens at 250, filler one merged `virt_lines` extmark per run.

local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

local M = {}

--- Pane colours relative to the base: ours and theirs add, the base loses.
local GROUPS = {
  ours = { line = "NvimDiffAddLine", token = "NvimDiffAddToken" },
  theirs = { line = "NvimDiffAddLine", token = "NvimDiffAddToken" },
  base = { line = "NvimDiffDelLine", token = "NvimDiffDelToken" },
}

---@class NvimDiff.ThreeWayMap
---@field merge NvimDiff.Merge
---@field trailer boolean
local Map = {}
Map.__index = Map

---@param merge NvimDiff.Merge
---@return NvimDiff.ThreeWayMap
function M.map(merge)
  local trailer = false
  if merge.rows > 0 then
    for _, side in ipairs({ "ours", "base", "theirs" }) do
      if not merge:line_at(side, merge.rows) then
        trailer = true
      end
    end
  end
  return setmetatable({ merge = merge, trailer = trailer }, Map)
end

--- Buffer line of the trailer on `side`, or nil.
---@param side NvimDiff.MergeSide
---@return integer?
function Map:trailer_line(side)
  return self.trailer and self.merge.counts[side] + 2 or nil
end

--- The file's line on buffer line `bl` of `side`, or nil on the header and the trailer.
---@param side NvimDiff.MergeSide
---@param bl integer
---@return integer?
function Map:file_line(side, bl)
  local lnum = bl - 1
  if lnum >= 1 and lnum <= self.merge.counts[side] then
    return lnum
  end
  return nil
end

--- View row of buffer line `bl` on `side`.
---@param side NvimDiff.MergeSide
---@param bl integer
---@return integer?
function Map:line_view(side, bl)
  if bl == 1 then
    return 0
  end
  local lnum = self:file_line(side, bl)
  if lnum then
    return self.merge.row_of[side][lnum]
  end
  if bl == self:trailer_line(side) then
    return self.merge.rows + 1
  end
  return nil
end

---@param side NvimDiff.MergeSide
---@param topline integer
---@param topfill integer
---@return integer?
function Map:top_view(side, topline, topfill)
  local v = self:line_view(side, topline)
  return v and v - (topfill or 0)
end

--- Where a pane showing `side` puts its top so view row `v` is its first screen row: the
--- first line at or after `v`, with the filler between above it.
---@param side NvimDiff.MergeSide
---@param v integer
---@return integer? topline
---@return integer? topfill
function Map:view_top(side, v)
  local merge = self.merge
  if v < 0 or v > merge.rows + 1 then
    return nil, nil
  elseif v == 0 then
    return 1, 0
  end
  for d = v, merge.rows do
    local lnum = merge:line_at(side, d)
    if lnum then
      return lnum + 1, d - v
    end
  end
  if self.trailer then
    return self:trailer_line(side), merge.rows + 1 - v
  end
  return nil, nil
end

---@return integer
function Map:max_top()
  if self.trailer then
    return self.merge.rows + 1
  end
  return self.merge.rows
end

--- Number column width shared by the three panes.
---@param merge NvimDiff.Merge
---@return integer
function M.number_width(merge)
  local n = math.max(merge.counts.ours, merge.counts.base, merge.counts.theirs)
  return math.max(3, #tostring(n))
end

---@param buf integer
---@param row integer 0-based
---@param group string
local function line_mark(buf, row, group)
  api.nvim_buf_set_extmark(buf, sidebyside.ns, row, 0, {
    end_row = row + 1,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = sidebyside.PRIORITY_LINE,
  })
end

--- Paint one pane: header, changed lines, tokens, filler. Idempotent.
---@param buf integer
---@param map NvimDiff.ThreeWayMap
---@param side NvimDiff.MergeSide
function M.paint(buf, map, side)
  local merge = map.merge
  api.nvim_buf_clear_namespace(buf, sidebyside.ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, sidebyside.ns_virt, 0, -1)
  line_mark(buf, 0, "NvimDiffHeader")

  local groups = GROUPS[side]
  for lnum in pairs(merge.changed[side]) do
    line_mark(buf, lnum, groups.line)
    for _, span in ipairs(merge.tokens[side][lnum] or {}) do
      api.nvim_buf_set_extmark(buf, sidebyside.ns, lnum, span[1], {
        end_row = lnum,
        end_col = span[2],
        hl_group = groups.token,
        priority = sidebyside.PRIORITY_TOKEN,
        strict = false,
      })
    end
  end

  local filler_line = { { string.rep(sidebyside.FILLER_CHAR, sidebyside.filler_width()), "NvimDiffFiller" } }
  for _, f in ipairs(merge.fillers[side]) do
    local lines = {}
    for i = 1, f.count do
      lines[i] = filler_line
    end
    api.nvim_buf_set_extmark(buf, sidebyside.ns_virt, f.after, 0, {
      virt_lines = lines,
      virt_lines_leftcol = true,
    })
  end
end

return M
