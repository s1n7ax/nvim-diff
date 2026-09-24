--- Context folds in pane windows: turns a pair's fold list (`render/fold.lua`) into real
--- manual folds in each pane, and binds the fold keys to the pair's fold actions.
---
--- Folds are rebuilt, never edited: `zE`, then one `:fold` per fold. Both panes are always
--- rebuilt together from the one list, which is what keeps them mirrored. A rebuild resets
--- the window's view (measured in the rendering research), so callers restore it — the
--- pair does, under `sync:pause`.
---
--- The fold keys are intercepted, because a fold opened in one pane only breaks alignment
--- on the spot:
---
---   zo        reveal `step` (10) more lines, `[count]` times; the cursor stays on the band
---   zO zv     reveal the whole fold
---   za zA     on a band: reveal it whole; elsewhere: fold the context back up
---   zc zC     fold the context around the cursor back up
---   zR        reveal every fold          zM   fold everything back up
---   zx zX     reapply the current folds (they only undo manual changes)
---   zE zd zD zf zF zn zN zi               do nothing; they would unmirror the panes
---
--- Anything that opens a fold behind the plugin's back (a search, `foldopen` motions)
--- is caught on `CursorMoved` and turned into "reveal the whole fold" on both panes.

local fold = require("nvim-diff.render.fold")

local api = vim.api

local M = {}

--- Window options a folding pane needs on top of `scene/window.lua`'s. `fillchars` is
--- merged into the window's value, so the user's other fill characters survive.
---@param win integer
function M.setup_window(win)
  local function set(name, value)
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  set("foldenable", true)
  set("foldlevel", 0)
  set("foldtext", fold.FOLDTEXT)
  local fc = {}
  for item in vim.gsplit(api.nvim_get_option_value("fillchars", { win = win }), ",", { plain = true }) do
    if item ~= "" and not item:find("^fold:") then
      fc[#fc + 1] = item
    end
  end
  fc[#fc + 1] = "fold:" .. fold.FILL
  set("fillchars", table.concat(fc, ","))
end

--- Replace every fold in `side`'s pane with the pair's current folds, and register the
--- separator texts `foldtext` shows. Moves the view: callers restore it.
---@param pair NvimDiff.Pair
---@param side NvimDiff.Side
function M.apply(pair, side)
  local diff = pair.diff
  local lines = pair.lines[side]
  local texts = {}
  local cmds = {}
  for _, f in ipairs(pair.folds) do
    local a, b = fold.side_lines(diff, f, side)
    if a then
      local scope
      if f.kind == "context" then
        pair.scopes[side] = pair.scopes[side] or fold.scope_index(lines)
        scope = fold.scope_at(lines, pair.scopes[side], b)
      end
      -- Buffer line = file line + 1: the header is line 1.
      texts[a + 1] = { fold.label(diff, f, scope), fold.group(f) }
      cmds[#cmds + 1] = ("%d,%dfold"):format(a + 1, b + 1)
    end
  end
  fold.texts[pair.bufs[side]] = texts
  api.nvim_win_call(pair.wins[side], function()
    vim.cmd("silent! normal! zE")
    for _, c in ipairs(cmds) do
      vim.cmd(c)
    end
  end)
end

--- Forget a buffer's separator texts.
---@param buf integer
function M.forget(buf)
  fold.texts[buf] = nil
end

--- The side and file line under the cursor of the current window, when it is a pane.
---@param pair NvimDiff.Pair
---@return NvimDiff.Side?
---@return integer?
local function here(pair)
  local side = pair:side_of(api.nvim_get_current_win())
  if not side then
    return nil, nil
  end
  return side, pair:cursor_line(side)
end

--- Bind the fold keys in both panes, and catch folds opened behind the pair's back.
---@param pair NvimDiff.Pair
---@param augroup integer
function M.attach(pair, augroup)
  local function act(fn)
    return function()
      local side, lnum = here(pair)
      if side then
        fn(side, lnum)
      end
    end
  end
  local expand_step = act(function(side, lnum)
    if lnum then
      pair:expand(side, lnum, pair.fold_step * vim.v.count1)
    end
  end)
  local expand_whole = act(function(side, lnum)
    if lnum then
      pair:expand(side, lnum)
    end
  end)
  local toggle = act(function(side, lnum)
    if lnum and pair:fold_at(side, lnum) then
      pair:expand(side, lnum)
    elseif lnum then
      pair:collapse(side, lnum)
    end
  end)
  local collapse = act(function(side, lnum)
    if lnum then
      pair:collapse(side, lnum)
    end
  end)

  local maps = {
    zo = expand_step,
    zO = expand_whole,
    zv = expand_whole,
    za = toggle,
    zA = toggle,
    zc = collapse,
    zC = collapse,
    zR = function()
      pair:expand_all()
    end,
    zM = function()
      pair:collapse_all()
    end,
    zx = function()
      pair:set_folds(pair.folds)
    end,
  }
  maps.zX = maps.zx
  for _, side in ipairs({ "old", "new" }) do
    local buf = pair.bufs[side]
    for lhs, rhs in pairs(maps) do
      vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "nvim-diff: context folds" })
    end
    for _, lhs in ipairs({ "zE", "zd", "zD", "zf", "zF", "zn", "zN", "zi" }) do
      vim.keymap.set({ "n", "x" }, lhs, "<Nop>", { buffer = buf, desc = "nvim-diff: folds are mirrored" })
    end

    api.nvim_create_autocmd("CursorMoved", {
      group = augroup,
      buffer = buf,
      callback = function()
        local s, lnum = here(pair)
        if s and lnum and pair:fold_at(s, lnum) and vim.fn.foldclosed(lnum + 1) == -1 then
          pair:expand(s, lnum)
        end
      end,
    })
  end
end

return M
