--- The scroll and cursor corrector: keeps several panes showing the same view rows.
---
--- `scrollbind` cannot do this — it positions by buffer line and cannot express a top that
--- lands inside a filler block, and measured, it fights any corrector running beside it.
--- Instead each pane describes its own view rows (`render/rowmap.lua`), and on
--- `WinScrolled` the pane that moved is read with `winsaveview()` and every other pane is
--- put at the same view row with `winrestview{ topline, topfill }`, which round-trips
--- exactly against extmark virtual lines.
---
--- The cursor follows too. A pane that is not current keeps its cursor wherever it was,
--- and entering it would scroll it back to that cursor (and the corrector would then drag
--- the other pane along). So every other pane's cursor is kept on the counterpart of the
--- current pane's cursor line — the same view row, or the nearest line above it where the
--- other side is filler — clamped into what that pane shows, `scrolloff` included. Entering
--- a pane therefore never scrolls it.
---
--- Pane-count agnostic: the side-by-side layout gives it two panes, a three-way merge
--- layout can give it more.

local api = vim.api

local M = {}

--- Scroll keys mapped to themselves in every pane buffer, shadowing global remaps. Smooth
--- scrolling plugins animate these with `WinScrolled` in `eventignore`, so the corrector
--- never hears of the scroll and the other panes stay behind.
M.SCROLL_KEYS = { "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-e>", "<C-y>", "zt", "zz", "zb", "z<CR>", "z.", "z-" }

---@class NvimDiff.SyncPane
---@field win integer
--- View row at the top of the pane for a `winsaveview()` top; nil if the line is unknown.
---@field top_view fun(topline: integer, topfill: integer): integer?
--- The top that shows view row `v` first; nil when no top can.
---@field view_top fun(v: integer): integer?, integer?
--- View row of buffer line `lnum`.
---@field line_view fun(lnum: integer): integer?
--- The largest view row that can be at the top of the pane.
---@field max_top fun(): integer

---@class NvimDiff.ScrollSync
---@field panes NvimDiff.SyncPane[]
---@field private augroup integer
---@field private expected table<integer, string> Last view the corrector left each pane in.
---@field private paused integer
local Sync = {}
Sync.__index = Sync

---@param view vim.fn.winsaveview.ret
---@return string
local function key(view)
  return view.topline .. ":" .. view.topfill .. ":" .. view.leftcol
end

---@param win integer
---@return vim.fn.winsaveview.ret
local function save(win)
  return api.nvim_win_call(win, vim.fn.winsaveview)
end

---@param win integer
---@return integer?
function Sync:index_of(win)
  for i, p in ipairs(self.panes) do
    if p.win == win then
      return i
    end
  end
  return nil
end

--- The buffer line a pane's cursor goes to, given the view row of the current pane's
--- cursor line: that view row if it is a line here, else the nearest line above.
---@param pane NvimDiff.SyncPane
---@param v integer
---@return integer
local function line_for(pane, v)
  local tl, tf = pane.view_top(v)
  if not tl then
    return api.nvim_buf_line_count(api.nvim_win_get_buf(pane.win))
  end
  return tf > 0 and math.max(1, tl - 1) or tl
end

--- Move `pane`'s cursor to the counterpart of view row `cursor_v`, kept inside the rows its
--- view shows with `scrolloff` respected, so that entering the pane does not scroll it.
--- Runs inside `nvim_win_call(pane.win)`.
---@param pane NvimDiff.SyncPane
---@param view vim.fn.winsaveview.ret The pane's view, already moved.
---@param cursor_v integer
local function place_cursor(pane, view, cursor_v)
  local top = pane.top_view(view.topline, view.topfill)
  local lnum = line_for(pane, cursor_v)
  if top then
    local height = api.nvim_win_get_height(pane.win)
    local so = math.min(vim.fn.eval("&scrolloff"), math.floor((height - 1) / 2))
    local lo = top > 0 and top + so or 0
    local hi = top < pane.max_top() and top + height - 1 - so or math.huge
    local v = pane.line_view(lnum)
    if v and v < lo then
      local tl = pane.view_top(lo)
      if tl then
        lnum = tl
      end
    elseif v and v > hi then
      lnum = line_for(pane, hi)
    end
  end
  view.lnum = lnum
  view.col = 0
  view.curswant = 0
end

--- Bring every other pane to `src`'s view row, horizontal offset and cursor line.
---@param src integer Window to follow.
function Sync:sync(src)
  local si = self:index_of(src)
  if not si or self.paused > 0 then
    return
  end
  local sp = self.panes[si]
  local sv = save(src)
  local v = sp.top_view(sv.topline, sv.topfill)
  if not v then
    return
  end
  local cursor_v = sp.line_view(sv.lnum)
  self.expected[src] = key(sv)

  for i, dp in ipairs(self.panes) do
    if i ~= si and api.nvim_win_is_valid(dp.win) then
      local tl, tf = dp.view_top(v)
      if tl then
        api.nvim_win_call(dp.win, function()
          local dv = vim.fn.winsaveview()
          dv.topline, dv.topfill, dv.leftcol = tl, tf, sv.leftcol
          if cursor_v then
            place_cursor(dp, dv, cursor_v)
          end
          vim.fn.winrestview(dv)
        end)
        self.expected[dp.win] = key(save(dp.win))
      end
    end
  end
end

--- Move the other panes' cursors to the counterpart of `src`'s cursor line, without
--- scrolling anything.
---@param src integer
function Sync:sync_cursor(src)
  local si = self:index_of(src)
  if not si or self.paused > 0 then
    return
  end
  local cursor_v = self.panes[si].line_view(api.nvim_win_get_cursor(src)[1])
  if not cursor_v then
    return
  end
  for i, dp in ipairs(self.panes) do
    if i ~= si and api.nvim_win_is_valid(dp.win) then
      api.nvim_win_call(dp.win, function()
        local dv = vim.fn.winsaveview()
        place_cursor(dp, dv, cursor_v)
        vim.fn.winrestview(dv)
      end)
    end
  end
end

--- Which pane a `WinScrolled` was about: the current window if it is a pane that moved,
--- else a pane that moved to somewhere the corrector did not put it.
---@param event table `v:event`
---@return integer?
function Sync:source(event)
  local cur = api.nvim_get_current_win()
  if event[tostring(cur)] and self:index_of(cur) then
    return cur
  end
  for _, p in ipairs(self.panes) do
    if event[tostring(p.win)] and api.nvim_win_is_valid(p.win) and self.expected[p.win] ~= key(save(p.win)) then
      return p.win
    end
  end
  return nil
end

--- The pane to follow when nothing in particular moved: the current window if it is a
--- pane, else the first pane.
---@return integer?
function Sync:leader()
  local cur = api.nvim_get_current_win()
  if self:index_of(cur) then
    return cur
  end
  return self.panes[1] and self.panes[1].win
end

--- Resync from the leader. Call after anything that changes the view rows (virtual lines
--- added or removed, folds rebuilt).
function Sync:refresh()
  local leader = self:leader()
  if leader and api.nvim_win_is_valid(leader) then
    self:sync(leader)
  end
end

--- Run `fn` with the corrector off — for a caller that moves several panes itself (a fold
--- rebuild restoring both views). Afterwards the panes' views are taken as they are.
---@generic T
---@param fn fun(): T
---@return T
function Sync:pause(fn)
  self.paused = self.paused + 1
  local ok, result = pcall(fn)
  self.paused = self.paused - 1
  for _, p in ipairs(self.panes) do
    if api.nvim_win_is_valid(p.win) then
      self.expected[p.win] = key(save(p.win))
    end
  end
  if not ok then
    error(result, 0)
  end
  return result
end

--- Stop correcting. Idempotent.
function Sync:detach()
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

--- Start correcting `panes`.
---@param panes NvimDiff.SyncPane[]
---@return NvimDiff.ScrollSync
function M.attach(panes)
  local self = setmetatable({ panes = panes, expected = {}, paused = 0 }, Sync)
  self.augroup = api.nvim_create_augroup("nvim-diff.scrollsync." .. panes[1].win, { clear = true })

  api.nvim_create_autocmd("WinScrolled", {
    group = self.augroup,
    callback = function()
      local src = self:source(vim.v.event)
      if src then
        self:sync(src)
      end
    end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = self.augroup,
    callback = function()
      self:refresh()
    end,
  })
  for _, p in ipairs(panes) do
    local buf = api.nvim_win_get_buf(p.win)
    for _, lhs in ipairs(M.SCROLL_KEYS) do
      vim.keymap.set({ "n", "x" }, lhs, lhs, { buffer = buf, desc = "nvim-diff (scroll sync)" })
    end
    api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = api.nvim_win_get_buf(p.win),
      callback = function()
        self:sync_cursor(api.nvim_get_current_win())
      end,
    })
  end
  return self
end

return M
