--- Foreign virtual lines: the ones another plugin draws in a pane — a diagnostic's
--- `virtual_lines`, a code lens, any other `virt_lines` extmark. They push that pane's rows
--- down, so the pair counts them and pads the other pane to match (`render/rowmap.lua`).
---
--- They show up in the real file's pane (`scene/filebuf.lua`), where language servers
--- attach. A scratch pane has no filetype and no server, so nothing normally draws there,
--- but both panes are watched the same way.
---
--- Watching: a decoration provider hears of every redraw of a watched window (`on_win`),
--- with the buffer rows being drawn. Neovim redraws a window when virtual lines change in
--- the part of its buffer it shows, and a code lens is only ever placed from inside a
--- redraw (Neovim's own `on_win`), so this catches both. The watcher is told during the
--- redraw and should count after it, when every provider has placed its marks.
---
--- Only the rows drawn are counted again: a count of the whole buffer walks every mark in
--- it (measured: 3 ms for a 6000-line file rewritten in half, too slow for every scroll
--- step). Only rows in view can put the panes out of line on screen. A count off screen
--- that went stale pads both panes' maps alike, so it keeps them aligned, and it is
--- counted again once that part is drawn.

local api = vim.api

local M = {}

---@alias NvimDiff.ForeignWatcher fun(toprow: integer, botrow: integer)

---@type table<integer, NvimDiff.ForeignWatcher>
local watched = {}

api.nvim_set_decoration_provider(api.nvim_create_namespace("nvim-diff.foreign"), {
  on_win = function(_, win, _, toprow, botrow)
    local fn = watched[win]
    if fn then
      -- An error here would get the provider disabled for the session.
      pcall(fn, toprow, botrow)
    end
    return false
  end,
})

--- Call `fn` with the 0-based buffer rows being drawn on every redraw of `win`, from inside
--- the redraw: it should only schedule its work. Replaces what `win` was watched with.
---@param win integer
---@param fn NvimDiff.ForeignWatcher
function M.watch(win, fn)
  watched[win] = fn
end

--- Stop calling `fn` for `win`; a later `watch` of the window by someone else stays.
---@param win integer
---@param fn NvimDiff.ForeignWatcher
function M.unwatch(win, fn)
  if watched[win] == fn then
    watched[win] = nil
  end
end

--- Whether marks of namespace `ns` show in `win`: a namespace scoped to other windows
--- (`nvim__ns_set`, experimental) does not.
---@param ns integer
---@param win integer
---@return boolean
local function shows_in(ns, win)
  local ok, info = pcall(api.nvim__ns_get, ns)
  if not ok or type(info) ~= "table" or type(info.wins) ~= "table" or #info.wins == 0 then
    return true
  end
  return vim.tbl_contains(info.wins, win)
end

--- How a pane's buffer is laid out around the file's lines.
---@class NvimDiff.ForeignPane
---@field buf integer
---@field win integer
---@field own table<integer, true> The pane's own namespaces.
---@field head integer Buffer lines before the file's first line: file line `l` is buffer line `l + head`.
---@field count integer Lines in the file.

--- The file lines whose virtual lines hang off marks on buffer rows `first..last`.
---@param pane NvimDiff.ForeignPane
---@param first integer
---@param last integer
---@return integer lo
---@return integer hi
function M.lines_of(pane, first, last)
  return first + 1 - pane.head, last + 1 - pane.head
end

--- The virtual lines the pane window shows that none of its own namespaces draws, by the
--- file line they hang off (under line 0 is under the header line; a trailer line's are
--- left out), from marks on buffer rows `first..last` (0-based, default: all). An
--- invalidated mark draws nothing, so it counts for nothing.
---@param pane NvimDiff.ForeignPane
---@param first? integer
---@param last? integer
---@return NvimDiff.ForeignLines
function M.scan(pane, first, last)
  local buf, win, own, head, count = pane.buf, pane.win, pane.own, pane.head, pane.count
  local out = { below = {}, above = {} }
  local shown = {}
  local max = api.nvim_buf_line_count(buf) - 1
  first, last = math.max(0, first or 0), math.min(max, last or max)
  if first > last then
    return out
  end
  local marks = api.nvim_buf_get_extmarks(buf, -1, { first, 0 }, { last, -1 }, { type = "virt_lines", details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    local ns = d.ns_id
    local n = d.virt_lines and #d.virt_lines or 0
    if n > 0 and not own[ns] and not d.invalid then
      if shown[ns] == nil then
        shown[ns] = shows_in(ns, win)
      end
      local l = m[2] + 1 - head
      local t = d.virt_lines_above and out.above or out.below
      if shown[ns] and l >= (d.virt_lines_above and 1 or 0) and l <= count then
        t[l] = (t[l] or 0) + n
      end
    end
  end
  return out
end

--- The virtual lines other plugins hang under buffer row `row` (0-based) in the pane window,
--- or over it when `above`, in the order Neovim draws them: what a parked pane copies
--- (`scene/park.lua`). Each starts at the window's left edge: one drawn after the number
--- column gets `indent` blank cells first.
---@param pane NvimDiff.ForeignPane
---@param row integer
---@param above boolean
---@param indent integer
---@return NvimDiff.VirtLine[]
function M.lines_at(pane, row, above, indent)
  local out = {}
  if row < 0 or row >= api.nvim_buf_line_count(pane.buf) then
    return out
  end
  local marks = api.nvim_buf_get_extmarks(
    pane.buf,
    -1,
    { row, 0 },
    { row, -1 },
    { type = "virt_lines", details = true }
  )
  for _, m in ipairs(marks) do
    local d = m[4]
    if
      d.virt_lines
      and not pane.own[d.ns_id]
      and not d.invalid
      and (d.virt_lines_above or false) == above
      and shows_in(d.ns_id, pane.win)
    then
      for _, line in ipairs(d.virt_lines) do
        if not d.virt_lines_leftcol then
          line = vim.list_extend({ { (" "):rep(indent), "" } }, line)
        end
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- `f` with the counts of file lines `lo..hi` replaced by `fresh`'s, a new count of those
--- lines; nil when that changes nothing.
---@param f NvimDiff.ForeignLines
---@param fresh NvimDiff.ForeignLines
---@param lo integer
---@param hi integer
---@return NvimDiff.ForeignLines?
function M.splice(f, fresh, lo, hi)
  local out, changed = { below = {}, above = {} }, false
  for _, k in ipairs({ "below", "above" }) do
    for l, n in pairs(f[k]) do
      if l < lo or l > hi then
        out[k][l] = n
      elseif fresh[k][l] ~= n then
        changed = true
      end
    end
    for l, n in pairs(fresh[k]) do
      out[k][l] = n
      if f[k][l] ~= n then
        changed = true
      end
    end
  end
  return changed and out or nil
end

--- Whether `f` has any rows.
---@param f? NvimDiff.ForeignLines
---@return boolean
function M.any(f)
  return f ~= nil and (next(f.below) ~= nil or next(f.above) ~= nil)
end

return M
