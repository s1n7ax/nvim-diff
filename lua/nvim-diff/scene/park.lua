--- Park and repaint: what a side-by-side pane that cannot show a view row at its top shows
--- instead.
---
--- Neovim needs a buffer line on screen in every window. The top of a window is a buffer
--- line plus `topfill` virtual rows above it, `topfill` stays below the window height, and
--- the top line cannot pass the last line (checked in Neovim's source). So no scroll option
--- puts a pane's top in the upper part of a run of virtual rows taller than the window —
--- tall filler, a long comment thread — or in the virtual rows below its last line: the
--- deleted tail of a file, opposite a real file that cannot grow a trailer line
--- (`render/rowmap.lua`).
---
--- Such a pane is parked: the scroll corrector (`scene/scrollsync.lua`) stops it at the
--- nearest top it can have, and this paints the virtual rows on screen again so the window
--- shows the view rows it should:
---
--- * a run under line `L` (filler mid-file or under the header line, a thread, the tail):
---   `L` at the top — not the line after the run at the bottom, whose number Neovim
---   sometimes draws as the line before's;
--- * a run above line 1 (a pane with no header line): line 1 at the bottom, `topfill` at its
---   cap.
---
--- Only that run's mark is painted again, with the rows in view: at most the window's
--- height, so a scroll step costs the same in a 20,000-row tail as in a short one. The one
--- buffer line left on screen is covered by the row it stands for: an overlay over its text
--- (`virt_text_win_col`, which also hides inlay hints, diagnostics, underlines, search
--- highlights and a sideways scroll), and the pane's `statuscolumn` for its number and
--- sign (`sidebyside.PARK_VAR`). The buffer's text never changes.
---
--- Another plugin's virtual lines in the run (a code lens, a diagnostic's `virtual_lines`)
--- are rows like the pane's own: once the rows in view start among them, they are copied
--- into the run's mark and the plugin's own pushed off screen. Those over line 1 always
--- sit between the run's mark and the line, so a parked run above line 1 keeps them at the
--- bottom of the window.
---
--- Everything lives in the pane's namespace for virtual rows (a real file's is scoped to its
--- window, `scene/filebuf.lua`), so painting the pane's virtual rows again drops the park.

local foreign = require("nvim-diff.scene.foreign")
local sidebyside = require("nvim-diff.render.sidebyside")

local api = vim.api

local M = {}

--- Above the overlays other plugins draw on the hidden line (inlay hints, diagnostics).
M.PRIORITY = 10000

local BLANK_LINE = { { "", "" } }

---@class NvimDiff.ParkPane
---@field buf integer
---@field win integer
---@field ns integer The pane's namespace for virtual rows.
---@field map NvimDiff.RowMap
---@field side NvimDiff.Side
---@field cols NvimDiff.PaneColumns
--- The pane's virtual rows as painted, by `key(row, above)`.
---@field marks table<integer, NvimDiff.VirtRows>
---@field foreign NvimDiff.ForeignPane

--- A pane's park: the run's mark, painted with the rows in view, and the hidden line's cover.
---@class NvimDiff.Park
---@field row integer 0-based buffer row of the run's mark.
---@field above boolean
---@field id integer The run's mark.
--- The mark's own rows, painted back by `unpark`; nil when the park made the mark.
---@field lines? NvimDiff.VirtLine[]
---@field cover? integer The overlay mark on the hidden line.
---@field line? integer The hidden line.

--- The key of a mark of virtual rows in `ParkPane.marks`.
---@param row integer
---@param above boolean
---@return integer
function M.key(row, above)
  return row * 2 + (above and 1 or 0)
end

--- The marks of `rows`, by `key`.
---@param rows NvimDiff.VirtRows[]
---@return table<integer, NvimDiff.VirtRows>
function M.index(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[M.key(r.row, r.above)] = r
  end
  return out
end

---@param win integer
---@param lnum integer
---@return boolean
local function folded(win, lnum)
  return api.nvim_win_call(win, function()
    return vim.fn.foldclosed(lnum)
  end) ~= -1
end

--- Where a pane parks to show view row `v`, which no top of its shows: the buffer line left
--- on screen, whether it is line 1 at the bottom (`lead`) rather than at the top, and the
--- view row of the run's first row. Nil when that line is inside a closed fold, where no
--- overlay shows.
---@param pane NvimDiff.ParkPane
---@param v integer
---@return { line: integer, lead: boolean, first: integer }?
function M.spot(pane, v)
  local map, side = pane.map, pane.side
  local tl = map:view_top(side, v)
  local line, lead, first
  if tl == 1 then
    -- Line 1 with the run above it: no header line (with one, `v` would be row 0).
    line, lead, first = 1, true, 0
  else
    -- The line above the run; past the last line, the last line.
    line, lead = tl and tl - 1 or api.nvim_buf_line_count(pane.buf), false
    local lv = map:line_view(side, line)
    if not lv then
      return nil
    end
    first = lv + 1
  end
  if folded(pane.win, line) then
    return nil
  end
  return { line = line, lead = lead, first = first }
end

--- The highlight group of a chunk, one name: `Normal` for none.
---@param hl string|string[]|nil
---@return string
local function group(hl)
  if type(hl) == "table" then
    hl = hl[#hl]
  end
  return type(hl) == "string" and hl ~= "" and hl or "Normal"
end

--- `line` cut at display cell `n`: the chunks of its first `n` cells, padded with blanks,
--- and the chunks after.
---@param line NvimDiff.VirtLine
---@param n integer
---@return NvimDiff.VirtLine head
---@return NvimDiff.VirtLine tail
local function cut(line, n)
  local head, tail, w = {}, {}, 0
  for _, c in ipairs(line) do
    local text = c[1]
    if w >= n then
      tail[#tail + 1] = c
    elseif w + vim.fn.strdisplaywidth(text) <= n then
      head[#head + 1] = c
      w = w + vim.fn.strdisplaywidth(text)
    else
      local chars, i = vim.fn.strcharlen(text), 0
      while i < chars do
        local cw = vim.fn.strdisplaywidth(vim.fn.strcharpart(text, i, 1))
        if w + cw > n then
          break
        end
        w, i = w + cw, i + 1
      end
      head[#head + 1] = { vim.fn.strcharpart(text, 0, i), c[2] }
      tail[#tail + 1] = { vim.fn.strcharpart(text, i), c[2] }
    end
  end
  if w < n then
    head[#head + 1] = { (" "):rep(n - w), "" }
  end
  return head, tail
end

--- `chunks` as a statusline string.
---@param chunks NvimDiff.VirtLine
---@return string
local function stl(chunks)
  local out = {}
  for _, c in ipairs(chunks) do
    out[#out + 1] = "%#" .. group(c[2]) .. "#" .. c[1]:gsub("%%", "%%%%")
  end
  return table.concat(out)
end

--- What the `statuscolumn` shows on the hidden line (`sidebyside.PARK_COL_VAR`): the first
--- cells of `line`, the row drawn over it, in the column's parts.
---@param pane NvimDiff.ParkPane
---@param line NvimDiff.VirtLine
---@return table<string, string> column
---@return NvimDiff.VirtLine rest The chunks after the column.
local function column(pane, line)
  local diff, cols = pane.map.diff, pane.cols
  local head, rest = cut(line, sidebyside.column_width(diff, cols))
  local sign = {}
  if cols.signs then
    sign, head = cut(head, sidebyside.SIGN_WIDTH)
  end
  local num, tail = cut(head, sidebyside.number_width(diff))
  local text = {}
  for _, c in ipairs(num) do
    text[#text + 1] = c[1]
  end
  local col = {
    sign = stl(sign),
    hl = "%#" .. group(num[1] and num[1][2]) .. "#",
    num = table.concat(text),
    tail = stl(tail),
  }
  return col, rest
end

--- The overlay text over the hidden line: `rest`, then blanks to the screen edge so nothing
--- of the line shows past it. No highlight is the window's own background, as on a virtual
--- row.
---@param rest NvimDiff.VirtLine
---@return NvimDiff.VirtLine
local function overlay(rest)
  local out, w = {}, 0
  for _, c in ipairs(rest) do
    out[#out + 1] = { c[1], c[2] or "" }
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  local pad = vim.o.columns - w
  if pad > 0 then
    out[#out + 1] = { (" "):rep(pad), "" }
  end
  return out
end

--- Park `pane` so the window shows view row `v` first, `height` text rows. `prev` is the
--- pane's park now, painted back first when this one is elsewhere. Returns the park, the
--- top to put the window at and the hidden line, where the cursor stays; nil when the pane
--- cannot park there (`spot`), with `prev` painted back.
---@param pane NvimDiff.ParkPane
---@param v integer
---@param height integer
---@param prev? NvimDiff.Park
---@return NvimDiff.Park? park
---@return integer? topline
---@return integer? topfill
function M.park(pane, v, height, prev)
  local s = M.spot(pane, v)
  local row, above = s and (s.lead and 0 or s.line - 1), s and s.lead
  if prev and not (s and prev.row == row and prev.above == above) then
    M.unpark(pane, prev)
    prev = nil
  end
  if not s then
    return nil
  end

  -- The run, in the order Neovim draws it: the pane's own rows, then other plugins' — under
  -- the line, then over the next one when it shows.
  local mark = pane.marks[M.key(row, above)]
  local own = mark and mark.lines or {}
  local indent = sidebyside.column_width(pane.map.diff, pane.cols)
  local others = foreign.lines_at(pane.foreign, row, above, indent)
  local count = api.nvim_buf_line_count(pane.buf)
  if not above and s.line < count and not folded(pane.win, s.line + 1) then
    vim.list_extend(others, foreign.lines_at(pane.foreign, row + 1, true, indent))
  end
  ---@param i integer 0-based row of the run.
  ---@return NvimDiff.VirtLine?
  local function at(i)
    if i < #own then
      return own[i + 1]
    end
    return others[i - #own + 1]
  end

  local k = v - s.first
  local lines, cover
  if s.lead then
    -- Window rows 0 .. height - 2 are the last rows over line 1: the mark's, then the
    -- other plugins', which stay where they are.
    local n = math.max(0, height - 1 - #others)
    lines = vim.list_slice(own, k + 1, k + n)
    cover = at(k + height - 1)
  elseif k + 1 < #own then
    -- Window rows 1 .. are the mark's from row k + 1; other plugins' follow as drawn.
    lines = vim.list_slice(own, k + 2, math.min(#own, k + height))
    cover = at(k)
  else
    -- The rows in view are other plugins': copies, theirs pushed off screen.
    lines = {}
    for i = k + 1, k + height - 1 do
      local l = at(i)
      if not l then
        break
      end
      lines[#lines + 1] = l
    end
    while #others > 0 and #lines < height - 1 do
      lines[#lines + 1] = BLANK_LINE
    end
    cover = at(k)
  end

  local id = sidebyside.set_virt(pane.buf, pane.ns, row, above, lines, prev and prev.id or mark and mark.id)
  local park = prev or { row = row, above = above, id = id, lines = mark and mark.lines }
  local col, rest = column(pane, cover or BLANK_LINE)
  park.line = s.line
  park.cover = api.nvim_buf_set_extmark(pane.buf, pane.ns, s.line - 1, 0, {
    id = park.cover,
    virt_text = overlay(rest),
    virt_text_win_col = 0,
    hl_mode = "replace",
    priority = M.PRIORITY,
  })
  vim.w[pane.win][sidebyside.PARK_VAR] = s.line
  vim.w[pane.win][sidebyside.PARK_COL_VAR] = col
  if s.lead then
    return park, 1, height - 1
  end
  return park, s.line, 0
end

--- Paint `park`'s run back as it is and uncover its line.
---@param pane NvimDiff.ParkPane
---@param park NvimDiff.Park
function M.unpark(pane, park)
  if api.nvim_buf_is_valid(pane.buf) then
    if park.lines then
      sidebyside.set_virt(pane.buf, pane.ns, park.row, park.above, park.lines, park.id)
    else
      pcall(api.nvim_buf_del_extmark, pane.buf, pane.ns, park.id)
    end
    pcall(api.nvim_buf_del_extmark, pane.buf, pane.ns, park.cover)
  end
  M.clear(pane.win)
end

--- Take the hidden line out of `win`'s `statuscolumn`.
---@param win integer
function M.clear(win)
  if api.nvim_win_is_valid(win) then
    vim.w[win][sidebyside.PARK_VAR] = nil
    vim.w[win][sidebyside.PARK_COL_VAR] = nil
  end
end

return M
