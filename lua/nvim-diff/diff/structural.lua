--- The structural (treesitter) diff: which syntax nodes changed, rather than which bytes.
---
--- It refines a line diff instead of replacing it. The hunks, rows, fillers and unchanged
--- runs stay exactly what `diff/line.lua` found — they are what `git diff` and GitHub show,
--- and what comments anchor to — and only two things change:
---
--- * `tokens`: the bright spans are the syntax nodes that changed, not the changed words.
--- * `formatting_only`: a hunk in which no token changed on either side is a pure
---   reformat, which folding collapses to one "no semantic change" separator.
---
--- The algorithm is the research step's, measured there: flatten each tree to its leaf
--- tokens (whitespace is not a node, so it vanishes for free), diff the two token streams
--- with `vim.text.diff` over a synthetic token-per-line document, then widen each changed
--- token to the largest enclosing node whose every token changed — so a wholly new
--- argument lights up whole, while a comma added to an argument list lights up alone.
---
--- It gives up, returning nil and a reason, when the answer would be dishonest or slow: no
--- parser for the language, a syntax error on either side (a half-typed buffer or conflict
--- markers turn the token stream to garbage), more lines than the size limit, or a NUL in
--- the text. The caller then keeps the line diff.
---
--- Pure: no buffers, no config. Injected languages are not descended into — a changed Lua
--- fence in markdown is one opaque token.

local M = {}

---@class NvimDiff.Diff.StructuralOpts
---@field algorithm? string Passed to `vim.text.diff` for the token diff. Default `"histogram"`.
--- Give up above this many lines on either side. Default 5000, where the two parses cross
--- ~100 ms.
---@field max_lines? integer
--- Compare comments word by word, ignoring whitespace and each line's leading comment
--- marker, so rewrapping a comment is a formatting change. Default true.
---@field normalize_comments? boolean

M.defaults = {
  algorithm = "histogram",
  max_lines = 5000,
  normalize_comments = true,
}

--- Whether a treesitter parser for `lang` is installed. `vim.treesitter.language.add` is not
--- a usable probe: it returns true for languages that do not exist.
---@param lang string
---@return boolean
function M.has_parser(lang)
  return (pcall(vim.treesitter.get_string_parser, "", lang))
end

--- One side's tokens, parallel arrays in source order.
---@class NvimDiff.Structural.Side
---@field text string The side's lines joined with `\n`.
---@field lines string[]
---@field line_starts integer[] 0-based byte offset of each line.
---@field start integer[] 0-based byte offset of each token.
---@field stop integer[] 0-based, exclusive.
---@field row integer[] 1-based line each token starts on.
---@field str string[] What the token diff compares.
---@field root TSNode
---@field parser vim.treesitter.LanguageTree Held so the tree outlives the flatten.
---@field word boolean[] The token is one word of a comment, not a whole leaf.
---@field changed boolean[]
---@field prefix integer[] `prefix[i]` = changed tokens among the first `i`.

---@param ty string A node type.
---@return boolean
local function is_comment(ty)
  return ty == "comment" or ty:find("comment$") ~= nil
end

--- A string literal is one token: a changed string lights up whole, quotes included,
--- rather than just its content between two unchanged quotes. `concatenated_string` (C,
--- Python) is several literals, which a reformat may spread over lines, so it is walked.
---@param ty string A node type.
---@return boolean
local function is_string(ty)
  return ty == "string" or ty == "char_literal" or ty:find("string_literal$") ~= nil
end

--- 1-based line holding byte offset `b`.
---@param starts integer[]
---@param b integer
---@return integer
local function line_of(starts, b)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= b then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

--- Parse one side and flatten it to tokens.
---@param lines string[]
---@param lang string
---@param opts NvimDiff.Diff.StructuralOpts
---@return NvimDiff.Structural.Side? side
---@return string? reason
local function flatten(lines, lang, opts)
  local text = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then
    return nil, ("no parser for %s"):format(lang)
  end
  local root = parser:parse()[1]:root()
  if root:has_error() then
    return nil, "syntax error"
  end

  local line_starts, at = {}, 0
  for i, l in ipairs(lines) do
    line_starts[i] = at
    at = at + #l + 1
  end
  if #line_starts == 0 then
    line_starts[1] = 0
  end

  local s = {
    text = text,
    lines = lines,
    line_starts = line_starts,
    start = {},
    stop = {},
    row = {},
    str = {},
    word = {},
    root = root,
    parser = parser,
  }
  local n = 0

  ---@param a integer
  ---@param b integer
  ---@param str string
  -- No node is kept per token: holding 83,000 node userdata measured 65 ms of GC. The few
  -- changed tokens find theirs again with `descendant_for_range`.
  ---@param row integer
  ---@param word? boolean
  local function push(a, b, str, row, word)
    n = n + 1
    s.start[n], s.stop[n], s.str[n], s.row[n], s.word[n] = a, b, str, row, word or false
  end

  --- A comment as words. A line's first word is dropped when it is all punctuation — the
  --- `--`, `//`, `#` or `*` a rewrap moves around — so rewrapping reads as formatting.
  ---@param a integer
  ---@param b integer
  local function push_words(a, b)
    local body = text:sub(a + 1, b)
    local line_start = true
    local pos = 1
    while true do
      local ws, we = body:find("%S+", pos)
      if not ws then
        break
      end
      if body:sub(pos, ws - 1):find("\n", 1, true) then
        line_start = true
      end
      local word = body:sub(ws, we)
      if not (line_start and word:find("^%p+$")) then
        local wa = a + ws - 1
        push(wa, a + we, word, line_of(line_starts, wa), true)
      end
      line_start = false
      pos = we + 1
    end
  end

  -- `iter_children` measured faster than indexing with `child(i)` (69 vs 94 ms for 83K
  -- leaves), and the parent is looked up only for the few tokens that changed.
  ---@param node TSNode
  local function walk(node)
    local ty = node:type()
    local comment = is_comment(ty)
    if not comment and not is_string(ty) and node:child_count() > 0 then
      for child in node:iter_children() do
        walk(child)
      end
      return
    end
    local srow, _, a, _, _, b = node:range(true)
    if b <= a then
      return -- a zero-width MISSING node, or an empty one
    end
    if comment and opts.normalize_comments then
      push_words(a, b)
    else
      push(a, b, text:sub(a + 1, b), srow + 1)
    end
  end
  walk(root)
  return s
end

--- A token as one line of the synthetic document: backslashes and newlines escaped, so a
--- multi-line string is one line and no two different tokens write the same line.
---@param str string
---@return string
local function doc_line(str)
  if str:find("[\\\n]") then
    return (str:gsub("\\", "\\\\"):gsub("\n", "\\n"))
  end
  return str
end

---@param s NvimDiff.Structural.Side
---@return string
local function document(s)
  if #s.str == 0 then
    return ""
  end
  local out = {}
  for i, str in ipairs(s.str) do
    out[i] = doc_line(str)
  end
  return table.concat(out, "\n") .. "\n"
end

--- The token diff's histogram budget, in tokens × hunks; `diff/line.lua` uses the same one.
local HISTOGRAM_BUDGET = 2e7

--- Mark each side's changed tokens.
---@param a NvimDiff.Structural.Side
---@param b NvimDiff.Structural.Side
---@param algorithm string
local function mark(a, b, algorithm)
  a.changed, b.changed = {}, {}
  local da, db = document(a), document(b)
  local total = #a.str + #b.str
  local hunks
  -- Histogram costs roughly tokens × hunks, as it does for lines (`diff/line.lua`): 83,000
  -- tokens a side with 700 scattered edits took 376 ms. Above the budget a myers pass,
  -- which is cheap, answers instead.
  if algorithm == "histogram" and total * total > HISTOGRAM_BUDGET then
    hunks = vim.text.diff(da, db, { result_type = "indices", algorithm = "myers" }) --[[@as integer[][] ]]
    if total * #hunks <= HISTOGRAM_BUDGET then
      hunks = nil
    end
  end
  hunks = hunks or vim.text.diff(da, db, { result_type = "indices", algorithm = algorithm }) --[[@as integer[][] ]]
  for _, h in ipairs(hunks) do
    for i = h[1], h[1] + h[2] - 1 do
      a.changed[i] = true
    end
    for i = h[3], h[3] + h[4] - 1 do
      b.changed[i] = true
    end
  end
  for _, s in ipairs({ a, b }) do
    local prefix, c = { [0] = 0 }, 0
    for i = 1, #s.str do
      if s.changed[i] then
        c = c + 1
      end
      prefix[i] = c
    end
    s.prefix = prefix
  end
end

--- First token index whose start is >= `b` (one past the end when none).
---@param starts integer[]
---@param b integer
---@return integer
local function first_token_at(starts, b)
  local lo, hi = 1, #starts + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if starts[mid] < b then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

--- The node token `i` came from: its leaf, or for a word the comment holding it.
---@param s NvimDiff.Structural.Side
---@param i integer
---@return TSNode?
local function token_node(s, i)
  local srow = s.row[i]
  local erow = line_of(s.line_starts, s.stop[i] - 1)
  local node =
    s.root:descendant_for_range(srow - 1, s.start[i] - s.line_starts[srow], erow - 1, s.stop[i] - s.line_starts[erow])
  if s.word[i] then
    while node and not is_comment(node:type()) do
      node = node:parent()
    end
  end
  return node
end

--- The changed byte ranges of one side: each changed token widened to the largest
--- enclosing node all of whose tokens changed, merged where they overlap.
---@param s NvimDiff.Structural.Side
---@return [integer, integer][] ranges Sorted, disjoint.
local function changed_ranges(s)
  local full = {} ---@type table<string, boolean>
  --- Whether every token inside `node` changed.
  ---@param node TSNode
  ---@return boolean
  local function all_changed(node)
    local id = node:id()
    local known = full[id]
    if known == nil then
      local _, _, a, _, _, b = node:range(true)
      local i = first_token_at(s.start, a)
      local j = first_token_at(s.start, b) - 1
      known = j >= i and s.prefix[j] - s.prefix[i - 1] == j - i + 1
      full[id] = known
    end
    return known
  end

  local ranges = {}
  for i = 1, #s.str do
    if s.changed[i] then
      local a, b = s.start[i], s.stop[i]
      local node = token_node(s, i) ---@type TSNode?
      if not s.word[i] then
        node = node and node:parent() -- the leaf itself is already `a, b`
      end
      while node and node:parent() and all_changed(node) do
        local _, _, na, _, _, nb = node:range(true)
        a, b = math.min(a, na), math.max(b, nb)
        node = node:parent()
      end
      ranges[#ranges + 1] = { a, b }
    end
  end
  table.sort(ranges, function(x, y)
    return x[1] < y[1]
  end)
  local merged = {}
  for _, r in ipairs(ranges) do
    local last = merged[#merged]
    if last and r[1] <= last[2] then
      last[2] = math.max(last[2], r[2])
    else
      merged[#merged + 1] = { r[1], r[2] }
    end
  end
  return merged
end

--- Byte ranges cut into per-line spans. A range's continuation lines start at their
--- first non-blank byte, so indentation never lights up.
---@param s NvimDiff.Structural.Side
---@param ranges [integer, integer][]
---@return table<integer, NvimDiff.Diff.Span[]>
local function line_spans(s, ranges)
  local out = {}
  for _, r in ipairs(ranges) do
    local first, last = line_of(s.line_starts, r[1]), line_of(s.line_starts, math.max(r[1], r[2] - 1))
    for lnum = first, last do
      local base = s.line_starts[lnum]
      local line = s.lines[lnum]
      local a = lnum == first and r[1] - base or ((line:find("%S") or #line + 1) - 1)
      local b = lnum == last and math.min(r[2] - base, #line) or #line
      if b > a then
        local list = out[lnum] or {}
        list[#list + 1] = { a, b }
        out[lnum] = list
      end
    end
  end
  return out
end

--- Per line: how many tokens start there, and how many of those changed.
---@param s NvimDiff.Structural.Side
---@return table<integer, integer> total
---@return table<integer, integer> changed
local function line_counts(s)
  local total, changed = {}, {}
  for i, row in ipairs(s.row) do
    total[row] = (total[row] or 0) + 1
    if s.changed[i] then
      changed[row] = (changed[row] or 0) + 1
    end
  end
  return total, changed
end

--- Whether a hunk is a pure reformat: both sides have lines, and no changed token touches
--- them on either side. The token diff is whole-file, so this holds even when the line
--- diff cut the hunk where the moved tokens do not line up with it (a call split so that
--- its closing lines match an unchanged `end` further down), and a changed multi-line
--- string that starts above the hunk still counts — its span reaches into the hunk.
---@param h NvimDiff.Hunk
---@param spans { old: table<integer, NvimDiff.Diff.Span[]>, new: table<integer, NvimDiff.Diff.Span[]> }
---@return boolean
local function is_reformat(h, spans)
  if h.old_count == 0 or h.new_count == 0 then
    return false -- blank lines added or removed: shown, not collapsed into "0 lines"
  end
  for side, first in pairs({ old = h.old_start, new = h.new_start }) do
    for lnum = first, first + h[side .. "_count"] - 1 do
      if spans[side][lnum] then
        return false
      end
    end
  end
  return true
end

---@param lines string[]
---@return boolean
local function has_nul(lines)
  for _, l in ipairs(lines) do
    if l:find("\n", 1, true) then
      return true
    end
  end
  return false
end

--- Refine a line diff structurally.
---
--- Returns a new model with the same hunks, rows and runs as `line_diff` (the hunk tables
--- are copied, the rows shared), `token_source = "structural"`, structural `tokens`, and
--- `formatting_only` set on pure reformats. `line_diff` is not modified.
---
--- `tokens` differs from the line engine's in one way: an `added` or `deleted` line may
--- carry spans too, when only some of its tokens are new (a line that gained an argument
--- when a call was split across lines). A line whose tokens are all new, or none of them,
--- stays without — uniform colour.
---@param line_diff NvimDiff.Diff
---@param old_lines string[]
---@param new_lines string[]
---@param lang string Treesitter language of both sides.
---@param opts? NvimDiff.Diff.StructuralOpts
---@return NvimDiff.Diff? diff
---@return string? reason Why not, when `diff` is nil.
function M.diff(line_diff, old_lines, new_lines, lang, opts)
  opts = vim.tbl_extend("force", M.defaults, opts or {})
  if #old_lines > opts.max_lines or #new_lines > opts.max_lines then
    return nil, ("over %d lines"):format(opts.max_lines)
  end
  if has_nul(old_lines) or has_nul(new_lines) then
    return nil, "NUL bytes"
  end
  local a, why = flatten(old_lines, lang, opts)
  if not a then
    return nil, why
  end
  local b
  b, why = flatten(new_lines, lang, opts)
  if not b then
    return nil, why
  end
  mark(a, b, opts.algorithm)

  local sides = { old = a, new = b }
  local tokens = { old = {}, new = {} }
  local hunks = {}
  local spans, totals, changes = {}, {}, {}
  for side, s in pairs(sides) do
    spans[side] = line_spans(s, changed_ranges(s))
    totals[side], changes[side] = line_counts(s)
  end

  for i, h in ipairs(line_diff.hunks) do
    local copy = {}
    for k, v in pairs(h) do
      copy[k] = v
    end
    copy.formatting_only = is_reformat(h, spans)
    hunks[i] = copy
    for _, r in ipairs(h.rows) do
      for side in pairs(sides) do
        local lnum = r[side]
        if lnum then
          if r.kind == "changed" then
            tokens[side][lnum] = spans[side][lnum] or {}
          else
            local c = changes[side][lnum] or 0
            if c > 0 and c < (totals[side][lnum] or 0) then
              tokens[side][lnum] = spans[side][lnum]
            end
          end
        end
      end
    end
  end

  local d = {}
  for k, v in pairs(line_diff) do
    d[k] = v
  end
  d.hunks = hunks
  d.tokens = tokens
  d.token_source = "structural"
  return setmetatable(d, getmetatable(line_diff))
end

return M
