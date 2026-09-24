--- A unified pane: one read-only window showing both sides of one diff, decorated by
--- `render/unified.lua`. The single-pane counterpart of `scene/pair.lua`, with the same
--- spec and the same block API, so a caller (the layout toggle, comment threads) can drive
--- either without caring which one is open. There is no scroll corrector: one pane has
--- nothing to stay aligned with.
---
---     local u = require("nvim-diff.scene.unified").open({
---       diff = require("nvim-diff.diff.line").diff(old_lines, new_lines),
---       old = { lines = old_lines, label = "a/lua/foo.lua" },
---       new = { lines = new_lines, label = "b/lua/foo.lua" },
---     })

local buffer = require("nvim-diff.scene.buffer")
local event = require("nvim-diff.core.event")
local hl = require("nvim-diff.ui.hl")
local sidebyside = require("nvim-diff.render.sidebyside")
local unified = require("nvim-diff.render.unified")
local window = require("nvim-diff.scene.window")

local api = vim.api

local M = {}

---@class NvimDiff.UnifiedSpec
---@field diff NvimDiff.Diff
---@field old NvimDiff.PairSide
---@field new NvimDiff.PairSide
---@field header? string Full header text; default `── <old label> → <new label> ──`.
---@field name? string Buffer name. Unnamed when omitted: the pair's per-blob names belong to the pair.
---@field win? integer Window to show the pane in. Omitted: a new tabpage.

---@class NvimDiff.Unified
---@field diff NvimDiff.Diff
---@field layout NvimDiff.UnifiedLayout
---@field buf integer
---@field win integer
---@field closed boolean
---@field private blocks table<any, NvimDiff.Block>
---@field private block_order any[]
---@field private augroup integer
---@field private virt { anchor: integer, lines: NvimDiff.VirtLine[] }[] The painted virtual rows.
local Unified = {}
Unified.__index = Unified

--- The default header of a unified pane.
---@param old_label string
---@param new_label string
---@return string
function M.header(old_label, new_label)
  if old_label == new_label then
    return sidebyside.header(old_label)
  end
  return sidebyside.header(old_label .. " → " .. new_label)
end

---@param spec NvimDiff.UnifiedSpec
---@return NvimDiff.Unified
function M.open(spec)
  hl.setup()
  local diff = spec.diff
  local layout = unified.layout(diff)
  local self = setmetatable({
    diff = diff,
    layout = layout,
    blocks = {},
    block_order = {},
    closed = false,
  }, Unified)

  self.buf = buffer.create({
    lines = unified.text(layout, spec.old.lines, spec.new.lines),
    header = spec.header or M.header(spec.old.label, spec.new.label),
    name = spec.name,
    lang = spec.new.lang or spec.old.lang,
  })

  local placeholder
  if spec.win then
    self.win = spec.win
  else
    vim.cmd("tabnew")
    self.win = api.nvim_get_current_win()
    placeholder = api.nvim_win_get_buf(self.win)
  end
  window.pane(self.win, self.buf, { statuscolumn = unified.statuscolumn(sidebyside.number_width(diff)) })
  api.nvim_win_set_cursor(self.win, { 1, 0 })
  if placeholder and api.nvim_buf_is_valid(placeholder) and api.nvim_buf_get_name(placeholder) == "" then
    pcall(api.nvim_buf_delete, placeholder, { force = true })
  end

  self.virt = unified.render(self.buf, layout)

  self.augroup = api.nvim_create_augroup("nvim-diff.unified." .. self.buf, { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.win),
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })

  event.emit_in({ win = self.win, buf = self.buf }, event.events.DIFF_BUF_READY, self.buf, {
    layout = "unified",
    unified = self,
  })
  return self
end

--- The side and file line under the cursor: `old` on a deleted line, `new` on an added or
--- unchanged one. Nil on the header.
---@return NvimDiff.Side?
---@return integer?
function Unified:cursor_pos()
  return unified.line_at(self.layout, api.nvim_win_get_cursor(self.win)[1])
end

--- The file line of `side` under the cursor: nil on the header, and on a line that only
--- exists on the other side.
---@param side NvimDiff.Side
---@return integer?
function Unified:cursor_line(side)
  local l = self.layout.lines[api.nvim_win_get_cursor(self.win)[1] - 1]
  return l and l[side]
end

--- Buffer line of `side`'s file line `lnum`, clamped into the file (the header when the
--- side is empty).
---@param side NvimDiff.Side
---@param lnum integer
---@return integer
function Unified:buf_line(side, lnum)
  local count = self.diff[side .. "_count"]
  if count == 0 then
    return 1
  end
  return unified.buf_line(self.layout, side, math.max(1, math.min(lnum, count)))
end

--- Put the cursor on `side`'s file line `lnum`, centred.
---@param side NvimDiff.Side
---@param lnum integer
function Unified:jump(side, lnum)
  api.nvim_win_set_cursor(self.win, { self:buf_line(side, lnum), 0 })
  api.nvim_win_call(self.win, function()
    vim.cmd("normal! zz")
  end)
end

--- Put the cursor on buffer line `bl` with the view scrolled so it sits on screen row
--- `winline` (1-based), as far as the file allows.
---@param bl integer
---@param winline integer
function Unified:place(bl, winline)
  local v = unified.line_view(self.virt, bl) - (winline - 1)
  local tl, tf = unified.view_top(self.virt, api.nvim_buf_line_count(self.buf), v)
  api.nvim_win_call(self.win, function()
    vim.fn.winrestview({ topline = tl, topfill = tf, lnum = bl, col = 0, curswant = 0 })
  end)
end

--- Repaint every virtual row from the current blocks.
function Unified:repaint_virt()
  local list = {}
  for _, id in ipairs(self.block_order) do
    list[#list + 1] = self.blocks[id]
  end
  self.virt = unified.paint_virt(self.buf, self.layout, list)
end

--- Insert (or replace) rows after display row `block.row`: `block.old` under the old line,
--- `block.new` under the new line. Same contract as `Pair:set_block`.
---@param id any
---@param block NvimDiff.Block
function Unified:set_block(id, block)
  if not self.blocks[id] then
    self.block_order[#self.block_order + 1] = id
  end
  self.blocks[id] = block
  self:repaint_virt()
end

--- Remove a block. No-op for an unknown id.
---@param id any
function Unified:remove_block(id)
  if not self.blocks[id] then
    return
  end
  self.blocks[id] = nil
  for i, x in ipairs(self.block_order) do
    if x == id then
      table.remove(self.block_order, i)
      break
    end
  end
  self:repaint_virt()
end

---@class NvimDiff.SceneCloseOpts
--- Leave this window open (the layout toggle reuses it). If it still shows the pane's
--- buffer, that is swapped for an empty scratch buffer first.
---@field keep? integer

--- Tear the pane down: close its window, wipe its buffer. Idempotent.
---@param opts? NvimDiff.SceneCloseOpts
function Unified:close(opts)
  if self.closed then
    return
  end
  self.closed = true
  local keep = opts and opts.keep
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  if api.nvim_win_is_valid(self.win) then
    api.nvim_set_option_value("winfixbuf", false, { win = self.win, scope = "local" })
    if self.win == keep then
      if api.nvim_win_get_buf(self.win) == self.buf then
        api.nvim_win_set_buf(self.win, window.scratch())
      end
    elseif not pcall(api.nvim_win_close, self.win, true) then
      api.nvim_win_set_buf(self.win, api.nvim_create_buf(true, false))
    end
  end
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

return M
