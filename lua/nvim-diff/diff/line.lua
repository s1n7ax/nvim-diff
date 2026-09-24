--- The line diff engine: two arrays of lines in, the hunk model (`diff/hunk.lua`) out.
---
--- Three passes, all pure:
---
--- 1. `vim.text.diff` (xdiff, in C) finds the hunks over the whole file. These are the
---    hunks `git diff` reports, which is what makes `commentable_ranges` match GitHub.
--- 2. Each hunk becomes aligned display rows: paired lines are `changed`, the rest
---    `deleted` or `added`. Small hunks are re-diffed alone with `linematch` so the paired
---    lines are the similar ones rather than the ones at the same offset.
--- 3. Each `changed` pair gets its intra-line token ranges from `diff/inline.lua`.
---
--- Input is what `nvim_buf_get_lines` or a split blob gives: one string per line, no line
--- terminators. No git, no buffers.

local hunk = require("nvim-diff.diff.hunk")
local inline = require("nvim-diff.diff.inline")

local M = {}

---@class NvimDiff.Diff.LineOpts
---@field algorithm? "myers"|"minimal"|"patience"|"histogram" Defaults to `"histogram"`.
--- Hunks of up to this many lines (old + new) are line-matched, pairing similar lines rather
--- than pairing by position. 0 turns it off. Defaults to 40, Neovim's `diffopt` default.
---@field linematch? integer
---@field indent_heuristic? boolean Shift hunk boundaries to indentation, as git does. Default true.
---@field inline? boolean Compute intra-line token ranges for changed lines. Default true.
---@field inline_max_bytes? integer See `NvimDiff.Diff.InlineOpts.max_bytes`.

M.defaults = {
  algorithm = "histogram",
  linematch = 40,
  indent_heuristic = true,
  inline = true,
}

--- Join lines into the text `vim.text.diff` wants.
---
--- Every line gets a terminator — including the last, so "no newline at end of file" never
--- shows up as a change to the last line — and an empty array is the empty string, not one
--- empty line. A line holding a `\n` (a NUL in the buffer) would split in two, so when any
--- line on either side holds one, every line on both sides is escaped injectively.
---@param old_lines string[]
---@param new_lines string[]
---@return string old_text
---@return string new_text
local function encode(old_lines, new_lines)
  local escape = false
  for _, lines in ipairs({ old_lines, new_lines }) do
    for _, l in ipairs(lines) do
      if l:find("\n", 1, true) then
        escape = true
        break
      end
    end
  end

  ---@param lines string[]
  ---@return string
  local function join(lines)
    if #lines == 0 then
      return ""
    end
    if escape then
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = l:gsub("\\", "\\\\"):gsub("\n", "\\n")
      end
      lines = out
    end
    return table.concat(lines, "\n") .. "\n"
  end

  return join(old_lines), join(new_lines)
end

--- xdiff's histogram costs roughly (total lines × hunks): measured on this toolchain, 50,000
--- lines with a change every 10th line took 2,470 ms under histogram and 12 ms under myers,
--- while 50,000 lines with 100 hunks took 40 ms. Above this many line-hunks the diff falls
--- back to myers, which is about 100 ms of histogram. Real edits are far below it; it is a
--- generated or mass-rewritten file that crosses it, and there the two algorithms' output
--- differs only in how ambiguous hunks slide.
local HISTOGRAM_BUDGET = 2e7

--- Whether histogram would be too slow here. A myers pass is cheap enough to ask.
---@param old_text string
---@param new_text string
---@param total_lines integer
---@param opts NvimDiff.Diff.LineOpts
---@return boolean
local function too_scattered_for_histogram(old_text, new_text, total_lines, opts)
  -- No number of hunks can blow the budget on a small file; skip the probe.
  if total_lines * total_lines <= HISTOGRAM_BUDGET then
    return false
  end
  local probe = vim.text.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = "myers",
    indent_heuristic = opts.indent_heuristic,
  }) --[[@as integer[][] ]]
  return total_lines * #probe > HISTOGRAM_BUDGET
end

--- Where a raw index hunk sits on one side, as a half-open line range `[first, stop)`.
---@param start integer
---@param count integer
---@return integer first
---@return integer stop
local function span(start, count)
  if count == 0 then
    return start + 1, start + 1
  end
  return start, start + count
end

--- Rows for one run of lines: position-paired lines are `changed`, then the surplus old
--- lines are `deleted`, then the surplus new lines `added`.
---@param rows NvimDiff.Row[]
---@param o1 integer First old line.
---@param oc integer
---@param n1 integer First new line.
---@param nc integer
local function push_rows(rows, o1, oc, n1, nc)
  local paired = math.min(oc, nc)
  for i = 0, paired - 1 do
    rows[#rows + 1] = { kind = "changed", old = o1 + i, new = n1 + i }
  end
  for i = paired, oc - 1 do
    rows[#rows + 1] = { kind = "deleted", old = o1 + i }
  end
  for i = paired, nc - 1 do
    rows[#rows + 1] = { kind = "added", new = n1 + i }
  end
end

--- Line-match one hunk: diff just its lines with `linematch`, which cuts it into sub-hunks
--- that pair the most similar old and new lines. Returns nil when the sub-hunks do not tile
--- the hunk exactly — re-diffing the slice alone can match a line the whole-file diff left
--- inside the hunk — so the hunk keeps the boundaries git reports and falls back to
--- positional pairing.
---@param old_lines string[]
---@param new_lines string[]
---@param o1 integer
---@param oc integer
---@param n1 integer
---@param nc integer
---@param algorithm string
---@param linematch integer
---@return NvimDiff.Row[]?
local function matched_rows(old_lines, new_lines, o1, oc, n1, nc, algorithm, linematch)
  local old_text, new_text = encode({ unpack(old_lines, o1, o1 + oc - 1) }, { unpack(new_lines, n1, n1 + nc - 1) })
  local subs = vim.text.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = algorithm,
    linematch = linematch,
  }) --[[@as integer[][] ]]
  local rows = {}
  local next_old, next_new = 1, 1
  for _, s in ipairs(subs) do
    local o_first, o_stop = span(s[1], s[2])
    local n_first, n_stop = span(s[3], s[4])
    if o_first ~= next_old or n_first ~= next_new then
      return nil
    end
    push_rows(rows, o1 + o_first - 1, s[2], n1 + n_first - 1, s[4])
    next_old, next_new = o_stop, n_stop
  end
  if next_old ~= oc + 1 or next_new ~= nc + 1 then
    return nil
  end
  return rows
end

--- Display rows for one whole-file hunk `{ start_a, count_a, start_b, count_b }`.
---@param old_lines string[]
---@param new_lines string[]
---@param r integer[]
---@param algorithm string
---@param linematch integer
---@return NvimDiff.Row[]
local function hunk_rows(old_lines, new_lines, r, algorithm, linematch)
  local o1, n1 = span(r[1], r[2]), span(r[3], r[4])
  local oc, nc = r[2], r[4]
  -- A 1:1 hunk, or one with nothing on a side, has only one possible pairing.
  if oc > 0 and nc > 0 and oc + nc > 2 and oc + nc <= linematch then
    local rows = matched_rows(old_lines, new_lines, o1, oc, n1, nc, algorithm, linematch)
    if rows then
      return rows
    end
  end
  local rows = {}
  push_rows(rows, o1, oc, n1, nc)
  return rows
end

--- Diff two line arrays.
---@param old_lines string[]
---@param new_lines string[]
---@param opts? NvimDiff.Diff.LineOpts
---@return NvimDiff.Diff
function M.diff(old_lines, new_lines, opts)
  opts = vim.tbl_extend("force", M.defaults, opts or {})
  local old_text, new_text = encode(old_lines, new_lines)

  local algorithm = opts.algorithm
  if algorithm == "histogram" and too_scattered_for_histogram(old_text, new_text, #old_lines + #new_lines, opts) then
    algorithm = "myers"
  end
  -- No `linematch` here: inside `vim.text.diff` it costs time per hunk proportional to the
  -- whole file (measured: 50,000 lines, 5,000 hunks, 937 ms with it and 11 ms without).
  -- `hunk_rows` runs it per hunk on just that hunk's lines instead.
  local raw = vim.text.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = algorithm,
    indent_heuristic = opts.indent_heuristic,
  }) --[[@as integer[][] ]]

  ---@type NvimDiff.Hunk[]
  local hunks = {}
  for i, r in ipairs(raw) do
    hunks[i] = {
      old_start = r[1],
      old_count = r[2],
      new_start = r[3],
      new_count = r[4],
      rows = hunk_rows(old_lines, new_lines, r, algorithm, opts.linematch),
    }
  end

  local d = hunk.new(#old_lines, #new_lines, hunks)
  d.algorithm = algorithm

  if opts.inline then
    local inline_opts = { algorithm = opts.algorithm, max_bytes = opts.inline_max_bytes }
    for _, h in ipairs(hunks) do
      for _, row in ipairs(h.rows) do
        if row.kind == "changed" then
          d.tokens.old[row.old], d.tokens.new[row.new] =
            inline.spans(old_lines[row.old], new_lines[row.new], inline_opts)
        end
      end
    end
  end

  return d
end

return M
