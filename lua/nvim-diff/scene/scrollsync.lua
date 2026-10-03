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
--- A pane cannot always have a view row at its top: Neovim keeps `topfill` below the window
--- height, so a top in the upper part of virtual rows taller than the window is out of
--- reach, and the top line cannot pass the last line, so virtual rows below it are too (a
--- real file's pane has no trailer line). Such a pane is *stopped*: put at the nearest top
--- it can have and, when the pane can (`park`, `scene/park.lua`), painted so it still shows
--- the view row. The panes scroll as far as the one that reaches furthest. A stopped pane
--- stands for the view row it was stopped at: it is followed only when it moved by itself
--- (a cursor motion, `zz`), and then read as it is. It gets a window-local `scrolloff=0`, or
--- Neovim would scroll it to keep lines around its cursor. Scroll keys and the mouse wheel
--- in a pane that cannot scroll that way (stopped, or at its own last line) scroll another
--- pane that can, and the corrector brings it along.
---
--- Pane-count agnostic: the side-by-side layout gives it two panes, a three-way merge
--- layout can give it more.

local api = vim.api

local M = {}

--- Scroll keys mapped in every pane buffer, shadowing global remaps. Smooth scrolling
--- plugins animate these with `WinScrolled` in `eventignore`, so the corrector never hears
--- of the scroll and the other panes stay behind.
M.SCROLL_KEYS = { "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-e>", "<C-y>", "zt", "zz", "zb", "z<CR>", "z.", "z-" }

--- The scroll keys a pane that cannot scroll hands on to another, and their direction.
local FORWARD = { ["<C-d>"] = 1, ["<C-u>"] = -1, ["<C-f>"] = 1, ["<C-b>"] = -1, ["<C-e>"] = 1, ["<C-y>"] = -1 }

--- The mouse wheel, as the scroll key it stands for (`page`: a screen at a time).
local WHEEL = {
  [vim.keycode("<ScrollWheelDown>")] = { lhs = "<C-e>" },
  [vim.keycode("<ScrollWheelUp>")] = { lhs = "<C-y>" },
  [vim.keycode("<S-ScrollWheelDown>")] = { lhs = "<C-f>", page = true },
  [vim.keycode("<S-ScrollWheelUp>")] = { lhs = "<C-b>", page = true },
  [vim.keycode("<C-ScrollWheelDown>")] = { lhs = "<C-f>", page = true },
  [vim.keycode("<C-ScrollWheelUp>")] = { lhs = "<C-b>", page = true },
}

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
--- Paint the pane so a window `height` rows tall shows view row `v` first, from the top
--- it returns, though no top shows it as painted; and the one buffer line on screen,
--- where the cursor must stay. Nil when it cannot.
---@field park? fun(v: integer, height: integer): integer?, integer?, integer?
--- Paint the pane as it is again, after `park`.
---@field unpark? fun()

--- A stopped pane.
---@class NvimDiff.SyncStop
---@field v integer The view row it stands for.
---@field top string `topline:topfill` it was left at.
---@field lnum? integer The line its cursor stays on, when parked.
---@field lead? boolean That line is at the bottom, below the rows (a run above line 1).
---@field so integer Its window-local 'scrolloff' before (-1: none).

---@class NvimDiff.ScrollSync
---@field panes NvimDiff.SyncPane[]
---@field stopped table<integer, NvimDiff.SyncStop> By window.
---@field private augroup integer
---@field private expected table<integer, string> Last view the corrector left each pane in.
---@field private paused integer
local Sync = {}
Sync.__index = Sync

--- Correctors attached, for the mouse wheel.
---@type table<NvimDiff.ScrollSync, true>
local live = {}
local wheel_ns = api.nvim_create_namespace("nvim-diff.scrollsync.wheel")

---@param view vim.fn.winsaveview.ret
---@return string
local function key(view)
  return view.topline .. ":" .. view.topfill .. ":" .. view.leftcol
end

---@param view vim.fn.winsaveview.ret
---@return string
local function top_key(view)
  return view.topline .. ":" .. view.topfill
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

--- The top that shows view row `v` first in `pane`, when the window can have it.
---@param pane NvimDiff.SyncPane
---@param v integer
---@return integer? topline
---@return integer? topfill
local function reach(pane, v)
  local tl, tf = pane.view_top(v)
  if tl and tf <= vim.fn.winheight(pane.win) - 1 then
    return tl, tf
  end
  return nil, nil
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
    -- Text rows only: `nvim_win_get_height` counts a winbar too.
    local height = vim.fn.winheight(pane.win)
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
    -- Where `scrolloff` asks for a line inside filler, the nearest one may be off screen:
    -- then the nearest on it (the top line always is).
    v = pane.line_view(lnum)
    if v and v > top + height - 1 then
      lnum = line_for(pane, top + height - 1)
    elseif v and v < top then
      lnum = view.topline
    end
  end
  view.lnum = lnum
  view.col = 0
  view.curswant = 0
end

--- The last view row a pane can show at its top: the largest any pane reaches as it is.
---@return integer
function Sync:limit()
  local limit = 0
  for _, p in ipairs(self.panes) do
    if api.nvim_win_is_valid(p.win) then
      limit = math.max(limit, p.max_top())
    end
  end
  return limit
end

--- `win`'s pane is no longer stopped: its 'scrolloff' and its rows as they are come back.
---@param win integer
function Sync:release(win)
  local stop = self.stopped[win]
  if not stop then
    return
  end
  self.stopped[win] = nil
  if api.nvim_win_is_valid(win) then
    api.nvim_set_option_value("scrolloff", stop.so, { win = win, scope = "local" })
  end
  local i = self:index_of(win)
  if i and self.panes[i].unpark then
    self.panes[i].unpark()
  end
end

--- `pane` cannot have view row `v` at its top: stop it at the nearest top it can have,
--- painted to show `v` when it can be (`park`). Returns that top, and the line the cursor
--- stays on when parked. Runs inside `nvim_win_call(pane.win)`.
---@param pane NvimDiff.SyncPane
---@param v integer
---@return integer topline
---@return integer topfill
---@return integer? lnum
function Sync:stop(pane, v)
  local height = vim.fn.winheight(pane.win)
  local tl, tf, lnum
  if pane.park then
    tl, tf, lnum = pane.park(v, height)
  end
  if not tl then
    tl, tf = pane.view_top(v)
    if tl then
      tf = math.min(tf, height - 1)
    else
      tl, tf = pane.view_top(pane.max_top())
    end
  end
  local stop = self.stopped[pane.win]
  if not stop then
    stop = { so = api.nvim_get_option_value("scrolloff", { win = pane.win, scope = "local" }) }
    api.nvim_set_option_value("scrolloff", 0, { win = pane.win, scope = "local" })
    self.stopped[pane.win] = stop
  end
  stop.v, stop.lnum, stop.lead = v, lnum, lnum ~= nil and (tf or 0) > 0
  return tl or 1, tf or 0, lnum
end

--- Put `pane` at view row `v` — at the top that shows it, else stopped — with its cursor on
--- `lnum` when given, else on the counterpart of view row `cursor_v` when given, and its
--- horizontal offset at `leftcol` when given.
---@param pane NvimDiff.SyncPane
---@param v integer
---@param cursor_v? integer
---@param leftcol? integer
---@param lnum? integer
function Sync:place(pane, v, cursor_v, leftcol, lnum)
  local win = pane.win
  local tl, tf = reach(pane, v)
  if tl then
    self:release(win)
  end
  api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local hidden
    if not tl then
      tl, tf, hidden = self:stop(pane, v)
    end
    view.topline, view.topfill = tl, tf
    -- Neovim may have left a sideways skip of a tall `topfill` there (after a resize), which
    -- draws `<<<` over the top row.
    view.skipcol = 0
    if leftcol then
      view.leftcol = leftcol
    end
    lnum = hidden or lnum
    if lnum then
      view.lnum, view.col, view.curswant = lnum, 0, 0
    elseif cursor_v then
      place_cursor(pane, view, cursor_v)
    end
    vim.fn.winrestview(view)
  end)
  local now = save(win)
  if self.stopped[win] then
    self.stopped[win].top = top_key(now)
  end
  self.expected[win] = key(now)
end

--- The view row at the top of `pane`, its view, and whether it is stopped. A stopped pane
--- stands for its view row while it stays where it was put; one that moved by itself is
--- read as it is.
---@param pane NvimDiff.SyncPane
---@return integer?
---@return vim.fn.winsaveview.ret
---@return boolean stopped
function Sync:view_row(pane)
  local view = save(pane.win)
  local stop = self.stopped[pane.win]
  if not (stop and stop.top == top_key(view)) then
    return pane.top_view(view.topline, view.topfill), view, false
  end
  local v = stop.v
  -- The rows may have changed since (a thread taken away from around it): the view row
  -- stays inside the run of virtual rows its one line bounds.
  local lv = stop.lnum and pane.line_view(stop.lnum)
  if lv and stop.lead then
    v = math.min(v, lv)
  elseif lv then
    v = math.max(v, lv)
    local next_v = pane.line_view(stop.lnum + 1)
    if next_v then
      v = math.min(v, next_v)
    end
  end
  return v, view, true
end

--- `view_row`, a pane that moved by itself no longer stopped.
---@param pane NvimDiff.SyncPane
---@return integer?
---@return vim.fn.winsaveview.ret
function Sync:top_of(pane)
  local v, view, stopped = self:view_row(pane)
  if not stopped then
    self:release(pane.win)
  end
  return v, view
end

--- Bring every other pane to `src`'s view row, horizontal offset and cursor line. A
--- stopped `src` is painted again for its view row too (the rows may have changed).
---@param src integer Window to follow.
function Sync:sync(src)
  local si = self:index_of(src)
  if not si or self.paused > 0 then
    return
  end
  local sp = self.panes[si]
  local v, sv = self:top_of(sp)
  if not v then
    return
  end
  local cursor_v = sp.line_view(sv.lnum)
  if self.stopped[src] then
    self:place(sp, v, cursor_v, sv.leftcol)
  else
    self.expected[src] = key(sv)
  end
  for i, dp in ipairs(self.panes) do
    if i ~= si and api.nvim_win_is_valid(dp.win) then
      self:place(dp, v, cursor_v, sv.leftcol)
    end
  end
end

--- Put every pane at view row `v` (within what they reach): `win`'s cursor on `lnum` when
--- given, else on the line at `v`, and the others' on its counterpart.
---@param v integer
---@param win integer
---@param lnum? integer
function Sync:show(v, win, lnum)
  local si = self:index_of(win)
  if not si or self.paused > 0 then
    return
  end
  v = math.max(0, math.min(v, self:limit()))
  local lead = self.panes[si]
  self:place(lead, v, v, nil, lnum)
  local cursor_v = lead.line_view(api.nvim_win_get_cursor(win)[1])
  for i, p in ipairs(self.panes) do
    if i ~= si and api.nvim_win_is_valid(p.win) then
      self:place(p, v, cursor_v)
    end
  end
end

--- Move the other panes' cursors to the counterpart of `src`'s cursor line, without
--- scrolling anything. A stopped pane's cursor stays on its one line.
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
    if i ~= si and api.nvim_win_is_valid(dp.win) and not self.stopped[dp.win] then
      api.nvim_win_call(dp.win, function()
        local dv = vim.fn.winsaveview()
        place_cursor(dp, dv, cursor_v)
        vim.fn.winrestview(dv)
      end)
    end
  end
end

--- Whether `win`'s pane cannot scroll `dir` rows (1: down, -1: up) though the panes can:
--- it is stopped, or the next view row is out of its reach (its last line is at the top,
--- or `topfill` is at its cap).
---@param win integer
---@param dir integer
---@return boolean
---@return integer? v The view row at its top.
function Sync:blocked(win, dir)
  local i = self:index_of(win)
  if not i or self.paused > 0 then
    return false
  end
  local pane = self.panes[i]
  local v, _, stopped = self:view_row(pane)
  if not v or v + dir < 0 or v + dir > self:limit() then
    return false
  end
  return stopped or reach(pane, v + dir) == nil, v
end

--- Rows scroll key `lhs` moves window `win` by, signed.
---@param lhs string
---@param count integer
---@param win integer
---@return integer
local function rows_of(lhs, count, win)
  local height = vim.fn.winheight(win)
  local n
  if lhs == "<C-e>" or lhs == "<C-y>" then
    n = math.max(count, 1)
  elseif lhs == "<C-d>" or lhs == "<C-u>" then
    n = count > 0 and count or vim.wo[win].scroll
    if n <= 0 then
      n = math.floor(height / 2)
    end
  else
    n = math.max(1, height - 2) * math.max(count, 1)
  end
  return n * FORWARD[lhs]
end

--- A scroll key (`FORWARD`) in `win`'s pane, with `count`. False when the pane can scroll
--- that way: the key is the caller's to run. Otherwise the first other pane that can runs
--- it and the corrector brings `win` along; when none can (every pane stopped inside one
--- tall run), or in Visual mode (which belongs to `win`), the view row moves by what the key
--- would scroll.
---@param win integer
---@param lhs string
---@param count integer
---@return boolean
function Sync:forward(win, lhs, count)
  local dir = FORWARD[lhs]
  local blocked, v = self:blocked(win, dir)
  if not blocked or not v then
    return false
  end
  local visual = api.nvim_get_mode().mode:find("^[vV\22]") ~= nil
  for _, p in ipairs(self.panes) do
    if
      not visual
      and p.win ~= win
      and api.nvim_win_is_valid(p.win)
      and not self.stopped[p.win]
      and reach(p, v + dir)
    then
      api.nvim_win_call(p.win, function()
        vim.cmd("normal! " .. (count > 0 and count or "") .. vim.keycode(lhs))
      end)
      self:sync(p.win)
      return true
    end
  end
  self:show(v + rows_of(lhs, count, win), win)
  return true
end

--- Which pane a `WinScrolled` was about: the current window if it is a pane that moved,
--- else a pane that moved to somewhere the corrector did not put it. A current pane the
--- corrector itself moved (`gg` leading with the other pane, a stop) is not the source:
--- where it could not follow exactly, it would drag the others to where it stopped.
---@param event table `v:event`
---@return integer?
function Sync:source(event)
  local cur = api.nvim_get_current_win()
  if event[tostring(cur)] and self:index_of(cur) and self.expected[cur] ~= key(save(cur)) then
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
--- pane, else the first pane — passing over a stopped pane, whose top says only how near it
--- got (another pane may rightly be elsewhere).
---@return integer?
function Sync:leader()
  local cur = api.nvim_get_current_win()
  local order = {}
  if self:index_of(cur) then
    order[1] = self.panes[self:index_of(cur)]
  end
  for _, p in ipairs(self.panes) do
    if p.win ~= cur then
      order[#order + 1] = p
    end
  end
  for _, p in ipairs(order) do
    if api.nvim_win_is_valid(p.win) and not self.stopped[p.win] then
      return p.win
    end
  end
  return order[1] and order[1].win
end

--- Resync from the leader. Call after anything that changes the view rows (virtual lines
--- added or removed, folds rebuilt) or the windows' size.
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

--- The mouse wheel over a pane that cannot scroll that way scrolls another (`forward`);
--- the wheel key itself is dropped. Whatever window is current.
---@param wheel { lhs: string, page?: boolean }
---@return string?
local function on_wheel(wheel)
  local count = 1
  if not wheel.page then
    count = tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3
    if count == 0 then
      return nil
    end
  end
  local win = vim.fn.getmousepos().winid
  for sync in pairs(live) do
    if sync:blocked(win, FORWARD[wheel.lhs]) then
      vim.schedule(function()
        if live[sync] and api.nvim_win_is_valid(win) then
          sync:forward(win, wheel.lhs, count)
        end
      end)
      return ""
    end
  end
  return nil
end

---@param k string
---@param typed string
---@return string?
local function on_key(k, typed)
  local wheel = WHEEL[k] or WHEEL[typed]
  if not wheel then
    return nil
  end
  -- An error would take the listener away for good.
  local ok, out = pcall(on_wheel, wheel)
  return ok and out or nil
end

--- Stop correcting; stopped panes get their 'scrolloff' back (their owner paints them as it
--- closes). Idempotent.
function Sync:detach()
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for win, stop in pairs(self.stopped) do
    if api.nvim_win_is_valid(win) then
      api.nvim_set_option_value("scrolloff", stop.so, { win = win, scope = "local" })
    end
  end
  self.stopped = {}
  live[self] = nil
  if next(live) == nil then
    vim.on_key(nil, wheel_ns)
  end
end

--- Map the scroll keys in `buf`: `FORWARD` ones handed on when its pane cannot scroll that
--- way, the rest to themselves.
---@param buf integer
function Sync:map_keys(buf)
  for _, lhs in ipairs(M.SCROLL_KEYS) do
    local rhs = lhs
    if FORWARD[lhs] then
      rhs = function()
        local count = vim.v.count
        if not self:forward(api.nvim_get_current_win(), lhs, count) then
          api.nvim_feedkeys(vim.keycode((count > 0 and count or "") .. lhs), "ni", false)
        end
      end
    end
    vim.keymap.set({ "n", "x" }, lhs, rhs, { buffer = buf, desc = "nvim-diff (scroll sync)" })
  end
end

--- Start correcting `panes`.
---@param panes NvimDiff.SyncPane[]
---@return NvimDiff.ScrollSync
function M.attach(panes)
  local self = setmetatable({ panes = panes, expected = {}, paused = 0, stopped = {} }, Sync)
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
    self:map_keys(buf)
    api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = buf,
      callback = function()
        self:sync_cursor(api.nvim_get_current_win())
      end,
    })
  end
  if next(live) == nil then
    vim.on_key(on_key, wheel_ns)
  end
  live[self] = true
  return self
end

return M
