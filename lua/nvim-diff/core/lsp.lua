--- Language server clients by the folders they are rooted in: their root directory and
--- workspace folders. A review slot's head pane warns about a server rooted outside the
--- slot (`scene/filebuf.lua`); a review stops the servers rooted in its slot before a fork
--- PR is checked out there, and when it ends (`views/review.lua`); a fork PR's review
--- keeps every server off its slot until the reviewer says yes (`block`).
---
---     lsp.outside(client, slot)      -- the client's roots that are not the slot or inside it
---     lsp.stop_in(slot, "checkout")  -- kill every client with a root in the slot, at once
---     lsp.stop_in(slot, "close")     -- stop the clients rooted only in the slot, gracefully
---     local block = lsp.block(slot, on_blocked) -- no server on the slot's files from now
---     block:lift({ start = true })   -- until here; start them on its open files
---
--- Only `block` loads `vim.lsp`: with it not loaded there is no client.

local path = require("nvim-diff.core.path")

local api = vim.api

local M = {}

--- The folders `client` is rooted in, resolved: its root directory and its workspace
--- folders. Empty for a client in single-file mode. Also takes a client's config, for the
--- folders a client made from it would be rooted in.
---@param client vim.lsp.Client|vim.lsp.ClientConfig
---@return string[]
function M.roots(client)
  local seen, list = {}, {}
  local function add(dir)
    if type(dir) == "string" and dir ~= "" then
      dir = path.real(dir)
      if not seen[dir] then
        seen[dir] = true
        list[#list + 1] = dir
      end
    end
  end
  add(client.root_dir)
  if type(client.workspace_folders) == "table" then
    for _, f in ipairs(client.workspace_folders) do
      add(f.uri and vim.uri_to_fname(f.uri) or f.name)
    end
  end
  return list
end

--- The roots of `client` that are neither `dir` nor inside it.
---@param client vim.lsp.Client
---@param dir string
---@return string[]
function M.outside(client, dir)
  local root = path.real(dir)
  return vim.tbl_filter(function(r)
    return not path.is_under(r, root)
  end, M.roots(client))
end

--- How long a server stopped in mode `close` gets to shut down before it is killed.
-- Measured: lua-language-server busy with a fresh workspace never answered `shutdown`, and
-- Neovim's default `exit_timeout` is never to force.
M.STOP_TIMEOUT_MS = 5000

---@alias NvimDiff.LspStopMode
---| "checkout" # before another PR is checked out into the folder
---| "close"    # the review ended

--- Kill `client`'s server now, unless it is already going: not `is_stopped()`, which is true
--- as soon as a graceful shutdown starts, while the server may still be running for up to
--- `STOP_TIMEOUT_MS`.
---@param client vim.lsp.Client
---@return boolean killed
local function kill(client)
  if client.rpc.is_closing() then
    return false
  end
  client:stop(true)
  return true
end

--- Stop this Neovim's language servers rooted in review slot `dir`, including servers still
--- starting up (a starting server's process may already be reading the slot), as `mode`
--- says:
---
--- * `checkout`: every server with any root in `dir`, one still shutting down after the last
---   review ended too — so none started for an earlier PR can index, or build, the next
---   one's code — killed at once: no shutdown to wait out while the checkout starts;
--- * `close`: every server rooted only in `dir` — at least one root, and all of them `dir`
---   or inside it; one also rooted elsewhere (the user's own project) keeps running — shut
---   down gracefully, and killed if still running after `STOP_TIMEOUT_MS` (or its own
---   shorter `exit_timeout`).
---@param dir string
---@param mode NvimDiff.LspStopMode
---@return integer stopped
function M.stop_in(dir, mode)
  assert(mode == "checkout" or mode == "close", "nvim-diff: unknown stop mode")
  -- Nothing has loaded `vim.lsp`: there is no client, and no need to load it here.
  if not package.loaded["vim.lsp"] then
    return 0
  end
  local root = path.real(dir)
  local stopped = 0
  -- `_uninitialized` is Neovim's own (package) filter for servers still starting; a Neovim
  -- without it lists only the started ones.
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    local roots = M.roots(client)
    local inside = #vim.tbl_filter(function(r)
      return path.is_under(r, root)
    end, roots)
    if mode == "checkout" then
      -- One still shutting down from the last review's end is running too.
      if inside > 0 and kill(client) then
        stopped = stopped + 1
      end
    elseif inside > 0 and inside == #roots and not client:is_stopped() then
      local timeout = client.exit_timeout
      if type(timeout) ~= "number" or timeout > M.STOP_TIMEOUT_MS then
        timeout = M.STOP_TIMEOUT_MS
      end
      client:stop(timeout)
      stopped = stopped + 1
    end
  end
  return stopped
end

-- Blocks ---------------------------------------------------------------------------------
--
-- Neovim has no event before a language server starts, and nothing in a client's config
-- that can refuse one: the server's process is spawned as the client is made
-- (`vim.lsp.Client.create`), before `before_init` runs, and `LspAttach` comes after its
-- `initialize`, with the file already sent. So a block wraps the two functions a start goes
-- through — `vim.lsp.start` (`vim.lsp.enable`'s `FileType` handler, nvim-lspconfig, most
-- plugins) and `vim.lsp.buf_attach_client` (a running client reused for another file; the
-- old `vim.lsp.start_client` way) — and refuses there, before anything is spawned. A server
-- that gets past them (code that kept the functions from before, or starts one another
-- way) is caught on `LspAttach` and killed at once.
--
-- The wrappers stay once made — taking them out could drop another plugin's wrapper over
-- them — and pass every call straight on while no block is in place.

---@class NvimDiff.LspBlock
---@field lifted boolean
---@field private dirs string[] The folder: as given, and with its links resolved.
---@field private on_blocked fun(name: string, file?: string)
local Block = {}
Block.__index = Block

--- The blocks in place.
---@type table<NvimDiff.LspBlock, true>
local blocks = {}
local wrapped = false
--- The `LspAttach` autocmd, while any block is in place.
---@type integer?
local net

--- Whether Neovim spawns the server of `config` itself: its `cmd` is a command, not a
--- function (a server run inside Neovim, or a connection to one already running).
---@param config vim.lsp.ClientConfig
---@return boolean
local function spawned(config)
  return type(config.cmd) ~= "function"
end

---@param config vim.lsp.ClientConfig
---@return string
local function config_name(config)
  if type(config.name) == "string" then
    return config.name
  elseif type(config.cmd) == "table" and type(config.cmd[1]) == "string" then
    return vim.fs.basename(config.cmd[1])
  end
  return "a language server"
end

--- Whether `p`, a file or a folder, is in the block's folder. Not a URI (`oil://`).
---@param p? string
---@return boolean
function Block:holds(p)
  if type(p) ~= "string" or p == "" or p:find("^%a[%w+.-]*://") then
    return false
  end
  local forms = { path.normalize(p) }
  local real = path.real(p)
  if real ~= forms[1] then
    forms[2] = real
  end
  for _, dir in ipairs(self.dirs) do
    for _, form in ipairs(forms) do
      if path.is_under(form, dir) then
        return true
      end
    end
  end
  return false
end

--- Whether buffer `buf`'s file is in the block's folder.
---@param buf integer
---@return boolean
function Block:holds_buf(buf)
  return api.nvim_buf_is_valid(buf) and self:holds(api.nvim_buf_get_name(buf))
end

--- Whether any of `roots` (a client's, `M.roots`) is in the block's folder.
---@param roots string[]
---@return boolean
function Block:holds_any(roots)
  for _, r in ipairs(roots) do
    if self:holds(r) then
      return true
    end
  end
  return false
end

--- Tell the owner a server was kept off the folder: `name`, on buffer `buf`'s file.
---@param name string
---@param buf? integer
function Block:refused(name, buf)
  if self.lifted then
    return
  end
  local file = buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) or nil
  pcall(self.on_blocked, name, file)
end

--- Take `client` off the block's folder. Killed at once when it is there for the folder's
--- code: rooted in it (when Neovim spawned it, or it serves a file there), or rooted
--- nowhere and serving files there only. Otherwise — the user's own server, rooted
--- elsewhere — only detached from the folder's files.
---@param client vim.lsp.Client
---@param buf? integer A file in the folder `client` was refused on just now.
---@return boolean acted Whether it was killed or detached from a file.
function Block:enforce(client, buf)
  local inside, others = {}, 0
  for b in pairs(client.attached_buffers) do
    if self:holds_buf(b) then
      inside[#inside + 1] = b
    else
      others = others + 1
    end
  end
  local roots = M.roots(client)
  local serves = #inside > 0 or buf ~= nil
  if (self:holds_any(roots) and (spawned(client.config) or serves)) or (#roots == 0 and others == 0 and serves) then
    return kill(client)
  end
  for _, b in ipairs(inside) do
    -- Not inside the attach that may be running.
    vim.schedule(function()
      if client.attached_buffers[b] then
        pcall(vim.lsp.buf_detach_client, b, client.id)
      end
    end)
  end
  return #inside > 0
end

--- The block keeping `config`'s server from starting (`vim.lsp.start` with `opts`), and the
--- buffer it would attach to there, if any.
---@param config vim.lsp.ClientConfig
---@param opts vim.lsp.start.Opts
---@return NvimDiff.LspBlock?
---@return integer? buf
local function refusing(config, opts)
  local buf = opts.bufnr
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  local roots
  for b in pairs(blocks) do
    if opts.attach ~= false and b:holds_buf(buf) then
      return b, buf
    end
    if spawned(config) then
      if not roots then
        roots = M.roots(config)
        -- What `vim.lsp.start` finds from the buffer when given markers (`vim.lsp.enable`):
        -- an unnamed buffer's search starts in the cwd, which may be the slot.
        local markers = opts._root_markers
        if not config.root_dir and type(markers) == "table" and api.nvim_buf_is_valid(buf) then
          local ok, root = pcall(vim.fs.root, buf, markers)
          if ok and root then
            roots[#roots + 1] = path.real(root)
          end
        end
      end
      if b:holds_any(roots) then
        return b, nil
      end
    end
  end
  return nil
end

--- `LspAttach`: a server that got past the wrappers onto a blocked folder.
---@param args vim.api.keyset.create_autocmd.callback_args
local function on_attach(args)
  local client = vim.lsp.get_client_by_id(args.data and args.data.client_id or -1)
  if not client then
    return
  end
  for b in pairs(blocks) do
    local here = b:holds_buf(args.buf)
    if (here or b:holds_any(M.roots(client))) and b:enforce(client) then
      b:refused(client.name, here and args.buf or nil)
    end
  end
end

--- Wrap `vim.lsp.start` and `vim.lsp.buf_attach_client`, once.
local function wrap()
  if wrapped then
    return
  end
  wrapped = true
  local vlsp = vim.lsp
  local start, attach = vlsp.start, vlsp.buf_attach_client
  -- Writing into `vim.lsp` is the point here.
  -- luacheck: push ignore 122
  vlsp.start = function(config, opts)
    if next(blocks) and type(config) == "table" then
      local b, buf = refusing(config, opts or {})
      if b then
        b:refused(config_name(config), buf)
        return nil
      end
    end
    return start(config, opts)
  end
  vlsp.buf_attach_client = function(bufnr, client_id)
    if next(blocks) and (bufnr == nil or type(bufnr) == "number") and type(client_id) == "number" then
      local buf = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
      for b in pairs(blocks) do
        if b:holds_buf(buf) then
          local client = vlsp.get_client_by_id(client_id)
          b:refused(client and client.name or "a language server", buf)
          if client then
            -- One made for this file alone (`vim.lsp.start_client`) is running already.
            b:enforce(client, buf)
          end
          return false
        end
      end
    end
    return attach(bufnr, client_id)
  end
  -- luacheck: pop
end

--- Keep every language server off folder `dir` (a fork PR's review slot, after a no) until
--- `lift`: none starts for a file in it or rooted in it, or attaches to a file in it —
--- refused before its process is spawned; one that gets past is killed at once (rooted in
--- `dir`, or there for its files only) or detached from them (the user's own, rooted
--- elsewhere). Servers there already are dealt with the same way now. Files outside `dir`
--- are left alone, and so is a server Neovim does not spawn (`cmd` a function) rooted in
--- `dir` while it serves no file there: `vim.pack`'s, rooted in the cwd.
---
--- `on_blocked(name, file)` is called on every server kept off since: its name, and the
--- file it would have served, if any.
---
--- Loads `vim.lsp`. A config's `root_dir` function (`vim.lsp.config`) still runs for a file
--- in `dir`: only the start it leads to is refused.
---@param dir string
---@param on_blocked fun(name: string, file?: string)
---@return NvimDiff.LspBlock
function M.block(dir, on_blocked)
  wrap()
  local dirs = { path.normalize(dir) }
  local real = path.real(dir)
  if real ~= dirs[1] then
    dirs[2] = real
  end
  local self = setmetatable({ dirs = dirs, on_blocked = on_blocked, lifted = false }, Block)
  blocks[self] = true
  net = net
    or api.nvim_create_autocmd("LspAttach", {
      group = api.nvim_create_augroup("nvim-diff.lsp.block", { clear = true }),
      callback = on_attach,
    })
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    self:enforce(client)
  end
  return self
end

--- Let language servers onto the folder again. With `start`, the servers `vim.lsp.enable`
--- has for the folder's files open now start on them, as when they were opened; one
--- started some other way (an ftplugin, nvim-lspconfig's own `setup`) waits for its file to
--- be opened again (`:edit`). Idempotent.
---@param opts? { start?: boolean }
function Block:lift(opts)
  if self.lifted then
    return
  end
  self.lifted = true
  blocks[self] = nil
  if not next(blocks) and net then
    pcall(api.nvim_del_autocmd, net)
    net = nil
  end
  if not (opts and opts.start) then
    return
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if
      api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and vim.bo[buf].filetype ~= ""
      and self:holds_buf(buf)
    then
      -- Neovim's own handler (`vim.lsp.enable`); no such group without it.
      pcall(api.nvim_exec_autocmds, "FileType", { group = "nvim.lsp.enable", buffer = buf, modeline = false })
    end
  end
end

return M
