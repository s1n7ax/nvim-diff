--- Comment threads as the diff shows them: where each one hangs, and the virtual lines it
--- is drawn with. Pure: no windows, no buffers, no GitHub.
---
--- A thread hangs under its anchor line — the last line of its range, in the file its side
--- names (`"old"` = GitHub `LEFT`, the base; `"new"` = `RIGHT`, the head). With the PR
--- worktree checked out at the head, a `RIGHT` line is a line of the new pane with no
--- position arithmetic at all.
---
--- Some threads have no line to hang from, and go to the side list instead:
---
--- * `outdated` — the code it was on changed since; GitHub itself returns no `line`.
--- * `file` — a file-level comment, on no line at all.
--- * `off_file` — a line past the end of the file shown, i.e. the diff on screen is not of
---   the revisions the thread was made against.
---
--- Collapsed, a thread is one line: `▌ ▸ alice  why 9090? …  · 2 replies · unresolved`.
--- Expanded, it is a meta line and then every comment, author and date over its body,
--- wrapped to the pane. A resolved thread is drawn entirely in `NvimDiffThreadResolved`
--- with a `✓`.

local M = {}

M.BAR = "▌ "
M.COLLAPSED = "▸ "
M.EXPANDED = "▾ "
M.RESOLVED = "✓"
--- Columns a comment body is indented by, under its author line.
M.INDENT = 2
--- Cells of the first comment a collapsed thread keeps however narrow the pane.
M.MIN_EXCERPT = 16

---@alias NvimDiff.ThreadPlace "line"|"outdated"|"file"|"off_file"

--- Where a thread goes: under a line of the diff, or in the side list (and why).
---@param thread NvimDiff.GitHub.Thread
---@param diff NvimDiff.Diff
---@return integer? row Display row the thread hangs after, when it has one.
---@return NvimDiff.ThreadPlace place
function M.anchor(thread, diff)
  if thread.subject == "file" then
    return nil, "file"
  end
  if thread.outdated or not thread.line then
    return nil, "outdated"
  end
  local side = thread.side or "new"
  if thread.line < 1 or thread.line > diff[side .. "_count"] then
    return nil, "off_file"
  end
  return diff:row_of(side, thread.line), "line"
end

--- `L12` or `L12–14`, for the thread's line range; the original range for an outdated one.
---@param thread NvimDiff.GitHub.Thread
---@return string?
function M.range_label(thread)
  local last, first = thread.line, thread.start_line
  if not last then
    last, first = thread.original_line, thread.original_start_line
  end
  if not last then
    return nil
  end
  if first and first ~= last then
    return ("L%d–%d"):format(first, last)
  end
  return ("L%d"):format(last)
end

---@param n integer
---@return string
local function replies(n)
  return n == 1 and "1 reply" or ("%d replies"):format(n)
end

--- `resolved ✓` / `resolved ✓ by carol` / `unresolved`.
---@param thread NvimDiff.GitHub.Thread
---@return string
function M.state_label(thread)
  if thread.resolved then
    return M.RESOLVED .. " resolved" .. (thread.resolved_by and (" by " .. thread.resolved_by) or "")
  end
  return "unresolved"
end

--- Markdown source as display lines: tabs expanded, control characters dropped, trailing
--- blank lines gone. Never empty.
---@param body string
---@return string[]
function M.body_lines(body)
  local out = {}
  for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
    out[#out + 1] = l:gsub("\t", "    "):gsub("%c", "")
  end
  while #out > 0 and vim.trim(out[#out]) == "" do
    out[#out] = nil
  end
  while #out > 0 and vim.trim(out[1]) == "" do
    table.remove(out, 1)
  end
  if #out == 0 then
    out[1] = "(no text)"
  end
  return out
end

--- Cut `text` to `width` display cells, ending in `…` when it was longer.
---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.split(text, "\\zs")
  local out, w = {}, 0
  for _, ch in ipairs(chars) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return (table.concat(out):gsub("%s+$", "")) .. "…"
end

--- Wrap one line at word boundaries to `width` display cells; a word longer than the width
--- is split. Leading indentation is kept on the first piece only.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(1, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return { text }
  end
  local out = {}
  local cur, cw = "", 0
  local lead = text:match("^%s*")
  local first = true
  for word in text:gmatch("%S+") do
    if first then
      word = lead .. word
      first = false
    end
    local w = vim.fn.strdisplaywidth(word)
    while w > width do
      if cur ~= "" then
        out[#out + 1] = cur
        cur, cw = "", 0
      end
      local head = M.truncate(word, width + 1):gsub("…$", "")
      if head == "" then
        -- One character wider than the width: it goes on a line of its own regardless.
        head = vim.fn.strcharpart(word, 0, 1)
      end
      out[#out + 1] = head
      word = word:sub(#head + 1)
      w = vim.fn.strdisplaywidth(word)
    end
    if cur == "" then
      cur, cw = word, w
    elseif cw + 1 + w <= width then
      cur, cw = cur .. " " .. word, cw + 1 + w
    else
      out[#out + 1] = cur
      cur, cw = word, w
    end
  end
  if cur ~= "" then
    out[#out + 1] = cur
  end
  return out
end

---@param thread NvimDiff.GitHub.Thread
---@param group string
---@return string
local function hl(thread, group)
  return thread.resolved and "NvimDiffThreadResolved" or group
end

---@class NvimDiff.ThreadLineOpts
--- Display cells to fit into: the collapsed line is truncated to it, bodies are wrapped.
---@field width? integer
---@field hint? string Shown dim at the end of the collapsed line, e.g. the expand key.
---@field label? string Leads the expanded meta line, e.g. `outdated` in the side list.

--- The one-line summary: author, the first line of the first comment, the reply count and
--- the resolved state.
---@param thread NvimDiff.GitHub.Thread
---@param opts? NvimDiff.ThreadLineOpts
---@return NvimDiff.VirtLine
function M.collapsed_line(thread, opts)
  opts = opts or {}
  local width = opts.width or 80
  local first = thread.comments[1]
  local author = first and first.author or "?"
  local meta = ("  · %s · %s"):format(replies(math.max(0, #thread.comments - 1)), M.state_label(thread))
  if opts.hint then
    meta = meta .. "  " .. opts.hint
  end
  local head = M.BAR .. M.COLLAPSED .. author .. "  "
  local room = width - vim.fn.strdisplaywidth(head .. meta)
  local text = vim.trim(first and M.body_lines(first.body)[1] or "")
  -- The excerpt keeps at least `MIN_EXCERPT` cells in a narrow pane; the meta gives way.
  text = M.truncate(text, math.max(room, math.min(M.MIN_EXCERPT, vim.fn.strdisplaywidth(text))))
  local meta_room = width - vim.fn.strdisplaywidth(head .. text)
  if vim.fn.strdisplaywidth(meta) > meta_room then
    meta = meta_room > 4 and M.truncate(meta, meta_room) or ""
  end
  return {
    { M.BAR, hl(thread, "NvimDiffThreadBar") },
    { M.COLLAPSED, hl(thread, "NvimDiffThreadMeta") },
    { author, hl(thread, "NvimDiffThreadAuthor") },
    { "  ", "" },
    { text, hl(thread, "NvimDiffThreadBody") },
    { meta, hl(thread, "NvimDiffThreadMeta") },
  }
end

--- The date part of an ISO 8601 timestamp.
---@param iso string
---@return string
local function date(iso)
  return iso:match("^(%d+%-%d+%-%d+)") or iso
end

--- The whole thread: a meta line (range, comment count, state), then each comment as an
--- author line over its body, the body wrapped to `opts.width`.
---@param thread NvimDiff.GitHub.Thread
---@param opts? NvimDiff.ThreadLineOpts
---@return NvimDiff.VirtLine[]
function M.expanded_lines(thread, opts)
  opts = opts or {}
  local width = opts.width or 80
  local bar = { M.BAR, hl(thread, "NvimDiffThreadBar") }
  local n = #thread.comments
  local parts = { opts.label }
  local range = M.range_label(thread)
  if range then
    parts[#parts + 1] = range
  end
  parts[#parts + 1] = n == 1 and "1 comment" or ("%d comments"):format(n)
  parts[#parts + 1] = M.state_label(thread)
  local lines = {
    {
      bar,
      { M.EXPANDED, hl(thread, "NvimDiffThreadMeta") },
      { table.concat(parts, " · "), hl(thread, "NvimDiffThreadMeta") },
    },
  }
  local body_width = width - vim.fn.strdisplaywidth(M.BAR) - M.INDENT
  local indent = (" "):rep(M.INDENT)
  for _, c in ipairs(thread.comments) do
    lines[#lines + 1] = {
      bar,
      { c.author, hl(thread, "NvimDiffThreadAuthor") },
      { "  " .. date(c.created_at), hl(thread, "NvimDiffThreadMeta") },
    }
    for _, l in ipairs(M.body_lines(c.body)) do
      for _, piece in ipairs(M.wrap(l, body_width)) do
        lines[#lines + 1] = { bar, { indent .. piece, hl(thread, "NvimDiffThreadBody") } }
      end
    end
  end
  return lines
end

--- Plain text of a virtual line, for tests and the side list.
---@param vl NvimDiff.VirtLine
---@return string
function M.text(vl)
  local out = {}
  for _, chunk in ipairs(vl) do
    out[#out + 1] = chunk[1]
  end
  return table.concat(out)
end

return M
