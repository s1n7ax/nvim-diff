--- Intra-line changed-token ranges.
---
--- A changed line is painted in its own side's colour with the changed tokens brighter
--- inside, so a wholly added line — uniform colour, no bright token — reads differently
--- from an edited one. This module decides which byte ranges "the changed tokens" are.
---
--- The mechanism is the one the structural step will reuse: split each side into tokens,
--- write the tokens into a synthetic token-per-line document and hand that to
--- `vim.text.diff`, which is xdiff in C. A pure-Lua LCS is fine on a small edit and
--- catastrophic on a large one; this is uniformly fast.
---
--- Nothing here knows about extmarks. It returns byte ranges; the renderer turns them into
--- marks.

local M = {}

--- A byte range inside one line: `{ start_col, end_col }`, **0-based** and **end-exclusive**
--- — exactly the `col` / `end_col` pair `nvim_buf_set_extmark` wants. Both ends always fall
--- on a character boundary.
---@alias NvimDiff.Diff.Span [integer, integer]

--- Word bytes: ASCII identifier characters plus every byte of a multi-byte character, so a
--- UTF-8 sequence is always inside one token and a span can never start mid-character.
local WORD = "^[%w_\128-\255]+"
--- Runs of spaces and tabs are one token. Not `%s`: a buffer line holding a NUL comes back
--- from `nvim_buf_get_lines` with a `\n` in its place, and a `\n` must stay a token of its
--- own so it can be escaped before it reaches the line-oriented token document.
local SPACE = "^[ \t]+"

--- Above this many bytes on either side, tokenizing is the expensive part (a minified
--- bundle is one line of a megabyte), so the differing middle is reported as a single span
--- instead. Every real source line is far below it.
local DEFAULT_MAX_BYTES = 4096

--- Split a line into word runs, blank runs and single other characters.
---@param line string
---@return string[] texts
---@return integer[] starts 0-based byte offset of each token
---@return integer[] ends 0-based, exclusive
local function tokenize(line)
  local texts, starts, ends = {}, {}, {}
  local pos, len, n = 1, #line, 0
  while pos <= len do
    local s, e = line:find(WORD, pos)
    if not s then
      s, e = line:find(SPACE, pos)
    end
    if not s then
      s, e = pos, pos
    end
    n = n + 1
    texts[n] = line:sub(s, e)
    starts[n] = s - 1
    ends[n] = e
    pos = e + 1
  end
  return texts, starts, ends
end

--- A token as one line of the synthetic document. The only token that can hold a `\n` is
--- the single character `\n` itself (see `SPACE`), and the only raw token holding a
--- backslash is the single character `\`, so writing `\n` as the two bytes `\n` cannot
--- collide with any other token.
---@param text string
---@return string
local function doc_token(text)
  if text == "\n" then
    return "\\n"
  end
  return text
end

---@param byte integer?
---@return boolean
local function is_continuation(byte)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

--- Longest common prefix of `a` and `b` in bytes, pulled back onto a character boundary.
---@param a string
---@param b string
---@return integer
local function common_prefix(a, b)
  local limit = math.min(#a, #b)
  local n = 0
  while n < limit and a:byte(n + 1) == b:byte(n + 1) do
    n = n + 1
  end
  while n > 0 and is_continuation(a:byte(n + 1)) do
    n = n - 1
  end
  return n
end

--- Longest common suffix of `a` and `b` in bytes, not overlapping the `prefix` already
--- taken, pushed forward onto a character boundary.
---@param a string
---@param b string
---@param prefix integer
---@return integer
local function common_suffix(a, b, prefix)
  local limit = math.min(#a, #b) - prefix
  local n = 0
  while n < limit and a:byte(#a - n) == b:byte(#b - n) do
    n = n + 1
  end
  while n > 0 and is_continuation(a:byte(#a - n + 1)) do
    n = n - 1
  end
  return n
end

--- The whole differing middle as one span per side. Used for lines too long to tokenize.
---@param a string
---@param b string
---@return NvimDiff.Diff.Span[] a_spans
---@return NvimDiff.Diff.Span[] b_spans
local function rough_spans(a, b)
  local prefix = common_prefix(a, b)
  local suffix = common_suffix(a, b, prefix)
  local a_spans, b_spans = {}, {}
  if #a - suffix > prefix then
    a_spans[1] = { prefix, #a - suffix }
  end
  if #b - suffix > prefix then
    b_spans[1] = { prefix, #b - suffix }
  end
  return a_spans, b_spans
end

---@class NvimDiff.Diff.InlineOpts
---@field algorithm? string Passed to `vim.text.diff`; defaults to `"histogram"`.
---@field max_bytes? integer Above this line length the differing middle becomes one span.

--- The changed byte ranges of one pair of lines.
---
--- Returns two lists, one per side. Either may be empty while the other is not: text purely
--- inserted into a line has nothing to light up on the old side, and that is honest — the
--- old line really is unchanged, it is just shorter.
---@param a string The line as it is on side a.
---@param b string The line as it is on side b.
---@param opts? NvimDiff.Diff.InlineOpts
---@return NvimDiff.Diff.Span[] a_spans Ascending, non-overlapping.
---@return NvimDiff.Diff.Span[] b_spans
function M.spans(a, b, opts)
  if a == b then
    return {}, {}
  end
  opts = opts or {}
  if #a > (opts.max_bytes or DEFAULT_MAX_BYTES) or #b > (opts.max_bytes or DEFAULT_MAX_BYTES) then
    return rough_spans(a, b)
  end

  local a_text, a_start, a_end = tokenize(a)
  local b_text, b_start, b_end = tokenize(b)

  -- Trim the tokens the two lines share at each end; only the middle is diffed.
  local pre = 0
  while pre < #a_text and pre < #b_text and a_text[pre + 1] == b_text[pre + 1] do
    pre = pre + 1
  end
  local post = 0
  while post < #a_text - pre and post < #b_text - pre and a_text[#a_text - post] == b_text[#b_text - post] do
    post = post + 1
  end

  local a_n = #a_text - pre - post
  local b_n = #b_text - pre - post

  -- The three shapes that need no diff at all, which is most real edits.
  if a_n == 0 and b_n == 0 then
    return {}, {}
  end
  local a_whole = a_n > 0 and { { a_start[pre + 1], a_end[pre + a_n] } } or {}
  local b_whole = b_n > 0 and { { b_start[pre + 1], b_end[pre + b_n] } } or {}
  if a_n == 0 or b_n == 0 or (a_n == 1 and b_n == 1) then
    return a_whole, b_whole
  end

  local a_doc, b_doc = {}, {}
  for i = 1, a_n do
    a_doc[i] = doc_token(a_text[pre + i])
  end
  for i = 1, b_n do
    b_doc[i] = doc_token(b_text[pre + i])
  end
  local hunks = vim.text.diff(table.concat(a_doc, "\n") .. "\n", table.concat(b_doc, "\n") .. "\n", {
    result_type = "indices",
    algorithm = opts.algorithm or "histogram",
  })
  if not hunks or #hunks == 0 then
    return a_whole, b_whole
  end

  local a_spans, b_spans = {}, {}
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    if count_a > 0 then
      a_spans[#a_spans + 1] = { a_start[pre + start_a], a_end[pre + start_a + count_a - 1] }
    end
    if count_b > 0 then
      b_spans[#b_spans + 1] = { b_start[pre + start_b], b_end[pre + start_b + count_b - 1] }
    end
  end
  return a_spans, b_spans
end

--- Exposed for the structural step, which tokenizes syntax leaves rather than words but
--- wants the same synthetic-document trick, and for tests.
---@param line string
---@return string[] texts
---@return integer[] starts
---@return integer[] ends
function M.tokenize(line)
  return tokenize(line)
end

return M
