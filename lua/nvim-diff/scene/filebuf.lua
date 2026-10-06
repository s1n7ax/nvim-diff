--- The real file in a diff pane: a PR review's head pane shows the file checked out in the
--- review slot, in its own buffer, so filetype plugins run and language servers attach — not
--- a scratch copy of the blob (`scene/buffer.lua`).
---
--- The buffer is loaded with `bufadd` + `bufload`: unlisted, no swap file, read-only and not
--- modifiable. It is used only when the file on disk and the buffer both hold exactly the
--- lines that were diffed (bar the CR a CRLF file loses to 'fileformat' `dos`). Anything
--- else — an encoding conversion, a BOM, an eol or LFS filter, a file changed since the
--- checkout, unsaved changes in the user's own buffer on it — and `claim` returns nil, for
--- the caller to show a scratch pane instead.
---
--- Owned and borrowed: a buffer this module loaded is owned. When the pane lets go it stays
--- loaded, hidden, so going back to the file is instant and its language server keeps it
--- open; beyond `buffers.lru_size` of them, the least recently used one that no window
--- shows is wiped. A buffer the user already had (or took over, by opening the file) is
--- borrowed: read-only and 'bufhidden' `hide` while a pane shows it, handed back as it was,
--- never wiped.
---
--- The buffer outlives the pane, and may show in the user's own windows at the same time:
---
--- * the pane's decorations go in namespaces scoped to its window (`nvim__ns_set`,
---   experimental; without it they show in every window on the file);
--- * the plugin's buffer-local keys are mapped only while the pane window is current. In any
---   other window on the buffer, and once the pane lets go, the keys they shadowed (the
---   user's own, a language server's) are back. Keys an `LspAttach` handler maps over the
---   plugin's are taken back right after it;
--- * other plugins' virtual lines (a code lens, a diagnostic's `virtual_lines`) stay: the
---   pair pads the other pane to match (`scene/foreign.lua`);
--- * the pane's window options and folds are taken back (`scene/window.lua` `reset`) before
---   the buffer leaves the pane window, and from another window that got them with the
---   buffer: Neovim gives a window newly showing a buffer the options of a window showing
---   it, or of the one it was last shown in (and a split copies its window's). They go back
---   to the user's values for the file, not the global ones: those the window had for the
---   buffer before the pane's, those a filetype plugin or an `LspAttach` handler set while
---   the buffer loaded (in Neovim's hidden autocmd window: a treesitter `expr` fold method),
---   and those other code set in the pane while it held the buffer. nvim-ufo, kept off the
---   buffer while the pane holds it, gets its fold providers back.
---
--- Guards, while the pane holds the buffer:
---
--- * other code changing the pane window's options — an `LspAttach` handler's `expr` fold
---   method, a statuscolumn or winbar plugin, `foldlevel` — gets the pane's put back
---   (`OptionSet`, and after every `LspAttach`), and the owner (`on_guard`) rebuilds the
---   folds. What it set counts as the user's, for when the pane lets go;
--- * a language server attached to the file but rooted outside `root` (the review slot)
---   gets a warning, once: it may answer from other code than the PR's;
--- * the file changing on disk (found by `:checktime`, or on focus) neither reloads the
---   buffer nor prompts (W11): the pane keeps the diffed lines, and `on_changed` is called
---   for the owner to show the file again — as a copy, since the file no longer matches.
---   Neovim checks a hidden buffer's file only when a window shows it again, so `claim`
---   reads the file on disk for a loaded buffer too, and wipes an owned one whose file
---   changed. An owned buffer shown elsewhere gets no prompt either; once the user took it
---   over (opened the file), Neovim's own.
---
---     local claim, why = require("nvim-diff.scene.filebuf").claim({ path = abs, lines = lines })
---     if claim then
---       local user = window.pane(win, claim.buf, ...)
---       local ns = claim:attach(win, { user = user }) -- paint into ns.line / ns.virt
---       -- ...
---       claim:release()
---     end

local blob = require("nvim-diff.git.blob")
local buffer = require("nvim-diff.scene.buffer")
local config = require("nvim-diff.config")
local log = require("nvim-diff.core.log")
local lsp = require("nvim-diff.core.lsp")
local path = require("nvim-diff.core.path")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

--- How the description of every mapping the plugin sets starts.
local PREFIX = "nvim-diff"

--- Pane options whose change undoes the pane's folds.
local FOLD_OPTIONS = { foldmethod = true, foldenable = true, foldlevel = true, foldminlines = true }

---@class NvimDiff.FileBufOpts
---@field path string Absolute path of the file on disk.
---@field lines string[] The lines diffed: the buffer is used only when it holds these.
--- Treesitter language, started on an owned buffer when nothing else (the user's config, an
--- ftplugin) did.
---@field lang? string
--- The folder the file's language servers belong in (the review slot): one attached to the
--- file but rooted elsewhere gets a warning.
---@field root? string
--- Called (scheduled) when the file changed on disk while a pane showed it. The pane still
--- shows the diffed lines; the owner shows the file again, and `claim` then refuses it.
---@field on_changed? fun()

---@class NvimDiff.FileAttachOpts
--- The window options the pane window had for the buffer before the pane's (`window.pane`):
--- handed back, with what else the user's config set for the file, when the pane lets go.
---@field user? table<string, any>
--- Called after the pane's window options were put back over another plugin's; `refold`
--- when fold options were among them, so the pane's folds are gone.
---@field on_guard? fun(refold: boolean)

---@class NvimDiff.FileClaim
---@field buf integer
---@field owned boolean Loaded by this module, and wiped by it in time (see the top).
--- The namespaces to paint the pane into, scoped to its window; set by `attach`.
---@field ns? NvimDiff.PaneNs
---@field released boolean
---@field private path string
---@field private win? integer The pane window.
---@field private augroup? integer
--- The plugin's mappings of the buffer as last seen: `maplist()` items by mode and lhs.
---@field private ours table<string, table>
--- The buffer's other mappings, to put back where the plugin's replaced them.
---@field private theirs table<string, table>
---@field private active boolean Whether the plugin's mappings are in place.
---@field private saved? { modifiable: boolean, readonly: boolean, bufhidden: string } A borrowed buffer's own.
---@field private root? string
---@field private on_changed? fun()
---@field private on_guard? fun(refold: boolean)
--- The user's window options for the buffer (`window.USER_OPTIONS`), handed back to a
--- window the pane's leave; nil to hand back the global values.
---@field private user? table<string, any>
---@field private loaded? table<string, any> Window options set while the buffer loaded.
---@field private pane? table<string, any> The pane window's own options, as the pane set them.
---@field private guard_queued boolean
---@field private autoread { value: boolean? } The buffer's own 'autoread' (nil: the global).
---@field private stale boolean The file changed on disk while the pane held it.
local Claim = {}
Claim.__index = Claim

--- Owned buffers: the tick of their last use.
---@type table<integer, integer>
local owned = {}
--- The claim on each buffer a pane holds.
---@type table<integer, NvimDiff.FileClaim>
local claimed = {}
--- Buffers whose file changed on disk since they were loaded, still around.
---@type table<integer, true>
local stale = {}
--- Buffers this module watches for changes on disk (see `watch`).
---@type table<integer, true>
local watching = {}
--- Language servers already warned about, by client and root.
---@type table<string, true>
local warned = {}
local tick = 0
--- Namespace pairs no pane uses now, for the next one.
---@type NvimDiff.PaneNs[]
local free_ns = {}
local ns_made = 0

local group = api.nvim_create_augroup("nvim-diff.filebuf", { clear = true })

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

--- The file at `p`, for a message: relative to the cwd (the review slot, in its tabpage).
---@param p string
---@return string
local function shown(p)
  return vim.fn.fnamemodify(p, ":~:.")
end

--- `buf`'s own 'autoread', nil when it has none and the global one applies.
---@param buf integer
---@return boolean?
local function own_autoread(buf)
  return api.nvim_buf_call(buf, function()
    return api.nvim_get_option_value("autoread", { scope = "local" })
  end)
end

-- Changes on disk ------------------------------------------------------------------------

--- Wipe owned buffer `buf` when its file changed on disk and nothing uses it: it holds what
--- the file was, which no pane can show any more. LSP closes it.
---@param buf integer
local function drop_stale(buf)
  if
    api.nvim_buf_is_valid(buf)
    and stale[buf]
    and owned[buf]
    and not claimed[buf]
    and not vim.bo[buf].buflisted
    and not vim.bo[buf].modified
    and #vim.fn.win_findbuf(buf) == 0
  then
    owned[buf], stale[buf] = nil, nil
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

--- `FileChangedShell` on a watched buffer: Neovim found its file changed on disk, and asks
--- this handler instead of prompting (W11).
---@param buf integer
local function file_changed(buf)
  -- `time`, `mode`: the text on disk is still the buffer's.
  local reason = vim.v.fcs_reason
  local text = reason ~= "time" and reason ~= "mode"
  local claim = claimed[buf]
  if claim and not claim.released then
    -- The pane keeps showing the diffed lines: no reload, no prompt.
    api.nvim_set_vvar("fcs_choice", "")
    if text then
      claim:disk_changed()
    end
  elseif owned[buf] and not vim.bo[buf].buflisted then
    -- Loaded for a pane, never opened by the user: no prompt for a file they never saw.
    api.nvim_set_vvar("fcs_choice", "")
    if text then
      stale[buf] = true
      vim.schedule(function()
        drop_stale(buf)
      end)
    end
  else
    -- The user's buffer now: as if nvim-diff were not here.
    api.nvim_set_vvar("fcs_choice", "ask")
  end
end

--- Handle `buf`'s file changing on disk (`file_changed`), for as long as it is owned or a
--- pane holds it. Idempotent.
---@param buf integer
local function watch(buf)
  if watching[buf] then
    return
  end
  watching[buf] = true
  api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    buffer = buf,
    callback = function(args)
      file_changed(args.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function(args)
      owned[args.buf], stale[args.buf], watching[args.buf] = nil, nil, nil
    end,
  })
end

--- Stop watching `buf` (a borrowed one, handed back).
---@param buf integer
local function unwatch(buf)
  if not watching[buf] then
    return
  end
  watching[buf] = nil
  pcall(api.nvim_clear_autocmds, { group = group, buffer = buf })
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
    window.reset(win, self.user)
  end
  vim.schedule(function()
    self:follow_window()
  end)
end

-- Guards ---------------------------------------------------------------------------------

--- Put the pane's window options back where other code changed them, keeping that code's
--- values as the user's; then tell the owner, to rebuild the folds. Soon, not at once: an
--- `LspAttach` handler or a plugin often sets several options in a row.
function Claim:guard_soon()
  if self.guard_queued then
    return
  end
  self.guard_queued = true
  vim.schedule(function()
    self.guard_queued = false
    self:guard()
  end)
end

--- `guard_soon`, now.
function Claim:guard()
  if self.released or not self.pane or not self:holding() then
    return
  end
  local win = self.win --[[@as integer]]
  local function get(name)
    return api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  if self.user then
    -- Not a pane option, so never put back; the user's as it is now.
    self.user.foldexpr = get("foldexpr")
  end
  local changed, refold = false, false
  for name, want in pairs(self.pane) do
    local have = get(name)
    if have ~= want then
      if self.user and self.user[name] ~= nil then
        self.user[name] = have
      end
      api.nvim_set_option_value(name, want, { win = win, scope = "local" })
      changed = true
      refold = refold or FOLD_OPTIONS[name] == true
    end
  end
  if changed and self.on_guard then
    self.on_guard(refold)
  end
end

--- Warn, once, when language server `client_id` attached to the file is rooted outside the
--- review slot: its answers may come from other code than the PR's (a root marker the slot
--- lacks found further up, a client reused from another project).
---@param client_id? integer
function Claim:check_root(client_id)
  if not self.root or not client_id or not package.loaded["vim.lsp"] then
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end
  local outside = lsp.outside(client, self.root)
  local id = client.id .. "\0" .. self.root
  if #outside == 0 or warned[id] then
    return
  end
  warned[id] = true
  log.warn(
    "language server %s on %s is rooted in %s, outside the review slot %s: "
      .. "its answers may come from other code than the PR's",
    client.name,
    shown(self.path),
    table.concat(outside, ", "),
    self.root
  )
end

--- The file changed on disk while the pane held it (`file_changed`): the owner shows it
--- again, as a copy.
function Claim:disk_changed()
  if self.stale then
    return
  end
  self.stale = true
  stale[self.buf] = true
  vim.schedule(function()
    if self.released then
      return
    end
    if self.on_changed then
      self.on_changed()
    else
      log.warn("%s changed on disk; the pane still shows the diffed version", shown(self.path))
    end
  end)
end

--- Hand back a borrowed buffer whose file changed on disk while the pane held it: Neovim
--- took the change as seen, so it would not tell the user. Reloaded as 'autoread' would
--- (the pane kept it unmodified), else a warning.
function Claim:hand_back_stale()
  local buf = self.buf
  stale[buf] = nil
  -- `vim.bo` gives a global-local option's buffer value: nil when the global one applies.
  local autoread = own_autoread(buf)
  if autoread == nil then
    autoread = vim.go.autoread
  end
  if not vim.uv.fs_stat(self.path) then
    log.warn("%s was deleted while the review showed it", shown(self.path))
  elseif autoread and not vim.bo[buf].modified then
    -- `:edit` resets 'readonly'; the buffer goes back as it was.
    local readonly = vim.bo[buf].readonly
    pcall(api.nvim_buf_call, buf, function()
      vim.cmd("silent! edit")
    end)
    vim.bo[buf].readonly = readonly
  else
    log.warn("%s changed on disk while the review showed it; :edit loads it", shown(self.path))
  end
end

-- Claims ---------------------------------------------------------------------------------

--- Whether the claim's pane window still shows its buffer.
---@return boolean
function Claim:holding()
  return self.win ~= nil and api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

--- Load `buf`, recording the window options a filetype plugin, a `FileType` or an
--- `LspAttach` handler set while it loaded: Neovim runs them in its hidden autocmd window,
--- so they never reach a window of the user's. Only those that differ from the global
--- values, which that window starts with (measured).
---@param buf integer
---@return table<string, any> set
local function load(buf)
  local set = {}
  local id = api.nvim_create_autocmd({ "FileType", "LspAttach" }, {
    buffer = buf,
    -- Defined last, so after the user's handlers.
    callback = function()
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_buf(win) ~= buf then
        return
      end
      for _, name in ipairs(window.USER_OPTIONS) do
        local value = api.nvim_get_option_value(name, { win = win, scope = "local" })
        if value ~= api.nvim_get_option_value(name, { scope = "global" }) then
          set[name] = value
        end
      end
    end,
  })
  vim.bo[buf].swapfile = false
  -- A failing autocmd of the user's (a broken ftplugin) is theirs; only the load counts.
  pcall(vim.cmd, ("silent call bufload(%d)"):format(buf))
  pcall(api.nvim_del_autocmd, id)
  return set
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

  local why, loaded
  -- The file on disk first: before loading, so no language server starts on a file that
  -- cannot be used; and for a loaded buffer, whose file may have changed since — Neovim
  -- checks a hidden buffer's file only when a window shows it again.
  local disk = read_lines(p)
  if not disk or not same_lines(disk, opts.lines) then
    why = "it differs from the diffed commit"
    if own and not new then
      -- A copy of what the file was, which no pane can use now.
      stale[buf] = true
      drop_stale(buf)
    end
  elseif api.nvim_buf_is_loaded(buf) then
    if not own and vim.bo[buf].modified then
      why = "it has unsaved changes"
    end
  else
    loaded = load(buf)
    if not api.nvim_buf_is_loaded(buf) then
      why = "it cannot be loaded"
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
    path = p,
    owned = own,
    released = false,
    ours = {},
    theirs = {},
    active = true,
    root = opts.root and path.real(opts.root) or nil,
    on_changed = opts.on_changed,
    loaded = loaded,
    guard_queued = false,
    autoread = { value = own_autoread(buf) },
    stale = false,
  }, Claim)
  if new then
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  end
  if not own then
    self.saved =
      { modifiable = vim.bo[buf].modifiable, readonly = vim.bo[buf].readonly, bufhidden = vim.bo[buf].bufhidden }
    -- Kept loaded, with the pane's marks, while a jump out of the pane shows another
    -- buffer in its window (`scene/pair.lua`), also with 'nohidden'.
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  end
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("readonly", true, { buf = buf })
  -- A change on disk reaches `file_changed` rather than reloading the buffer under the pane.
  api.nvim_set_option_value("autoread", false, { buf = buf })
  watch(buf)
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

--- The buffer is in the pane window `win`, which is set up (`window.pane`, the fold
--- options): scope the namespaces to it, follow the current window for the keys, guard its
--- options, reset `win` when it closes.
---@param win integer
---@param opts? NvimDiff.FileAttachOpts
---@return NvimDiff.PaneNs
function Claim:attach(win, opts)
  opts = opts or {}
  self.win = win
  self.ns = take_ns(win)
  self.on_guard = opts.on_guard
  if opts.user then
    self.user = vim.tbl_extend("force", opts.user, self.loaded or {})
    -- Not a pane option: the pane window carries it as the user's, so `guard` reads it there.
    if self.user.foldexpr ~= opts.user.foldexpr then
      pcall(api.nvim_set_option_value, "foldexpr", self.user.foldexpr, { win = win, scope = "local" })
    end
  end
  self.pane = {}
  for _, name in ipairs(window.PANE_OPTIONS) do
    self.pane[name] = api.nvim_get_option_value(name, { win = win, scope = "local" })
  end
  local buf = self.buf
  self.augroup = api.nvim_create_augroup("nvim-diff.filebuf." .. buf, { clear = true })
  api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:on_enter()
    end,
  })
  -- A language server attached: where it is rooted, then, after every `LspAttach` handler,
  -- the plugin's keys over any it mapped and the pane's window options over any it set
  -- (with `noautocmd`, past `OptionSet`). Its virtual lines stay (`scene/foreign.lua`).
  api.nvim_create_autocmd("LspAttach", {
    group = self.augroup,
    buffer = buf,
    callback = function(args)
      self:check_root(args.data and args.data.client_id)
      if self.active then
        self:remember()
      end
      vim.schedule(function()
        if self.released then
          return
        end
        if self.active then
          self:map_ours()
        end
      end)
      self:guard_soon()
    end,
  })
  -- Guard: the pane's window options.
  api.nvim_create_autocmd("OptionSet", {
    group = self.augroup,
    pattern = vim.list_extend({ "foldexpr" }, window.PANE_OPTIONS),
    callback = function()
      -- Fired in the window whose option changed, API calls included (measured).
      if api.nvim_get_current_win() == self.win then
        self:guard_soon()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(win),
    callback = function()
      -- The window is still there, and its options not yet recorded for the buffer.
      if self:holding() then
        window.reset(win, self.user)
      end
    end,
  })
  -- An LSP jump lists the buffer it goes to, this one too on a jump within the file: an
  -- owned buffer listed in the pane window stays unlisted, the plugin's (listed means the
  -- user opened the file).
  api.nvim_create_autocmd("BufAdd", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      if owned[buf] and api.nvim_get_current_win() == self.win then
        vim.schedule(function()
          if owned[buf] and not self.released and api.nvim_buf_is_valid(buf) then
            api.nvim_set_option_value("buflisted", false, { buf = buf })
          end
        end)
      end
    end,
  })
  -- Servers attached already: a running one attaches while the buffer loads.
  if package.loaded["vim.lsp"] then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
      self:check_root(client.id)
    end
  end
  -- The scene, the view and the review map their keys after this, in this same tick.
  vim.schedule(function()
    if not self.released and self.active then
      self:remember()
    end
  end)
  return self.ns
end

--- Take pane window `win` back to the user's settings for the buffer (`window.reset`),
--- before the buffer leaves it.
---@param win integer
function Claim:reset_window(win)
  window.reset(win, self.user)
end

--- The pane is done with the buffer: its decorations, keys and window options go, the
--- user's keys, window options and a borrowed buffer's options come back, and an owned
--- buffer is kept for next time (`evict`) — or wiped, when its file changed on disk. Call
--- before the pane window closes or shows another buffer. Idempotent.
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
    window.reset(self.win --[[@as integer]], self.user)
  end
  if self.ns then
    api.nvim_buf_clear_namespace(buf, self.ns.line, 0, -1)
    api.nvim_buf_clear_namespace(buf, self.ns.virt, 0, -1)
  end
  self:unmap_ours()
  -- `ui/help.lua` maps `?` again once this is gone.
  vim.b[buf].nvim_diff_help = nil
  vim.b[buf][buffer.VAR] = nil
  window.ufo_restore(buf)
  if self.saved then
    api.nvim_set_option_value("modifiable", self.saved.modifiable, { buf = buf })
    api.nvim_set_option_value("readonly", self.saved.readonly, { buf = buf })
    api.nvim_set_option_value("bufhidden", self.saved.bufhidden, { buf = buf })
  end
  if self.autoread.value == nil then
    api.nvim_buf_call(buf, function()
      vim.cmd("set autoread<")
    end)
  else
    api.nvim_set_option_value("autoread", self.autoread.value, { buf = buf })
  end
  if not (self.owned and owned[buf]) then
    unwatch(buf)
    if self.stale then
      self:hand_back_stale()
    end
    return
  end
  touch(buf)
  if self.stale then
    drop_stale(buf)
  end
  M.evict()
end

--- Whether `buf` is a buffer this module loaded for a pane and still owns (see the top).
---@param buf integer
---@return boolean
function M.owns(buf)
  return owned[buf] ~= nil
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
