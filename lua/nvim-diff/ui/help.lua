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

---@class NvimDiff.HelpItem
---@field key string The key as shown: `<leader>` put back, special keys in `<>` notation.
---@field desc string
---@field lhsraw string The key as typed, to run it.

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

--- The nvim-diff keys of `buf` in normal mode, sorted by what they do. Keys that only
--- block something (`<Nop>`) and the menu's own key are left out.
---@param buf integer
---@return NvimDiff.HelpItem[]
function M.items(buf)
  local help = config.get().keymaps.help
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    local desc = m.desc
    local nop = not m.callback and (m.rhs == nil or m.rhs == "" or m.rhs:lower() == "<nop>")
    if desc and vim.startswith(desc, PREFIX) and not nop then
      local key = show_key(m.lhsraw or m.lhs)
      if key ~= help then
        out[#out + 1] = { key = key, desc = desc:sub(#PREFIX + 1), lhsraw = m.lhsraw or m.lhs }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.desc ~= b.desc then
      return a.desc < b.desc
    end
    return a.key < b.key
  end)
  return out
end

---@class NvimDiff.Help
---@field buf integer The menu's buffer.
---@field win integer The menu's float.
---@field from integer The window the menu was opened from; keys run there.
---@field items NvimDiff.HelpItem[]
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
  local lines = {}
  local width = 0
  for i, it in ipairs(items) do
    lines[i] = (" %s%s  %s "):format(it.key, (" "):rep(key_w - vim.fn.strdisplaywidth(it.key)), it.desc)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, math.max(1, vim.o.lines - 6))

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, it in ipairs(items) do
    api.nvim_buf_set_extmark(buf, M.ns, i - 1, 1, { end_col = 1 + #it.key, hl_group = "NvimDiffHelpKey" })
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
    title = " nvim-diff keys ",
    title_pos = "center",
    footer = " <CR> run · q close ",
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "FloatBorder:NvimDiffHelpBorder,FloatTitle:NvimDiffHelpTitle"

  local self = setmetatable({ buf = buf, win = win, from = from, items = items }, Help)
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

--- Close the menu and press the key of item `i` in the window it was opened from.
---@param i integer
function Help:run(i)
  local it = self.items[i]
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
  vim.keymap.set("n", lhs, M.open, { buffer = buf, nowait = true, desc = PREFIX .. "list the keys that work here" })
end

return M
