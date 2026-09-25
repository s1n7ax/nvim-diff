--- Diff pane buffers: read-only scratch buffers holding one side of a diff.
---
--- Layout, fixed for every renderer: buffer line 1 is the header (`virt_lines_above` on
--- row 0 never renders, so filler above the file's first line needs a real line to hang
--- from), the file's lines follow, and an optional empty trailer line ends it (see
--- `render/rowmap.lua` for when).
---
--- Buffers of immutable content — a blob at a commit, asked for with `keep` — outlive the
--- scene that showed them: `release` hides such a buffer instead of wiping it, and the
--- next `create` under the same name takes it back, so returning to a file skips the
--- buffer build and the treesitter parse. At most `buffers.lru_size` of them are kept;
--- when there are more, the least recently used that no window displays are wiped. `0`
--- keeps none. Everything else (the work tree, the index, unified panes, a second copy of
--- a blob another window already shows) is wiped as soon as its scene lets go of it.

local config = require("nvim-diff.config")

local api = vim.api

local M = {}

---@class NvimDiff.PaneBufOpts
---@field lines string[] The file's lines, no terminators.
---@field header string Text of buffer line 1.
---@field trailer? boolean Append the empty trailer line.
--- Buffer name, set **before** the content so concurrent requests for one blob dedupe on
--- it (`nvim-diff://<gitdir>/<rev>/<path>`). Unnamed when omitted, and when another
--- buffer already has the name and cannot be reused (a window shows it).
---@field name? string
--- Treesitter language to highlight with. Started with `vim.treesitter.start` only — no
--- `filetype` is set, so no ftplugin can reach into the pane's window options.
---@field lang? string
--- The content never changes under this name (a blob at a commit): keep the buffer after
--- `release`, for reuse. Only honoured for a named buffer.
---@field keep? boolean

--- Buffer variable (`b:nvim_diff_pane`) set on every pane buffer, before any window shows
--- it, so other plugins can leave the pane alone — e.g. nvim-ufo's `provider_selector`
--- returning `''` for it, or ufo's folds would replace the context folds.
M.VAR = "nvim_diff_pane"

--- Options every pane buffer carries. `modifiable` is set last, after the content.
local BUF_OPTIONS = {
  buftype = "nofile",
  bufhidden = "wipe",
  swapfile = false,
  buflisted = false,
  undolevels = -1,
}

--- Modes whose buffer-local mappings `release` clears.
local MAP_MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

--- Kept buffers, by handle: the tick of their last use (create or release).
---@type table<integer, integer>
local kept = {}
--- Kept buffers by the name they were created with, and the reverse.
---@type table<string, integer>
local names = {}
---@type table<integer, string>
local name_of = {}
--- Kept buffers handed out by `create` and not yet released. Never handed out twice, even
--- before a window shows them (a pair builds both sides before displaying either).
---@type table<integer, true>
local in_use = {}
local tick = 0

--- Stop tracking `buf` (gone, or about to be).
---@param buf integer
local function forget(buf)
  kept[buf] = nil
  in_use[buf] = nil
  if name_of[buf] and names[name_of[buf]] == buf then
    names[name_of[buf]] = nil
  end
  name_of[buf] = nil
end

---@param buf integer
local function touch(buf)
  tick = tick + 1
  kept[buf] = tick
end

--- The pane's full text: header, file lines, optional trailer.
---@param opts NvimDiff.PaneBufOpts
---@return string[]
local function text_of(opts)
  local text = { opts.header }
  for i, line in ipairs(opts.lines) do
    -- A NUL in a blob arrives as `\n` when split on newlines; the buffer stores NUL as NL.
    text[i + 1] = line:find("\n", 1, true) and line:gsub("\n", "\0") or line
  end
  if opts.trailer then
    text[#text + 1] = ""
  end
  return text
end

---@param buf integer
---@param text string[]
local function set_text(buf, text)
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  api.nvim_set_option_value("modified", false, { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- Put `text` in a reused buffer, touching only the lines that differ — usually just the
--- header and the trailer — so the treesitter tree is updated rather than rebuilt.
---@param buf integer
---@param text string[]
local function update_text(buf, text)
  local cur = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first = 1
  while first <= #cur and first <= #text and cur[first] == text[first] do
    first = first + 1
  end
  if first > #cur and first > #text then
    return
  end
  local cur_last, last = #cur, #text
  while cur_last >= first and last >= first and cur[cur_last] == text[last] do
    cur_last, last = cur_last - 1, last - 1
  end
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, first - 1, cur_last, false, vim.list_slice(text, first, last))
  api.nvim_set_option_value("modified", false, { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })
end

--- A kept buffer named `name` that is free to take back: valid, released, in no window.
---@param name string
---@return integer?
local function reusable(name)
  local buf = names[name]
  if buf and kept[buf] and not in_use[buf] and api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
    return buf
  end
  return nil
end

--- Strip what a scene hung on a buffer: extmarks in every namespace and buffer-local
--- mappings, whose closures would otherwise hold on to a closed scene.
---@param buf integer
local function scrub(buf)
  api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  for _, mode in ipairs(MAP_MODES) do
    for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
      pcall(api.nvim_buf_del_keymap, buf, mode, map.lhs)
    end
  end
end

--- Create a pane buffer, or take back a kept one with the same name.
---@param opts NvimDiff.PaneBufOpts
---@return integer buf
function M.create(opts)
  local text = text_of(opts)
  local name = opts.name
  if name and vim.fn.bufexists(name) == 1 then
    local buf = reusable(name)
    if buf then
      touch(buf)
      in_use[buf] = true
      scrub(buf)
      update_text(buf, text)
      if opts.lang and not vim.treesitter.highlighter.active[buf] then
        pcall(vim.treesitter.start, buf, opts.lang)
      end
      return buf
    end
    name = nil
  end

  local buf = api.nvim_create_buf(false, true)
  for option, value in pairs(BUF_OPTIONS) do
    api.nvim_set_option_value(option, value, { buf = buf })
  end
  vim.b[buf][M.VAR] = true
  if name then
    api.nvim_buf_set_name(buf, name)
    if opts.keep then
      -- Hidden, not wiped, when its window closes: `release` decides its fate.
      api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
      names[name], name_of[buf] = buf, name
      in_use[buf] = true
      touch(buf)
    end
  end
  set_text(buf, text)

  if opts.lang then
    pcall(vim.treesitter.start, buf, opts.lang)
  end
  return buf
end

---@param buf integer
local function wipe(buf)
  forget(buf)
  if api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

--- Wipe the least recently used kept buffers that are released and in no window, until at
--- most `buffers.lru_size` are kept (or every one left is in use).
function M.evict()
  local order = {}
  for buf in pairs(kept) do
    if api.nvim_buf_is_valid(buf) then
      order[#order + 1] = buf
    else
      forget(buf)
    end
  end
  local excess = #order - config.get().buffers.lru_size
  if excess <= 0 then
    return
  end
  table.sort(order, function(a, b)
    return kept[a] < kept[b]
  end)
  for _, buf in ipairs(order) do
    if excess <= 0 then
      break
    end
    if not in_use[buf] and #vim.fn.win_findbuf(buf) == 0 then
      wipe(buf)
      excess = excess - 1
    end
  end
end

--- A scene is done with `buf`. A kept buffer no window shows is scrubbed and stays,
--- hidden, for the next `create` under its name; any other buffer is wiped. Idempotent,
--- and a no-op for a buffer already gone.
---@param buf integer
function M.release(buf)
  if not api.nvim_buf_is_valid(buf) then
    forget(buf)
    return
  end
  if not kept[buf] then
    pcall(api.nvim_buf_delete, buf, { force = true })
    return
  end
  if #vim.fn.win_findbuf(buf) > 0 then
    -- The caller left it on screen. Free to reuse once no window shows it; scrubbed then.
    in_use[buf] = nil
    return
  end
  in_use[buf] = nil
  scrub(buf)
  touch(buf)
  M.evict()
end

--- The kept buffers alive now, least recently used first. For tests and `:checkhealth`.
---@return integer[]
function M.kept()
  local order = {}
  for buf in pairs(kept) do
    if api.nvim_buf_is_valid(buf) then
      order[#order + 1] = buf
    end
  end
  table.sort(order, function(a, b)
    return kept[a] < kept[b]
  end)
  return order
end

return M
