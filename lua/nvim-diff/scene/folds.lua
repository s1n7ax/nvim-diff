--- Context folds in pane windows: turns a scene's fold list (`render/fold.lua`) into real
--- manual folds in each of its panes, and binds the fold keys to the scene's fold actions.
--- A scene is a side-by-side pair (`scene/pair.lua`) or a unified pane
--- (`scene/unified.lua`); both carry the same fold list and the same fold methods
--- (`NvimDiff.FoldScene`), so the keys behave the same in either layout.
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

--- Window options a folding pane needs on top of `scene/window.lua`'s. `foldtext` and
--- `fillchars` are left alone: a closed fold reads as the user's own folds do, whether
--- Neovim or a fold plugin draws it.
---@param win integer
function M.setup_window(win)
  local function set(name, value)
    api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  set("foldenable", true)
  set("foldlevel", 0)
end

--- One closed fold of a window: buffer lines `first..last`.
---@class NvimDiff.FoldLines
---@field first integer
---@field last integer

--- Replace every fold of `win` with `list`. Moves the view: callers restore it.
---@param win integer
---@param list NvimDiff.FoldLines[]
function M.build(win, list)
  api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    for _, l in ipairs(list) do
      vim.cmd(("%d,%dfold"):format(l.first, l.last))
    end
  end)
end

--- Replace every fold in `side`'s pane with the pair's current folds. Moves the view:
--- callers restore it.
---@param pair NvimDiff.Pair
---@param side NvimDiff.Side
function M.apply(pair, side)
  local diff = pair.diff
  local list = {}
  for _, f in ipairs(pair.folds) do
    local a, b = fold.side_lines(diff, f, side)
    if a and b then
      list[#list + 1] = { first = pair:buf_line(a), last = pair:buf_line(b) }
    end
  end
  M.build(pair.wins[side], list)
end

--- What the fold keys need from a scene.
---@class NvimDiff.FoldScene
---@field folds NvimDiff.Fold[]
---@field fold_step integer
--- The side and file line under the cursor of the current window, when it is one of the
--- scene's.
---@field fold_cursor fun(self): NvimDiff.Side?, integer?
---@field fold_at fun(self, side: NvimDiff.Side, lnum: integer): NvimDiff.Fold?, integer?
---@field expand fun(self, side: NvimDiff.Side, lnum: integer, n?: integer, dir?: NvimDiff.FoldDir): boolean
---@field expand_all fun(self)
---@field collapse fun(self, side: NvimDiff.Side, lnum: integer): boolean
---@field collapse_all fun(self)
---@field set_folds fun(self, list: NvimDiff.Fold[])

--- Bind the fold keys in the scene's buffers, and catch folds opened behind its back.
---@param scene NvimDiff.FoldScene
---@param bufs integer[]
---@param augroup integer
function M.attach(scene, bufs, augroup)
  local function act(fn)
    return function()
      local side, lnum = scene:fold_cursor()
      if side then
        fn(side, lnum)
      end
    end
  end
  local expand_step = act(function(side, lnum)
    if lnum then
      scene:expand(side, lnum, scene.fold_step * vim.v.count1)
    end
  end)
  local expand_whole = act(function(side, lnum)
    if lnum then
      scene:expand(side, lnum)
    end
  end)
  local toggle = act(function(side, lnum)
    if lnum and scene:fold_at(side, lnum) then
      scene:expand(side, lnum)
    elseif lnum then
      scene:collapse(side, lnum)
    end
  end)
  local collapse = act(function(side, lnum)
    if lnum then
      scene:collapse(side, lnum)
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
      scene:expand_all()
    end,
    zM = function()
      scene:collapse_all()
    end,
    zx = function()
      scene:set_folds(scene.folds)
    end,
  }
  maps.zX = maps.zx
  local descs = {
    zo = "Expand one step",
    zO = "Expand whole fold",
    zv = "Expand whole fold",
    za = "Toggle fold",
    zA = "Toggle fold",
    zc = "Collapse fold",
    zC = "Collapse fold",
    zR = "Expand all",
    zM = "Collapse all",
    zx = "Reset folds",
    zX = "Reset folds",
  }
  for _, buf in ipairs(bufs) do
    for lhs, rhs in pairs(maps) do
      vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = "nvim-diff: Folds: " .. descs[lhs] })
    end
    for _, lhs in ipairs({ "zE", "zd", "zD", "zf", "zF", "zn", "zN", "zi" }) do
      vim.keymap.set({ "n", "x" }, lhs, "<Nop>", { buffer = buf, desc = "nvim-diff: folds are mirrored" })
    end

    api.nvim_create_autocmd("CursorMoved", {
      group = augroup,
      buffer = buf,
      callback = function()
        local s, lnum = scene:fold_cursor()
        if s and lnum and scene:fold_at(s, lnum) and vim.fn.foldclosed(".") == -1 then
          scene:expand(s, lnum)
        end
      end,
    })
  end
end

return M
