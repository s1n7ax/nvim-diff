--- Context folding, as pure data: which display rows collapse into a separator row, how an
--- expand shrinks a fold, and what the separator says.
---
--- A fold is a range of display rows (`diff/hunk.lua`'s vocabulary) that shows as **one**
--- row in both panes. Both panes always carry the same fold list, so mirroring fold state
--- across panes is structural rather than a matter of keeping two lists in step. Two
--- kinds:
---
--- * `context` — the middle of an unchanged run, keeping `context` rows next to each hunk
---   (git's and GitHub's `-U3`, so the visible lines are exactly the commentable ones).
---   Both sides have a line on every row, and each pane folds its own lines.
--- * `reformat` — a whole hunk marked `formatting_only` by the structural engine. A side
---   with lines in it folds them; a side with none shows the separator as one virtual row
---   in place of its filler. Either way the hunk is one row on both sides and costs no
---   filler.
---
--- Invariants the row map relies on: folds are sorted, disjoint, and no inserted block sits
--- after a row inside a fold (`reveal` splits a fold around a block's row). A context fold
--- never ends on the row just above a hunk, so no filler ever hangs off a folded line —
--- measured, `virt_lines` anchored inside a closed fold, its last line included, are not
--- drawn.
---
--- No windows, no buffers.

local M = {}

---@alias NvimDiff.FoldKind "context"|"reformat"

---@class NvimDiff.Fold
---@field first integer First display row.
---@field last integer Last display row.
---@field kind NvimDiff.FoldKind
--- Identity of the fold as first computed. A fold shrunk or split by expanding keeps it, so
--- collapsing can put the original back.
---@field id integer
---@field hunk? integer `reformat` only: the hunk's index.

--- Unchanged rows kept visible next to a hunk.
M.CONTEXT = 3
--- Rows one expand reveals.
M.STEP = 10
--- Fewest unchanged rows worth a separator. A separator over one line costs the same row
--- as the line and hides it, so a one-row fold is never made, and an expand that would
--- leave one reveals it too.
M.MIN_ROWS = 2

--- Fill of the separator row, from column 1 to the window edge.
M.FILL = "·"

---@class NvimDiff.FoldOpts
---@field context? integer Default `M.CONTEXT`; values below 1 are raised to 1, so the row
--- above a hunk (the anchor of its filler) is never folded.

--- The folds a diff opens with.
---@param diff NvimDiff.Diff
---@param opts? NvimDiff.FoldOpts
---@return NvimDiff.Fold[]
function M.compute(diff, opts)
  local context = math.max(1, (opts and opts.context) or M.CONTEXT)
  local folds = {}
  local last_row = diff.rows

  -- Walk unchanged runs and reformat hunks together, in display order.
  local items = {}
  for _, run in ipairs(diff.unchanged) do
    items[#items + 1] = { row = run.row, run = run }
  end
  for _, h in ipairs(diff.hunks) do
    if h.formatting_only and #h.rows > 0 then
      items[#items + 1] = { row = h.row, hunk = h }
    end
  end
  table.sort(items, function(a, b)
    return a.row < b.row
  end)

  for _, item in ipairs(items) do
    if item.run then
      local run = item.run
      local first, last = run.row, run.row + run.count - 1
      -- A run touching the top (or bottom) of the file has no hunk there to keep context for.
      if first > 1 then
        first = first + context
      end
      if last < last_row then
        last = last - context
      end
      if last - first + 1 >= M.MIN_ROWS then
        folds[#folds + 1] = { first = first, last = last, kind = "context" }
      end
    else
      local h = item.hunk
      folds[#folds + 1] = { first = h.row, last = h.row + #h.rows - 1, kind = "reformat", hunk = h.index }
    end
  end
  for i, f in ipairs(folds) do
    f.id = i
  end
  return folds
end

--- Index of the fold containing display row `d`, if any.
---@param folds NvimDiff.Fold[]
---@param d integer
---@return integer?
function M.find(folds, d)
  local lo, hi = 1, #folds
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local f = folds[mid]
    if d < f.first then
      hi = mid - 1
    elseif d > f.last then
      lo = mid + 1
    else
      return mid
    end
  end
  return nil
end

---@param f NvimDiff.Fold
---@return NvimDiff.Fold
local function copy(f)
  return { first = f.first, last = f.last, kind = f.kind, id = f.id, hunk = f.hunk }
end

--- Which way an expand reveals rows:
--- * `down` — the fold's first rows, continuing the hunk above it; the separator moves down.
--- * `up` — its last rows, leading into the hunk below it; the separator stays put.
---@alias NvimDiff.FoldDir "down"|"up"

--- The direction to expand a fold in when the caller does not say: `up` for a fold at the
--- top of the file (only the hunk below it gives it a meaning), `down` otherwise.
---@param fold NvimDiff.Fold
---@return NvimDiff.FoldDir
function M.default_dir(fold)
  return fold.first == 1 and "up" or "down"
end

--- The fold list after expanding fold `i` by `n` rows (`nil`: all of it). A reformat fold
--- always opens whole: revealing part of a reflowed hunk would show filler for nothing.
---@param folds NvimDiff.Fold[]
---@param i integer
---@param n? integer
---@param dir? NvimDiff.FoldDir Default `M.default_dir`.
---@return NvimDiff.Fold[]
function M.expand(folds, i, n, dir)
  local out = {}
  for k, f in ipairs(folds) do
    if k ~= i then
      out[#out + 1] = f
    elseif n and f.kind == "context" and f.last - f.first + 1 - n >= M.MIN_ROWS then
      local g = copy(f)
      if (dir or M.default_dir(f)) == "up" then
        g.last = g.last - n
      else
        g.first = g.first + n
      end
      out[#out + 1] = g
    end
  end
  return out
end

--- The fold list with every fold of `base` whose `id` is in `ids` put back whole, replacing
--- whatever is left of it.
---@param folds NvimDiff.Fold[]
---@param base NvimDiff.Fold[]
---@param ids table<integer, true>
---@return NvimDiff.Fold[]
function M.restore(folds, base, ids)
  local out = {}
  for _, f in ipairs(folds) do
    if not ids[f.id] then
      out[#out + 1] = f
    end
  end
  for _, f in ipairs(base) do
    if ids[f.id] then
      out[#out + 1] = copy(f)
    end
  end
  table.sort(out, function(a, b)
    return a.first < b.first
  end)
  return out
end

--- The fold list with display row `d` visible: a context fold containing it is split
--- around it, a reformat fold containing it opens. For blocks (comment threads), which
--- must hang off a visible row.
---@param folds NvimDiff.Fold[]
---@param d integer
---@return NvimDiff.Fold[]
function M.reveal(folds, d)
  local i = M.find(folds, d)
  if not i then
    return folds
  end
  local f = folds[i]
  local out = {}
  for k = 1, i - 1 do
    out[#out + 1] = folds[k]
  end
  if f.kind == "context" then
    if f.first < d then
      local a = copy(f)
      a.last = d - 1
      out[#out + 1] = a
    end
    if d < f.last then
      local b = copy(f)
      b.first = d + 1
      out[#out + 1] = b
    end
  end
  for k = i + 1, #folds do
    out[#out + 1] = folds[k]
  end
  return out
end

--- The lines of `side` a fold covers, inclusive; nil when it has none there (a reformat
--- hunk that is pure addition or deletion on that side).
---@param diff NvimDiff.Diff
---@param fold NvimDiff.Fold
---@param side NvimDiff.Side
---@return integer? first
---@return integer? last
function M.side_lines(diff, fold, side)
  if fold.kind == "reformat" then
    local h = diff.hunks[fold.hunk]
    local count = h[side .. "_count"]
    if count == 0 then
      return nil, nil
    end
    local start = h[side .. "_start"]
    return start, start + count - 1
  end
  local a_old, a_new = diff:line_at(fold.first)
  local b_old, b_new = diff:line_at(fold.last)
  if side == "old" then
    return a_old, b_old
  end
  return a_new, b_new
end

-- The separator text -------------------------------------------------------------------

--- Longest scope text shown, in characters.
M.SCOPE_MAX = 60

--- Whether a line can name the scope that follows it — git's default `funcname` rule (a
--- line starting with a letter, `_` or `$`), minus lone words such as `end`, `else` or
--- `fi`, which close scopes rather than open them.
---@param text string
---@return boolean
function M.is_scope_line(text)
  if not text:find("^[%a_$]") then
    return false
  end
  return not text:find("^[%w_$]+%s*[;,]?%s*$")
end

--- Sorted line numbers of every scope line of a file. Built once per side, so naming the
--- scope of any fold is a binary search.
---@param lines string[]
---@return integer[]
function M.scope_index(lines)
  local out = {}
  for i, text in ipairs(lines) do
    if M.is_scope_line(text) then
      out[#out + 1] = i
    end
  end
  return out
end

--- The enclosing scope of line `lnum`, cheaply: the nearest scope line at or above it, the
--- same line git puts after `@@` for a hunk starting below it. Nil when there is none.
---@param lines string[]
---@param index integer[] From `scope_index(lines)`.
---@param lnum integer
---@return string?
function M.scope_at(lines, index, lnum)
  local lo, hi, found = 1, #index, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if index[mid] <= lnum then
      found = index[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if not found then
    return nil
  end
  local text = lines[found]:gsub("%s*{?%s*$", "")
  if vim.fn.strchars(text) > M.SCOPE_MAX then
    text = vim.fn.strcharpart(text, 0, M.SCOPE_MAX - 1) .. "…"
  end
  return text
end

--- The separator's text, up to where the fill takes over.
---
---     ··· 128 unchanged lines ··· impl Server ·····················
---     ··· reformatted into 5 lines — no semantic change ···········
---@param diff NvimDiff.Diff
---@param fold NvimDiff.Fold
---@param scope? string
---@return string
function M.label(diff, fold, scope)
  local dots = M.FILL:rep(3)
  if fold.kind == "reformat" then
    local n = diff.hunks[fold.hunk].new_count
    return ("%s reformatted into %d line%s — no semantic change"):format(dots, n, n == 1 and "" or "s")
  end
  local n = fold.last - fold.first + 1
  local text = ("%s %d unchanged line%s"):format(dots, n, n == 1 and "" or "s")
  if scope and scope ~= "" then
    text = text .. " " .. dots .. " " .. scope
  end
  return text
end

--- Highlight group of a separator's text.
---@param fold NvimDiff.Fold
---@return string
function M.group(fold)
  return fold.kind == "reformat" and "NvimDiffReformatSeparator" or "NvimDiffContextSeparator"
end

--- Separator text per buffer, keyed by the fold's first buffer line: what `foldtext` shows.
---@type table<integer, table<integer, [string, string]>>
M.texts = {}

--- `foldtext` of every pane: the text registered for this buffer's fold. The row's
--- background comes from the window's `Folded` remap; the chunk's group can override it
--- (measured: a chunk group with a background does win over the remap).
---@return [string, string][]|string
function M.foldtext()
  local t = M.texts[vim.api.nvim_get_current_buf()]
  local entry = t and t[vim.v.foldstart]
  if not entry then
    return M.FILL:rep(3)
  end
  return { { entry[1] .. " ", entry[2] } }
end

M.FOLDTEXT = "v:lua.require'nvim-diff.render.fold'.foldtext()"

return M
