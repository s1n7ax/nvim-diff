--- The side-by-side renderer: paints a `Diff` into two pane buffers with extmarks.
---
--- The buffers already hold `[header], file lines..., [trailer]` (see `scene/buffer.lua` and
--- `render/rowmap.lua`); this module only decorates them. Two namespaces, so the virtual
--- rows can be recomposed (a thread expands) without touching the line highlights:
---
--- * `ns` — the header band, the changed-line backgrounds (priority 150, a range extmark
---   with `hl_eol`, never `line_hl_group`, whose background no token can beat) and the
---   changed tokens (priority 250, background only), both above treesitter's 100.
--- * `ns_virt` — every virtual row: filler, inserted blocks, and the padding opposite
---   another plugin's virtual lines. One extmark per side per anchor line, holding
---   everything below that line in display order, so filler and a block that share an
---   anchor can never be drawn in the wrong order. Without a header line, what comes before
---   the first line is one `virt_lines_above` mark on it; so is padding after a closed
---   fold, on the line after it.
---
--- A pane showing a real file's buffer (`scene/filebuf.lua`) is painted into namespaces of
--- its own instead, scoped to its window, so the marks never show in another window on the
--- file: the painters take the namespaces to use, these two by default.
---
--- A pane parked inside virtual rows it cannot scroll to has one mark painted again with
--- the rows in view, and its one buffer line covered (`scene/park.lua`).
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
--- The pane can be parked (`scene/park.lua`): the line it hides shows the column of the
--- row drawn over it instead (`PARK_VAR`, `PARK_COL_VAR`). Default false.
---@field park? boolean

--- Window variable: the buffer line a parked pane hides (`scene/park.lua`), 0 for none.
M.PARK_VAR = "nvim_diff_park"
--- Window variable: what the `statuscolumn` shows on that line, in its parts — `sign`,
--- `hl` and `tail` statusline strings, `num` plain text of the number's width.
M.PARK_COL_VAR = "nvim_diff_park_col"

--- `expr`, a `statuscolumn` expression for a row that is no virtual line, with `{l}` the
--- buffer line the row is — which `v:lnum` is not always. Neovim 0.12 gives the top line of
--- a window the number of the line above it when `topfill` shows fewer than all of the
--- virtual lines that line has below it (`draw_statuscol()` counts them all as still to
--- come): the line after filler or a thread, at the top of a pane with only the end of those
--- rows above it, would read as the line before, and a trailer as the last line — whenever
--- the pane is drawn afresh, as the pane the corrector moves always is. Only then is
--- `v:lnum` above the window's top line.
---
--- The top line is read once, and from `winsaveview()`: `line('w0')` may scroll the window
--- it is drawing.
---@param expr string
---@return string
function M.at_line(expr)
  return ("(v:lnum<winsaveview().topline?%s:%s)"):format((expr:gsub("{l}", "(v:lnum+1)")), (expr:gsub("{l}", "v:lnum")))
end

--- A `statuscolumn` showing the file's own line numbers: blank on virtual rows, on the
--- header and on the trailer. Both panes should get the same `width` so their text starts
--- in the same column.
---
--- Alignment comes from the item's minimum width (`%3{}`), not from `printf` padding:
--- measured, a `%{}` result loses a leading space, which shifted the digits a column.
---
--- On a closed fold the column is part of the separator band instead — the fill in the
--- separator's colour — so the band runs from column 1 to the window edge. On the line a
--- parked pane hides, it is the start of the row drawn over that line.
---@param count integer Lines in this side's file.
---@param width integer Digits.
---@param cols? NvimDiff.PaneColumns
---@return string
function M.statuscolumn(count, width, cols)
  cols = cols or {}
  local head = cols.header == false and 0 or 1
  local folded = "v:virtnum==0&&" .. M.at_line("foldclosed({l})>0")
  -- The window variable first: unparked, the line is not worked out for it.
  local hidden = cols.park
    and ("get(w:,'%s',0)>0&&v:virtnum==0&&%s"):format(M.PARK_VAR, M.at_line(("get(w:,'%s',0)=={l}"):format(M.PARK_VAR)))
  -- Each part asks first whether this is the hidden line, and shows its own piece of it.
  local function park(piece)
    return hidden and ("%s?w:%s.%s:"):format(hidden, M.PARK_COL_VAR, piece) or ""
  end
  local parts = {}
  if cols.signs then
    parts[#parts + 1] = ("%%{%%%s%s?'%%#NvimDiffContextSeparator#%s':'%%s'%%}"):format(
      park("sign"),
      folded,
      fold.FILL:rep(M.SIGN_WIDTH)
    )
  end
  vim.list_extend(parts, {
    ("%%{%%%s%s?'%%#NvimDiffContextSeparator#':'%%#NonText#'%%}"):format(park("hl"), folded),
    ("%%%d{%sv:virtnum<0?'':%s}"):format(
      width,
      park("num"),
      M.at_line(
        ("{l}>%d%s?'':foldclosed({l})>0?repeat('%s',%d):{l}-%d"):format(
          count + head,
          head == 1 and "||{l}==1" or "",
          fold.FILL,
          width,
          head
        )
      )
    ),
    ("%%{%%%s%s?'%s':'%%#Normal# '%%}"):format(park("tail"), folded, fold.FILL),
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

--- The namespaces one pane is painted into.
---@class NvimDiff.PaneNs
---@field line integer The header band, changed lines and tokens (`ns`).
---@field virt integer Virtual rows (`ns_virt`).

--- The namespaces every scratch pane is painted into.
---@type NvimDiff.PaneNs
M.SHARED_NS = { line = M.ns, virt = M.ns_virt }

---@param buf integer
---@param ns integer
---@param row integer 0-based
---@param group string
local function line_mark(buf, ns, row, group)
  api.nvim_buf_set_extmark(buf, ns, row, 0, {
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
---@param ns integer
local function paint_lines(buf, map, side, ns)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if map.header then
    line_mark(buf, ns, 0, "NvimDiffHeader")
  end

  local diff = map.diff
  local groups = GROUPS[side]
  local tokens = diff.tokens[side]
  for _, h in ipairs(diff.hunks) do
    for _, r in ipairs(h.rows) do
      local lnum = r[side]
      if lnum then
        local row = map:buf_line(lnum) - 1
        line_mark(buf, ns, row, groups.line)
        -- The line engine sets tokens on `changed` rows only; the structural engine may
        -- also set them on an added or deleted line that is partly new.
        for _, span in ipairs(tokens[lnum] or {}) do
          api.nvim_buf_set_extmark(buf, ns, row, span[1], {
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

--- One mark's worth of virtual rows: `lines` hang under buffer row `row` (0-based), or over
--- it when `above`.
---@class NvimDiff.VirtRows
---@field row integer
---@field above boolean
---@field lines NvimDiff.VirtLine[]
---@field id? integer The mark, once painted.

--- The virtual rows of one side, grouped by where they hang, in display order. Filler
--- blocks are cut where a block sits inside them, so display order holds within a mark.
--- Filler inside a closed reformat fold is not drawn: a side with lines there folds them, a
--- side without shows one separator row. The rows another plugin draws (a block's `ext`)
--- are left out: they follow these (`render/rowmap.lua`).
---@param map NvimDiff.RowMap
---@param side NvimDiff.Side
---@param cols? NvimDiff.PaneColumns
---@return NvimDiff.VirtRows[]
function M.virt_rows(map, side, cols)
  -- Pushed in display order: filler row `d` at `d`, a block after row `d` at `d + 0.5`.
  -- Where the rows hang only moves down that order, so a mark's rows are contiguous.
  local out = {}
  local blocks = map.blocks
  local filler_line = { { string.rep(M.FILLER_CHAR, M.filler_width()), "NvimDiffFiller" } }
  local bi = 1

  ---@param row integer
  ---@param above boolean
  ---@param lines NvimDiff.VirtLine[]
  local function push(row, above, lines)
    if #lines == 0 then
      return
    end
    local last = out[#out]
    if last and last.row == row and last.above == above then
      vim.list_extend(last.lines, lines)
    else
      out[#out + 1] = { row = row, above = above, lines = lines }
    end
  end

  ---@param upto number
  local function flush_blocks(upto)
    while bi <= #blocks and blocks[bi].row + 0.5 < upto do
      local b = blocks[bi]
      local own = b[side] or {}
      local lines = {}
      for i = 1, rowmap.own_rows(b, side) do
        lines[i] = own[i] or BLANK_LINE
      end
      local row, above = map:block_anchor(side, b.row)
      push(row, above, lines)
      bi = bi + 1
    end
  end

  for _, f in ipairs(map.diff.fillers[side]) do
    -- Hung under the line before it, or over the first line when there is none.
    local anchor = map:buf_line(f.after) - 1
    local row, above = math.max(0, anchor), anchor < 0
    -- Filler never straddles a hunk boundary, so its first row says whether it is folded.
    local fi = fold.find(map.folds, f.row)
    if fi then
      local fd = map.folds[fi]
      if not fold.side_lines(map.diff, fd, side) then
        flush_blocks(f.row)
        push(row, above, { M.separator_line(map.diff, fd, cols) })
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
      push(row, above, lines)
      d = stop + 1
    end
    ::continue::
  end
  flush_blocks(math.huge)
  return out
end

--- Rows kept from each end of a tall mark of virtual rows (`set_virt`): no window is taller.
---@return integer
function M.virt_keep()
  return vim.o.lines
end

--- `lines` with the rows no window can show blanked. Neovim shows the virtual rows between
--- two buffer lines only next to one of them — under the first line, or over the second
--- with `topfill`, which stays below the window height — so a row further than a window's
--- height from both ends of its mark is never drawn (a parked pane draws its own copy,
--- `scene/park.lua`). Blank rows are cheap to place; a filler row to the screen edge is not
--- (measured: 190 ms for a 20,000-row deleted tail, 4 ms blank).
---@param lines NvimDiff.VirtLine[]
---@return NvimDiff.VirtLine[]
local function sparse(lines)
  local keep = M.virt_keep()
  local n = #lines
  if n <= 2 * keep then
    return lines
  end
  local out = {}
  for i = 1, n do
    out[i] = (i <= keep or i > n - keep) and lines[i] or BLANK_LINE
  end
  return out
end

--- Place (or, with `id`, replace) one mark of virtual rows: `lines` under buffer row `row`,
--- or over it when `above`.
---@param buf integer
---@param ns integer
---@param row integer 0-based
---@param above boolean
---@param lines NvimDiff.VirtLine[]
---@param id? integer
---@return integer id
function M.set_virt(buf, ns, row, above, lines, id)
  return api.nvim_buf_set_extmark(buf, ns, row, 0, {
    id = id,
    virt_lines = sparse(lines),
    virt_lines_above = above,
    virt_lines_leftcol = true,
    -- Sorts before another plugin's mark on the same spot (right gravity, the default),
    -- so its virtual lines come after these, where the row map counts them.
    right_gravity = false,
  })
end

--- Replace every virtual row of one side. Returns them, with their marks.
---@param buf integer
---@param map NvimDiff.RowMap
---@param side NvimDiff.Side
---@param cols? NvimDiff.PaneColumns
---@param ns? integer Default `ns_virt`.
---@return NvimDiff.VirtRows[]
function M.paint_virt(buf, map, side, cols, ns)
  ns = ns or M.ns_virt
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local rows = M.virt_rows(map, side, cols)
  for _, v in ipairs(rows) do
    v.id = M.set_virt(buf, ns, v.row, v.above, v.lines)
  end
  return rows
end

--- Paint both panes in full. Idempotent: clears its own namespaces first. Returns each
--- side's virtual rows (`paint_virt`).
---@param bufs { old: integer, new: integer }
---@param map NvimDiff.RowMap
---@param cols? NvimDiff.PaneColumns
---@param nss? { old?: NvimDiff.PaneNs, new?: NvimDiff.PaneNs } Default `SHARED_NS` for both.
---@return { old: NvimDiff.VirtRows[], new: NvimDiff.VirtRows[] }
function M.render(bufs, map, cols, nss)
  local out = {}
  for _, side in ipairs({ "old", "new" }) do
    local ns = nss and nss[side] or M.SHARED_NS
    paint_lines(bufs[side], map, side, ns.line)
    out[side] = M.paint_virt(bufs[side], map, side, cols, ns.virt)
  end
  return out
end

return M
