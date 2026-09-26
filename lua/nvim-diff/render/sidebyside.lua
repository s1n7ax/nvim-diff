--- The side-by-side renderer: paints a `Diff` into two pane buffers with extmarks.
---
--- The buffers already hold `[header], file lines..., [trailer]` (see `scene/buffer.lua` and
--- `render/rowmap.lua`); this module only decorates them. Two namespaces, so the virtual
--- rows can be recomposed (a thread expands) without touching the line highlights:
---
--- * `ns` — the header band, the changed-line backgrounds (priority 150, a range extmark
---   with `hl_eol`, never `line_hl_group`, whose background no token can beat) and the
---   changed tokens (priority 250, background only), both above treesitter's 100.
--- * `ns_virt` — every virtual row: filler and inserted blocks. One extmark per side per
---   anchor line, holding everything below that line in display order, so filler and a
---   block that share an anchor can never be drawn in the wrong order. Without a header
---   line, what comes before the first line is one `virt_lines_above` mark on it.
---
--- All marks are persistent and placed eagerly; no decoration provider (ephemeral marks
--- cannot draw `virt_lines`).

local fold = require("nvim-diff.render.fold")
local rowmap = require("nvim-diff.render.rowmap")

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("nvim-diff.render")
M.ns_virt = api.nvim_create_namespace("nvim-diff.render.virt")

M.PRIORITY_LINE = 150
M.PRIORITY_TOKEN = 250

--- Filler is drawn, not blank: "a line is missing here" must read differently from the
--- blank padding opposite a comment thread.
M.FILLER_CHAR = "┈"

--- Filler runs to the screen edge, not a fixed 400 cells: every virtual line holds its own
--- copy of the text, and an added 50,000-line file is 50,000 filler rows on the old side
--- (60 MB at 400 cells of a 3-byte character). A pane is never wider than `&columns`; the
--- scene repaints the filler when the screen grows.
---@return integer
function M.filler_width()
  return vim.o.columns
end

local BLANK_LINE = { { "", "" } }

local GROUPS = {
  old = { line = "NvimDiffDelLine", token = "NvimDiffDelToken" },
  new = { line = "NvimDiffAddLine", token = "NvimDiffAddToken" },
}

--- The header text for a pane.
---@param label string e.g. `a/lua/server/init.lua`
---@return string
function M.header(label)
  return "── " .. label .. " ──"
end

--- How every pane `winbar` starts, so one can be told from a user's own.
M.WINBAR_START = "%#NvimDiffHeader#"

--- A `winbar` showing `header` as the header band, to the window edge: the pane has no
--- header line (see `render/rowmap.lua`). Sticky, so the file name stays in view.
---@param header string
---@return string
function M.winbar(header)
  return M.WINBAR_START .. (header:gsub("%%", "%%%%")) .. "%="
end

--- Cells of the sign column (`signcolumn=yes:1`) a pane with signs shows.
M.SIGN_WIDTH = 2

---@class NvimDiff.PaneColumns
--- Buffer line 1 is the header: no number there, and every number is one line down.
--- Default true.
---@field header? boolean
--- A sign column (`%s`, `SIGN_WIDTH` cells) before the numbers. Default false.
---@field signs? boolean

--- A `statuscolumn` showing the file's own line numbers: blank on virtual rows, on the
--- header and on the trailer. Both panes should get the same `width` so their text starts
--- in the same column.
---
--- Alignment comes from the item's minimum width (`%3{}`), not from `printf` padding:
--- measured, a `%{}` result loses a leading space, which shifted the digits a column.
---
--- On a closed fold the column is part of the separator band instead — the fill in the
--- separator's colour — so the band runs from column 1 to the window edge.
---@param count integer Lines in this side's file.
---@param width integer Digits.
---@param cols? NvimDiff.PaneColumns
---@return string
function M.statuscolumn(count, width, cols)
  cols = cols or {}
  local head = cols.header == false and 0 or 1
  local folded = "v:virtnum==0&&foldclosed(v:lnum)>0"
  local parts = {}
  if cols.signs then
    parts[#parts + 1] = ("%%{%%%s?'%%#NvimDiffContextSeparator#%s':'%%s'%%}"):format(
      folded,
      fold.FILL:rep(M.SIGN_WIDTH)
    )
  end
  vim.list_extend(parts, {
    ("%%{%%%s?'%%#NvimDiffContextSeparator#':'%%#NonText#'%%}"):format(folded),
    ("%%%d{v:virtnum<0%s||v:lnum>%d?'':%s?repeat('%s',%d):v:lnum-%d}"):format(
      width,
      head == 1 and "||v:lnum==1" or "",
      count + head,
      folded,
      fold.FILL,
      width,
      head
    ),
    ("%%{%%%s?'%s':'%%#Normal# '%%}"):format(folded, fold.FILL),
  })
  return table.concat(parts)
end

--- Cells the `statuscolumn` takes: what a virtual row drawn over it must fill.
---@param diff NvimDiff.Diff
---@param cols? NvimDiff.PaneColumns
---@return integer
function M.column_width(diff, cols)
  return M.number_width(diff) + 1 + (cols and cols.signs and M.SIGN_WIDTH or 0)
end

--- Number column width shared by both panes.
---@param diff NvimDiff.Diff
---@return integer
function M.number_width(diff)
  return math.max(3, #tostring(math.max(diff.old_count, diff.new_count)))
end

---@param buf integer
---@param row integer 0-based
---@param group string
local function line_mark(buf, row, group)
  api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    end_row = row + 1,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = M.PRIORITY_LINE,
  })
end

--- Paint the header, changed lines and changed tokens of one side.
---@param buf integer
---@param map NvimDiff.RowMap
---@param side NvimDiff.Side
local function paint_lines(buf, map, side)
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if map.header then
    line_mark(buf, 0, "NvimDiffHeader")
  end

  local diff = map.diff
  local groups = GROUPS[side]
  local tokens = diff.tokens[side]
  for _, h in ipairs(diff.hunks) do
    for _, r in ipairs(h.rows) do
      local lnum = r[side]
      if lnum then
        local row = map:buf_line(lnum) - 1
        line_mark(buf, row, groups.line)
        -- The line engine sets tokens on `changed` rows only; the structural engine may
        -- also set them on an added or deleted line that is partly new.
        for _, span in ipairs(tokens[lnum] or {}) do
          api.nvim_buf_set_extmark(buf, M.ns, row, span[1], {
            end_row = row,
            end_col = span[2],
            hl_group = groups.token,
            priority = M.PRIORITY_TOKEN,
            strict = false,
          })
        end
      end
    end
  end
end

--- The separator of a reformat fold on a side with no lines in it, drawn as one virtual row
--- in place of the filler: the same band a folded side shows, to the screen edge.
---@param diff NvimDiff.Diff
---@param f NvimDiff.Fold
---@param cols? NvimDiff.PaneColumns
---@return NvimDiff.VirtLine
function M.separator_line(diff, f, cols)
  -- `virt_lines_leftcol` draws over the number column too: fill it as a folded row's
  -- `statuscolumn` would, so the text starts where the other pane's does.
  local lead = fold.FILL:rep(M.column_width(diff, cols))
  local text = fold.label(diff, f) .. " "
  local fill = math.max(0, M.filler_width() - vim.fn.strdisplaywidth(lead .. text))
  return {
    { lead, "NvimDiffContextSeparator" },
    { text, fold.group(f) },
    { fold.FILL:rep(fill), "NvimDiffContextSeparator" },
  }
end

--- The virtual rows of one side, grouped by anchor: `{ anchor = <0-based buffer row>,
--- lines = VirtLine[] }`, ascending; anchor -1 is above buffer row 0. Filler blocks are cut
--- where a block sits inside them, so display order holds within an anchor. Filler inside a
--- closed reformat fold is not drawn: a side with lines there folds them, a side without
--- shows one separator row.
---@param map NvimDiff.RowMap
---@param side NvimDiff.Side
---@param cols? NvimDiff.PaneColumns
---@return { anchor: integer, lines: NvimDiff.VirtLine[] }[]
function M.virt_rows(map, side, cols)
  -- Entries keyed by position in display order: filler row `d` at `d`, a block after row
  -- `d` at `d + 0.5`. Sorting by position sorts by anchor too, since anchors only grow.
  local entries = {}
  local blocks = map.blocks
  local filler_line = { { string.rep(M.FILLER_CHAR, M.filler_width()), "NvimDiffFiller" } }
  local bi = 1

  ---@param upto number
  local function flush_blocks(upto)
    while bi <= #blocks and blocks[bi].row + 0.5 < upto do
      local b = blocks[bi]
      local own = b[side] or {}
      local lines = {}
      for i = 1, rowmap.block_height(b) do
        lines[i] = own[i] or BLANK_LINE
      end
      entries[#entries + 1] = { anchor = map:anchor(side, b.row), lines = lines }
      bi = bi + 1
    end
  end

  for _, f in ipairs(map.diff.fillers[side]) do
    local anchor = map:buf_line(f.after) - 1
    -- Filler never straddles a hunk boundary, so its first row says whether it is folded.
    local fi = fold.find(map.folds, f.row)
    if fi then
      local fd = map.folds[fi]
      if not fold.side_lines(map.diff, fd, side) then
        flush_blocks(f.row)
        entries[#entries + 1] = { anchor = anchor, lines = { M.separator_line(map.diff, fd, cols) } }
      end
      goto continue
    end
    local d = f.row
    local last = f.row + f.count - 1
    while d <= last do
      flush_blocks(d)
      -- This segment runs to the next block inside the filler, or to the end of it.
      local stop = last
      if bi <= #blocks and blocks[bi].row < last then
        stop = math.max(d, blocks[bi].row)
      end
      local lines = {}
      for i = 1, stop - d + 1 do
        lines[i] = filler_line
      end
      entries[#entries + 1] = { anchor = anchor, lines = lines }
      d = stop + 1
    end
    ::continue::
  end
  flush_blocks(math.huge)

  -- Merge consecutive entries on the same anchor.
  local out = {}
  for _, e in ipairs(entries) do
    local last = out[#out]
    if last and last.anchor == e.anchor then
      vim.list_extend(last.lines, e.lines)
    else
      out[#out + 1] = { anchor = e.anchor, lines = e.lines }
    end
  end
  return out
end

--- Replace every virtual row of one side.
---@param buf integer
---@param map NvimDiff.RowMap
---@param side NvimDiff.Side
---@param cols? NvimDiff.PaneColumns
function M.paint_virt(buf, map, side, cols)
  api.nvim_buf_clear_namespace(buf, M.ns_virt, 0, -1)
  for _, v in ipairs(M.virt_rows(map, side, cols)) do
    api.nvim_buf_set_extmark(buf, M.ns_virt, math.max(0, v.anchor), 0, {
      virt_lines = v.lines,
      virt_lines_above = v.anchor < 0,
      virt_lines_leftcol = true,
    })
  end
end

--- Paint both panes in full. Idempotent: clears its own namespaces first.
---@param bufs { old: integer, new: integer }
---@param map NvimDiff.RowMap
---@param cols? NvimDiff.PaneColumns
function M.render(bufs, map, cols)
  for _, side in ipairs({ "old", "new" }) do
    paint_lines(bufs[side], map, side)
    M.paint_virt(bufs[side], map, side, cols)
  end
end

return M
