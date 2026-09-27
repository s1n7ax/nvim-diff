--- The real file in a diff pane: a PR review's head pane shows the file checked out in the
--- review slot, in its own buffer, so filetype plugins run and language servers attach — not
--- a scratch copy of the blob (`scene/buffer.lua`).
---
--- The buffer is loaded with `bufadd` + `bufload`: unlisted, no swap file, read-only and not
--- modifiable. It is used only when it holds exactly the lines that were diffed (bar the CR a
--- CRLF file loses to 'fileformat' `dos`). Anything else — an encoding conversion, a BOM, an
--- eol or LFS filter, a file changed since the checkout, unsaved changes in the user's own
--- buffer on it — and `claim` returns nil, for the caller to show a scratch pane instead.
---
--- Owned and borrowed: a buffer this module loaded is owned. When the pane lets go it stays
--- loaded, hidden, so going back to the file is instant and its language server keeps it
--- open; beyond `buffers.lru_size` of them, the least recently used one that no window
--- shows is wiped. A buffer the user already had (or took over, by opening the file) is
--- borrowed: read-only while a pane shows it, handed back as it was, never wiped.
---
--- The buffer outlives the pane, and may show in the user's own windows at the same time:
---
--- * the pane's decorations go in namespaces scoped to its window (`nvim__ns_set`,
---   experimental; without it they show in every window on the file);
--- * the plugin's buffer-local keys are mapped only while the pane window is current. In any
---   other window on the buffer, and once the pane lets go, the keys they shadowed (the
---   user's own, a language server's) are back. Keys an `LspAttach` handler maps over the
---   plugin's are taken back right after it;
--- * code lens is off for the buffer while the pane holds it: its lines would push the head
---   pane's rows down, out of line with the base pane;
--- * the pane's window options and folds are taken back (`scene/window.lua` `reset`) before
---   the buffer leaves the pane window, and from another window that got them with the
---   buffer: Neovim gives a window newly showing a buffer the options of a window showing
---   it, or of the one it was last shown in (and a split copies its window's).
---
---     local claim, why = require("nvim-diff.scene.filebuf").claim({ path = abs, lines = lines })
---     if claim then
---       api.nvim_win_set_buf(win, claim.buf)
---       local ns = claim:attach(win) -- paint into ns.line / ns.virt
---       -- ...
---       claim:release()
---     end

local blob = require("nvim-diff.git.blob")
local buffer = require("nvim-diff.scene.buffer")
local config = require("nvim-diff.config")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

--- How the description of every mapping the plugin sets starts.
local PREFIX = "nvim-diff"

---@class NvimDiff.FileBufOpts
---@field path string Absolute path of the file on disk.
---@field lines string[] The lines diffed: the buffer is used only when it holds these.
--- Treesitter language, started on an owned buffer when nothing else (the user's config, an
--- ftplugin) did.
---@field lang? string

---@class NvimDiff.FileClaim
---@field buf integer
---@field owned boolean Loaded by this module, and wiped by it in time (see the top).
--- The namespaces to paint the pane into, scoped to its window; set by `attach`.
---@field ns? NvimDiff.PaneNs
---@field released boolean
---@field private win? integer The pane window.
---@field private augroup? integer
--- The plugin's mappings of the buffer as last seen: `maplist()` items by mode and lhs.
---@field private ours table<string, table>
--- The buffer's other mappings, to put back where the plugin's replaced them.
---@field private theirs table<string, table>
---@field private active boolean Whether the plugin's mappings are in place.
---@field private saved? { modifiable: boolean, readonly: boolean } A borrowed buffer's own.
---@field private lens boolean Code lens was on for the buffer when the pane turned it off.
local Claim = {}
Claim.__index = Claim

--- Owned buffers: the tick of their last use.
---@type table<integer, integer>
local owned = {}
--- The claim on each buffer a pane holds.
---@type table<integer, NvimDiff.FileClaim>
local claimed = {}
local tick = 0
--- Namespace pairs no pane uses now, for the next one.
---@type NvimDiff.PaneNs[]
local free_ns = {}
local ns_made = 0

---@param buf integer
local function touch(buf)
  tick = tick + 1
  owned[buf] = tick
end

--- Whether `have`, a buffer's lines, are `want`, the diffed ones. A line may lack the CR
--- `want` ends it with: a file with CRLF throughout loads as 'fileformat' `dos`.
---@param have string[]
---@param want string[]
---@return boolean
local function same_lines(have, want)
  if #have ~= #want then
    return false
  end
  for i, line in ipairs(want) do
    local h = have[i]
    if h ~= line and not (line:sub(-1) == "\r" and h == line:sub(1, -2)) then
      return false
    end
  end
  return true
end

--- The lines of the file at `p`, split as a blob's are; nil when it cannot be read.
---@param p string
---@return string[]?
local function read_lines(p)
  local f = io.open(p, "rb")
  if not f then
    return nil
  end
  local bytes = f:read("*a")
  f:close()
  return bytes and (blob.lines(bytes)) or nil
end

--- A pair of namespaces for a pane, scoped to its window `win`.
---@param win integer
---@return NvimDiff.PaneNs
local function take_ns(win)
  local ns = table.remove(free_ns)
  if not ns then
    ns_made = ns_made + 1
    ns = {
      line = api.nvim_create_namespace("nvim-diff.render.pane." .. ns_made),
      virt = api.nvim_create_namespace("nvim-diff.render.virt.pane." .. ns_made),
    }
  end
  -- Experimental API: without it the marks show in every window on the file.
  pcall(api.nvim__ns_set, ns.line, { wins = { win } })
  pcall(api.nvim__ns_set, ns.virt, { wins = { win } })
  return ns
end

-- Mappings -------------------------------------------------------------------------------

---@param m table A `maplist()` item.
---@return string
local function key(m)
  return m.mode .. "|" .. m.lhs
end

---@param m table
---@return boolean
local function is_ours(m)
  return type(m.desc) == "string" and vim.startswith(m.desc, PREFIX)
end

--- The buffer-local mappings of `buf`, every mode.
---@param buf integer
---@return table[]
local function mappings(buf)
  return api.nvim_buf_call(buf, function()
    return vim.tbl_filter(function(m)
      return m.buffer == 1
    end, vim.fn.maplist())
  end)
end

---@param buf integer
---@param m table
local function unmap(buf, m)
  pcall(api.nvim_buf_del_keymap, buf, m.mode == " " and "" or m.mode, m.lhs)
end

---@param buf integer
---@param m table
local function map(buf, m)
  api.nvim_buf_call(buf, function()
    pcall(vim.fn.mapset, m)
  end)
end

--- Record the plugin's mappings of the buffer as they are now.
function Claim:remember()
  for _, m in ipairs(mappings(self.buf)) do
    if is_ours(m) then
      self.ours[key(m)] = m
    end
  end
end

--- Put the plugin's mappings in place, keeping what they replace to put back later.
function Claim:map_ours()
  local now = {}
  for _, m in ipairs(mappings(self.buf)) do
    now[key(m)] = m
  end
  for k, m in pairs(self.ours) do
    local cur = now[k]
    if not (cur and is_ours(cur)) then
      if cur then
        self.theirs[k] = cur
      end
      map(self.buf, m)
    end
  end
  self.active = true
end

--- Take the plugin's mappings out and put back the ones they replaced.
function Claim:unmap_ours()
  for _, m in ipairs(mappings(self.buf)) do
    if is_ours(m) then
      unmap(self.buf, m)
    end
  end
  local now = {}
  for _, m in ipairs(mappings(self.buf)) do
    now[key(m)] = true
  end
  for k, m in pairs(self.theirs) do
    if not now[k] then
      map(self.buf, m)
    end
  end
  self.active = false
end

--- The plugin's keys when the pane window is current, the user's in any other window.
function Claim:follow_window()
  if self.released then
    return
  end
  local pane = api.nvim_get_current_win() == self.win
  if pane and not self.active then
    self:map_ours()
  elseif not pane and self.active then
    self:remember()
    self:unmap_ours()
  end
end

--- The buffer was entered in a window. Another window than the pane that came with the
--- pane's options gets the user's back: measured, Neovim gives a new window on a buffer the
--- options and folds of a window already showing it, and a split copies its window's. The
--- keys follow the window that is current once the event is over (`nvim_win_set_buf` on
--- another window makes that one current only while its autocmds run).
function Claim:on_enter()
  if self.released then
    return
  end
  local win = api.nvim_get_current_win()
  if
    win ~= self.win
    and self:holding()
    and api.nvim_win_get_buf(win) == self.buf
    and vim.wo[win].statuscolumn == vim.wo[self.win].statuscolumn
  then
    window.reset(win)
  end
  vim.schedule(function()
    self:follow_window()
  end)
end

--- Turn code lens off for the buffer, when it is on.
function Claim:lens_off()
  -- No `vim.lsp` loaded, no client, no lens; and no need to load it here.
  local lens = package.loaded["vim.lsp"] and vim.lsp.codelens
  if not (lens and lens.enable and lens.is_enabled) then
    return
  end
  local filter = { bufnr = self.buf }
  if lens.is_enabled(filter) then
    pcall(lens.enable, false, filter)
    self.lens = true
  end
end

-- Claims ---------------------------------------------------------------------------------

--- Whether the claim's pane window still shows its buffer.
---@return boolean
function Claim:holding()
  return self.win ~= nil and api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

--- The buffer of the file `opts.path` for a pane, loaded, read-only, holding exactly
--- `opts.lines`. Nil, with the reason, when it cannot be had: the caller shows a scratch
--- pane instead.
---@param opts NvimDiff.FileBufOpts
---@return NvimDiff.FileClaim?
---@return string? why
function M.claim(opts)
  local p = opts.path
  if #opts.lines == 0 then
    return nil, "the file is empty"
  end
  local stat = vim.uv.fs_stat(p)
  if not stat or stat.type ~= "file" then
    return nil, "no such file"
  end
  local before = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    before[b] = true
  end
  local buf = vim.fn.bufadd(p)
  local held = claimed[buf]
  if held and held:holding() then
    return nil, "another pane shows it"
  elseif held then
    -- Left by a pane that never got its window: an error half-way.
    held:release()
  end
  local new = not before[buf]
  if owned[buf] and vim.bo[buf].buflisted then
    -- The user opened the file on it: theirs now.
    owned[buf] = nil
  end
  local own = new or owned[buf] ~= nil

  local why
  if api.nvim_buf_is_loaded(buf) then
    if not own and vim.bo[buf].modified then
      why = "it has unsaved changes"
    end
  else
    -- Checked before loading, so no language server starts on a file that cannot be used.
    local disk = read_lines(p)
    if not disk or not same_lines(disk, opts.lines) then
      why = "it differs from the diffed commit"
    else
      vim.bo[buf].swapfile = false
      -- A failing autocmd of the user's (a broken ftplugin) is theirs; only the load counts.
      pcall(vim.cmd, ("silent call bufload(%d)"):format(buf))
      if not api.nvim_buf_is_loaded(buf) then
        why = "it cannot be loaded"
      end
    end
  end
  if not why and not same_lines(api.nvim_buf_get_lines(buf, 0, -1, false), opts.lines) then
    why = "its buffer differs from the diffed commit"
  end
  if why then
    if new then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
    return nil, why
  end

  local self = setmetatable({
    buf = buf,
    owned = own,
    released = false,
    ours = {},
    theirs = {},
    active = true,
    lens = false,
  }, Claim)
  if new then
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  end
  if not own then
    self.saved = { modifiable = vim.bo[buf].modifiable, readonly = vim.bo[buf].readonly }
  end
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("readonly", true, { buf = buf })
  vim.b[buf][buffer.VAR] = true
  if own and opts.lang and not vim.treesitter.highlighter.active[buf] then
    pcall(vim.treesitter.start, buf, opts.lang)
  end
  for _, m in ipairs(mappings(buf)) do
    if is_ours(m) then
      -- Left by a pane that never let go.
      unmap(buf, m)
    else
      self.theirs[key(m)] = m
    end
  end
  claimed[buf] = self
  if own then
    touch(buf)
  end
  return self
end

--- The buffer is in the pane window `win`, which is set up: scope the namespaces to it,
--- follow the current window for the keys, reset `win` when it closes.
---@param win integer
---@return NvimDiff.PaneNs
function Claim:attach(win)
  self.win = win
  self.ns = take_ns(win)
  local buf = self.buf
  self.augroup = api.nvim_create_augroup("nvim-diff.filebuf." .. buf, { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:on_enter()
    end,
  })
  api.nvim_create_autocmd("LspAttach", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      if self.active then
        self:remember()
      end
      -- After every `LspAttach` handler, some of which map keys of their own.
      vim.schedule(function()
        if self.released then
          return
        end
        self:lens_off()
        if self.active then
          self:map_ours()
        end
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(win),
    callback = function()
      -- The window is still there, and its options not yet recorded for the buffer.
      if self:holding() then
        window.reset(win)
      end
    end,
  })
  self:lens_off()
  -- The scene, the view and the review map their keys after this, in this same tick.
  vim.schedule(function()
    if not self.released and self.active then
      self:remember()
    end
  end)
  return self.ns
end

--- The pane is done with the buffer: its decorations, keys and window options go, the
--- user's keys and a borrowed buffer's options come back, and an owned buffer is kept for
--- next time (`evict`). Call before the pane window closes or shows another buffer.
--- Idempotent.
function Claim:release()
  if self.released then
    return
  end
  self.released = true
  local buf = self.buf
  if claimed[buf] == self then
    claimed[buf] = nil
  end
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.ns then
    free_ns[#free_ns + 1] = self.ns
  end
  if not api.nvim_buf_is_valid(buf) then
    owned[buf] = nil
    return
  end
  if self:holding() then
    window.reset(self.win --[[@as integer]])
  end
  if self.ns then
    api.nvim_buf_clear_namespace(buf, self.ns.line, 0, -1)
    api.nvim_buf_clear_namespace(buf, self.ns.virt, 0, -1)
  end
  self:unmap_ours()
  -- `ui/help.lua` maps `?` again once this is gone.
  vim.b[buf].nvim_diff_help = nil
  vim.b[buf][buffer.VAR] = nil
  if self.lens then
    pcall(vim.lsp.codelens.enable, true, { bufnr = buf })
  end
  if self.saved then
    api.nvim_set_option_value("modifiable", self.saved.modifiable, { buf = buf })
    api.nvim_set_option_value("readonly", self.saved.readonly, { buf = buf })
  end
  if self.owned and owned[buf] then
    touch(buf)
    M.evict()
  end
end

--- Wipe the least recently used owned buffers that no pane holds and no window shows,
--- until at most `buffers.lru_size` are left. One the user opened becomes theirs instead.
function M.evict()
  local order = {}
  for buf in pairs(owned) do
    if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buflisted then
      owned[buf] = nil
    else
      order[#order + 1] = buf
    end
  end
  local excess = #order - config.get().buffers.lru_size
  if excess <= 0 then
    return
  end
  table.sort(order, function(a, b)
    return owned[a] < owned[b]
  end)
  for _, buf in ipairs(order) do
    if excess <= 0 then
      break
    end
    if not claimed[buf] and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 then
      owned[buf] = nil
      pcall(api.nvim_buf_delete, buf, { force = true })
      excess = excess - 1
    end
  end
end

return M
