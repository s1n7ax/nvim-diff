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
--- Collapsed, a thread is one line, a folded bubble ending in a coloured state badge:
--- `╶▸ alice  why 9090? …  · 2 replies ───── UNRESOLVED `. Expanded, it is a bordered
--- bubble: the meta and the badge in its top border, then every comment, author and date
--- over its body, wrapped to the pane. A resolved thread is drawn in
--- `NvimDiffThreadResolved` but for its green badge, and a collapsed one also carries a `✓`
--- before the author (`╶▸ ✓ alice  why 9090? …`) so no pane is too narrow to show it.

local M = {}

M.COLLAPSED_CAP = "╶"
--- Leads a collapsed thread hung under a line: the bubble's tail, pointing up at it.
M.COLLAPSED_TAIL = "╰"
--- In the top border of an expanded thread hung under a line: the bubble's tail.
M.TAIL = "┴"
M.COLLAPSED = "▸ "
M.EXPANDED = "▾ "
M.RESOLVED = "✓"
M.RULE = "─"
--- Parts one comment of an expanded thread from the next.
M.SEPARATOR = "┄"
--- Columns a comment body is indented by, under its author line.
M.INDENT = 2
--- Cells a bubble grows to at most, however wide the pane: a long line of prose is hard
--- to read.
M.MAX_WIDTH = 100
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

--- The border group: lit while the cursor is on the thread's lines, else as `hl` says.
---@param thread NvimDiff.GitHub.Thread
---@param opts NvimDiff.ThreadLineOpts
---@return string
local function border_hl(thread, opts)
  return opts.active and "NvimDiffThreadBorderActive" or hl(thread, "NvimDiffThreadBorder")
end

--- The state badge, a coloured chip: ` ✓ RESOLVED ` or ` UNRESOLVED `. Never dimmed, so a
--- resolved thread still reads as resolved at a glance.
---@param thread NvimDiff.GitHub.Thread
---@return NvimDiff.VirtChunk
function M.badge(thread)
  if thread.resolved then
    return { " " .. M.RESOLVED .. " RESOLVED ", "NvimDiffThreadBadgeResolved" }
  end
  return { " UNRESOLVED ", "NvimDiffThreadBadgeUnresolved" }
end

---@param s string
---@return integer
local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

---@class NvimDiff.ThreadLineOpts
--- Display cells to fit into: the collapsed line is truncated to it, bodies are wrapped.
---@field width? integer
---@field hint? string Shown dim at the end of the collapsed line, e.g. the expand key.
---@field label? string Leads the expanded meta line, e.g. `outdated` in the side list.
--- Draw the bubble's tail, pointing up at the line the thread hangs under.
---@field tail? boolean
--- The cursor is on the thread's lines: the border is drawn in `NvimDiffThreadBorderActive`.
---@field active? boolean

--- Cells a bubble takes in a pane `width` wide: all of it, up to `MAX_WIDTH`.
---@param width integer
---@return integer
function M.bubble_width(width)
  return math.min(width, M.MAX_WIDTH)
end

--- The one-line summary: author, the first line of the first comment, the reply count and
--- the state badge, as a folded bubble: `╶▸ alice  why 9090?  · 1 reply ──── UNRESOLVED `;
--- `╰▸ …` with `tail`, pointing up at the line it hangs under.
---@param thread NvimDiff.GitHub.Thread
---@param opts? NvimDiff.ThreadLineOpts
---@return NvimDiff.VirtLine
function M.collapsed_line(thread, opts)
  opts = opts or {}
  local width = M.bubble_width(opts.width or 80)
  local first = thread.comments[1]
  local author = first and first.author or "?"
  local meta = ("  · %s"):format(replies(math.max(0, #thread.comments - 1)))
  if opts.hint then
    meta = meta .. "  " .. opts.hint
  end
  local badge = M.badge(thread)
  -- A resolved thread leads with its ✓ as well, so a narrow pane that cuts the badge off
  -- still shows it.
  local mark = thread.resolved and (M.RESOLVED .. " ") or ""
  local cap = (opts.tail and M.COLLAPSED_TAIL or M.COLLAPSED_CAP) .. M.COLLAPSED .. mark
  local head = cap .. author .. "  "
  local text = vim.trim(first and M.body_lines(first.body)[1] or "")
  local want = math.min(M.MIN_EXCERPT, dw(text))
  -- After the excerpt: the meta, a rule of at least one cell, and the badge. In a narrow
  -- pane the meta goes first, then the badge; the excerpt keeps at least `MIN_EXCERPT`.
  local full = dw(meta) + 3 + dw(badge[1])
  local tail = 1 + dw(badge[1])
  local room = width - dw(head)
  local kind = room - full >= want and "full" or room - tail >= want and "badge" or "none"
  text = M.truncate(text, math.max(want, room - (kind == "full" and full or kind == "badge" and tail or 0)))
  room = room - dw(text)
  local line = {
    { cap, border_hl(thread, opts) },
    { author, hl(thread, "NvimDiffThreadAuthor") },
    { "  ", "" },
    { text, hl(thread, "NvimDiffThreadBody") },
  }
  if kind == "full" then
    vim.list_extend(line, {
      { meta, hl(thread, "NvimDiffThreadMeta") },
      { " " .. M.RULE:rep(room - full + 1) .. " ", border_hl(thread, opts) },
      badge,
    })
  elseif kind == "badge" then
    line[#line + 1] = { (" "):rep(room - dw(badge[1])), "" }
    line[#line + 1] = badge
  end
  return line
end

--- The date part of an ISO 8601 timestamp.
---@param iso string
---@return string
local function date(iso)
  return iso:match("^(%d+%-%d+%-%d+)") or iso
end

--- The whole thread as a bubble: a top border carrying the meta (range, comment count) and
--- the state badge, then each comment as an author line over its body, wrapped to fit,
--- comments parted by a dotted rule, and a bottom border. With `tail`, the top border
--- points up at the line the thread hangs under: `╭┴▾ L12 …`.
---
---     ╭─▾ L12 · 2 comments ─────── UNRESOLVED ─╮
---     │ alice  2026-09-01                       │
---     │   why 9090?                             │
---     ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤
---     │ bob  2026-09-02                         │
---     │   the port                              │
---     ╰─────────────────────────────────────────╯
---@param thread NvimDiff.GitHub.Thread
---@param opts? NvimDiff.ThreadLineOpts
---@return NvimDiff.VirtLine[]
function M.expanded_lines(thread, opts)
  opts = opts or {}
  local width = M.bubble_width(opts.width or 80)
  local border = border_hl(thread, opts)
  local inner = width - 4
  local n = #thread.comments
  local parts = { opts.label }
  local range = M.range_label(thread)
  if range then
    parts[#parts + 1] = range
  end
  parts[#parts + 1] = n == 1 and "1 comment" or ("%d comments"):format(n)
  if thread.resolved and thread.resolved_by then
    parts[#parts + 1] = "resolved by " .. thread.resolved_by
  end
  local badge = M.badge(thread)

  -- Top: `╭─▾ meta ─── BADGE ─╮`; the meta gives way to the badge, then the badge to the
  -- border.
  local lead = "╭" .. (opts.tail and M.TAIL or M.RULE) .. M.EXPANDED
  local close = " " .. M.RULE .. "╮"
  local show_badge = width - dw(lead) - dw(close) - dw(badge[1]) - 2 >= 8
  local meta_room = width - dw(lead) - dw(close) - 2 - (show_badge and dw(badge[1]) + 1 or 0)
  local meta = M.truncate(table.concat(parts, " · "), math.max(1, meta_room))
  local fill = width - dw(lead) - dw(meta) - dw(close) - (show_badge and dw(badge[1]) + 1 or 0)
  local top = {
    { lead, border },
    { meta, hl(thread, "NvimDiffThreadMeta") },
    { " " .. M.RULE:rep(math.max(0, fill - 1)), border },
  }
  if show_badge then
    top[#top + 1] = { " ", border }
    top[#top + 1] = badge
  end
  top[#top + 1] = { close, border }
  local lines = { top }

  ---@param chunks NvimDiff.VirtChunk[] What goes inside, at most `inner` cells.
  local function row(chunks)
    local used = 0
    for _, c in ipairs(chunks) do
      used = used + dw(c[1])
    end
    local out = { { "│ ", border } }
    vim.list_extend(out, chunks)
    out[#out + 1] = { (" "):rep(math.max(0, inner - used)), "" }
    out[#out + 1] = { " │", border }
    lines[#lines + 1] = out
  end

  local body_width = inner - M.INDENT
  local indent = (" "):rep(M.INDENT)
  for i, c in ipairs(thread.comments) do
    if i > 1 then
      lines[#lines + 1] = { { "├" .. M.SEPARATOR:rep(width - 2) .. "┤", border } }
    end
    local stamp = "  " .. date(c.created_at)
    local who = M.truncate(c.author, math.max(1, inner - dw(stamp)))
    row({
      { who, hl(thread, "NvimDiffThreadAuthor") },
      { M.truncate(stamp, math.max(0, inner - dw(who))), hl(thread, "NvimDiffThreadMeta") },
    })
    for _, l in ipairs(M.body_lines(c.body)) do
      for _, piece in ipairs(M.wrap(l, body_width)) do
        row({ { indent .. piece, hl(thread, "NvimDiffThreadBody") } })
      end
    end
  end
  lines[#lines + 1] = { { "╰" .. M.RULE:rep(width - 2) .. "╯", border } }
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
