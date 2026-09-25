--- The key menu, after lazygit's `?`: a float listing every nvim-diff key of the buffer the
--- cursor is in — the panel, a diff pane, the comment split — with what it does. Pick one
--- with `<CR>` to run it there, or read its key and close the menu to use it next time.
---
---     require("nvim-diff.ui.help").attach(buf) -- maps `keymaps.help` in `buf`, once
---
--- The list is read from the buffer's own mappings (every one the plugin sets carries an
--- `nvim-diff: ` description), so it is always exactly what works in that buffer — no
--- second table of keys to keep in step.

local config = require("nvim-diff.config")

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace("nvim-diff.help")

local PREFIX = "nvim-diff: "

--- Section order in the menu; a group not listed here comes after these, by name.
local GROUPS = { "Files", "Diff", "Review", "Comments", "Threads", "Conflicts", "Compose", "Folds", "General" }

---@class NvimDiff.HelpItem
---@field group string The section it is listed under: the `Group: ` part of its description.
---@field key string The keys as shown, `<leader>` put back, special keys in `<>` notation;
--- several keys that do the same thing share one item.
---@field desc string
---@field lhsraw string The first key as typed, to run it.

--- `lhs` in `<>` notation, with the leader spelled `<leader>`.
---@param lhsraw string
---@return string
local function show_key(lhsraw)
  local key = vim.fn.keytrans(lhsraw)
  local leader = vim.g.mapleader
  if type(leader) ~= "string" or leader == "" then
    leader = "\\"
  end
  local l = vim.fn.keytrans(leader)
  if vim.startswith(key, l) and #key > #l then
    key = "<leader>" .. key:sub(#l + 1)
  end
  return key
end

---@param group string
---@return integer
local function group_rank(group)
  return vim.fn.index(GROUPS, group) + 1
end

--- `desc` for sorting: a `Next x` and its `Previous x` sort together, under `x`.
---@param desc string
---@return string
local function sort_key(desc)
  local d = desc:lower()
  local rest = d:match("^next (.+)")
  if rest then
    return rest .. " 1"
  end
  rest = d:match("^previous (.+)")
  if rest then
    return rest .. " 2"
  end
  return d
end

--- The nvim-diff keys of `buf` in normal mode, by section, then by what they do. A
--- description reads `nvim-diff: Group: text`; one with no group goes under `General`.
--- Keys that only block something (`<Nop>`) and the menu's own key are left out.
---@param buf integer
---@return NvimDiff.HelpItem[]
function M.items(buf)
  local help = config.get().keymaps.help
  local by_desc = {}
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    local desc = m.desc
    local nop = not m.callback and (m.rhs == nil or m.rhs == "" or m.rhs:lower() == "<nop>")
    if desc and vim.startswith(desc, PREFIX) and not nop then
      local key = show_key(m.lhsraw or m.lhs)
      if key ~= help then
        local text = desc:sub(#PREFIX + 1)
        local group, rest = text:match("^(%u[%w ]-): (.+)$")
        group, text = group or "General", rest or text
        local id = group .. "\0" .. text
        local it = by_desc[id]
        if it then
          it.keys[#it.keys + 1] = { key = key, lhsraw = m.lhsraw or m.lhs }
        else
          it = { group = group, desc = text, keys = { { key = key, lhsraw = m.lhsraw or m.lhs } } }
          by_desc[id] = it
          out[#out + 1] = it
        end
      end
    end
  end
  for _, it in ipairs(out) do
    table.sort(it.keys, function(a, b)
      local la, lb = a.key:lower(), b.key:lower()
      if la ~= lb then
        return la < lb
      end
      return a.key > b.key
    end)
    it.key = table.concat(
      vim.tbl_map(function(k)
        return k.key
      end, it.keys),
      " "
    )
    it.lhsraw = it.keys[1].lhsraw
    it.keys = nil
  end
  table.sort(out, function(a, b)
    if a.group ~= b.group then
      local ra, rb = group_rank(a.group), group_rank(b.group)
      if ra ~= rb then
        return ra ~= 0 and (rb == 0 or ra < rb)
      end
      return a.group < b.group
    end
    local sa, sb = sort_key(a.desc), sort_key(b.desc)
    if sa ~= sb then
      return sa < sb
    end
    return a.key < b.key
  end)
  return out
end

---@class NvimDiff.Help
---@field buf integer The menu's buffer.
---@field win integer The menu's float.
---@field from integer The window the menu was opened from; keys run there.
---@field items table<integer, NvimDiff.HelpItem> The item on each menu line; none on titles.
---@field closed? boolean
local Help = {}
Help.__index = Help

--- The menu open now, if any.
---@type NvimDiff.Help?
local current

--- Open the menu for the current buffer, centred over the editor.
---@return NvimDiff.Help?
function M.open()
  if current then
    current:close()
  end
  local from = api.nvim_get_current_win()
  local items = M.items(api.nvim_win_get_buf(from))
  if #items == 0 then
    require("nvim-diff.core.log").warn("no nvim-diff keys here")
    return nil
  end
  local key_w = 0
  for _, it in ipairs(items) do
    key_w = math.max(key_w, vim.fn.strdisplaywidth(it.key))
  end
  -- A section title, then its keys indented under it; a blank line between sections.
  -- `at[lnum]` is the item on that line, nil on titles and blanks.
  local lines, at, titles = {}, {}, {}
  local width = 0
  local function add(line, item)
    lines[#lines + 1] = line
    at[#lines] = item
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local group
  for _, it in ipairs(items) do
    if it.group ~= group then
      if group then
        add("")
      end
      group = it.group
      add(" " .. group)
      titles[#lines] = true
    end
    add(("   %s%s   %s "):format(it.key, (" "):rep(key_w - vim.fn.strdisplaywidth(it.key)), it.desc), it)
  end
  width = math.min(math.max(width, 30), vim.o.columns - 4)
  local height = math.min(#lines, math.max(1, vim.o.lines - 6))

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for lnum, line in ipairs(lines) do
    if titles[lnum] then
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, { end_col = #line, hl_group = "NvimDiffHelpGroup" })
    elseif at[lnum] then
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 3, { end_col = 3 + #at[lnum].key, hl_group = "NvimDiffHelpKey" })
      api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 3 + key_w, { end_col = #line, hl_group = "NvimDiffHelpDesc" })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Keys ",
    title_pos = "center",
    footer = " <CR> run · q close ",
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "FloatBorder:NvimDiffHelpBorder,FloatTitle:NvimDiffHelpTitle"

  local self = setmetatable({ buf = buf, win = win, from = from, items = at }, Help)
  api.nvim_win_set_cursor(win, { 2, 0 })
  -- Keep the cursor on keys: titles and blank lines are stepped over, in the direction
  -- it was moving.
  local last = 2
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local lnum = api.nvim_win_get_cursor(win)[1]
      if at[lnum] then
        last = lnum
        return
      end
      local step = lnum < last and -1 or 1
      local n = lnum
      while n >= 1 and n <= #lines and not at[n] do
        n = n + step
      end
      if not at[n] then
        n = last
      end
      last = n
      api.nvim_win_set_cursor(win, { n, 0 })
    end,
  })
  current = self
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("<CR>", function()
    self:run(api.nvim_win_get_cursor(self.win)[1])
  end)
  for _, lhs in ipairs({ "q", "<Esc>", config.get().keymaps.help }) do
    if type(lhs) == "string" then
      map(lhs, function()
        self:close()
      end)
    end
  end
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  return self
end

--- Close the menu, focus back on the window it was opened from.
--- Only the first close moves focus: a late one (the `WinLeave` fallback) must not pull
--- the cursor back from wherever it has gone since.
function Help:close()
  if current == self then
    current = nil
  end
  if self.closed then
    return
  end
  self.closed = true
  local focused = api.nvim_get_current_win() == self.win
  if api.nvim_win_is_valid(self.win) then
    pcall(api.nvim_win_close, self.win, true)
  end
  if focused and api.nvim_win_is_valid(self.from) then
    api.nvim_set_current_win(self.from)
  end
end

--- Close the menu and press the key on menu line `lnum` in the window it was opened from.
---@param lnum integer
function Help:run(lnum)
  local it = self.items[lnum]
  self:close()
  if it then
    api.nvim_feedkeys(it.lhsraw, "m", false)
  end
end

--- Map `keymaps.help` in `buf`. Idempotent.
---@param buf integer
function M.attach(buf)
  local lhs = config.get().keymaps.help
  if type(lhs) ~= "string" or not api.nvim_buf_is_valid(buf) or vim.b[buf].nvim_diff_help then
    return
  end
  vim.b[buf].nvim_diff_help = true
  vim.keymap.set("n", lhs, M.open, { buffer = buf, nowait = true, desc = PREFIX .. "General: Show keys" })
end

return M
