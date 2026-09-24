--- The plugin's own highlight groups.
---
--- The built-in `DiffAdd`/`DiffChange`/`DiffText`/`DiffDelete` groups are never used: the
--- plugin renders with diff mode off and owns every colour it draws, so no colorscheme can
--- make its diff colours collide with its fold colours.
---
--- Two layers:
---   * global groups defined with `default = true`, which is the user's override surface —
---     a colorscheme that already defines `NvimDiffAddLine` keeps it. They do not survive
---     `:colorscheme`, hence the autocommand.
---   * a private namespace, bound to plugin windows with `nvim_win_set_hl_ns`, holding the
---     remaps that must not leak into other windows (`Folded` is the separator band).
---     A namespace survives both `:colorscheme` and `:hi clear`, and falls back to the
---     global namespace for every group it does not define.
---
--- Diff groups set `bg` only, never `fg`, so treesitter's syntax colours survive inside a
--- changed token.

local api = vim.api

local M = {}

--- The namespace plugin windows are bound to.
M.ns = api.nvim_create_namespace("nvim-diff")

---@alias NvimDiff.HlSpec { dark: vim.api.keyset.highlight, light: vim.api.keyset.highlight }

--- Group name to its dark and light definition. Every group the plugin draws is here, so
--- `:h nvim-diff-highlights` can be generated from it and a user can override any of them
--- through `highlights` in the config.
---@type table<string, NvimDiff.HlSpec>
M.groups = {
  -- A changed line, coloured by side: red on the left, green on the right.
  NvimDiffDelLine = { dark = { bg = "#3a1418" }, light = { bg = "#f7dadd" } },
  NvimDiffAddLine = { dark = { bg = "#14301a" }, light = { bg = "#d7f5dd" } },
  -- The changed tokens inside it, brighter. Drawn above treesitter, so background only.
  NvimDiffDelToken = { dark = { bg = "#7a2129" }, light = { bg = "#f0aeb5" } },
  NvimDiffAddToken = { dark = { bg = "#2f6f2f" }, light = { bg = "#a6e8b5" } },

  -- The steel band: pale text on dark blue, filled to the window edge. Loud enough to be a
  -- landmark, calmer than amber.
  NvimDiffContextSeparator = {
    dark = { fg = "#c9d8e8", bg = "#1c3a5e", bold = true },
    light = { fg = "#f2f6fa", bg = "#2f5f93", bold = true },
  },
  -- A collapsed reformat reads as the same kind of landmark.
  NvimDiffReformatSeparator = {
    dark = { link = "NvimDiffContextSeparator" },
    light = { link = "NvimDiffContextSeparator" },
  },

  -- Filler: a line exists on the other side that is missing here. Distinct from the blank
  -- padding opposite a comment thread, which carries no mark at all.
  NvimDiffFiller = { dark = { fg = "#3b4048" }, light = { fg = "#c4c9d2" } },

  -- The mandatory header at buffer line 1 of every pane.
  NvimDiffHeader = {
    dark = { fg = "#8a94a6", bg = "#20242c", bold = true },
    light = { fg = "#4a5262", bg = "#e6e9ee", bold = true },
  },

  -- Comment threads, rendered as virtual lines under the commented row.
  NvimDiffThreadBar = { dark = { fg = "#5f87d7" }, light = { fg = "#3060b0" } },
  NvimDiffThreadAuthor = { dark = { bold = true }, light = { bold = true } },
  NvimDiffThreadBody = { dark = { link = "Normal" }, light = { link = "Normal" } },
  NvimDiffThreadMeta = { dark = { link = "Comment" }, light = { link = "Comment" } },
  NvimDiffThreadResolved = { dark = { link = "Comment" }, light = { link = "Comment" } },

  -- The file panel.
  NvimDiffPanelTitle = { dark = { link = "Title" }, light = { link = "Title" } },
  NvimDiffPanelDir = { dark = { link = "Directory" }, light = { link = "Directory" } },
  NvimDiffPanelPath = { dark = { link = "Normal" }, light = { link = "Normal" } },
  NvimDiffPanelInsertions = { dark = { fg = "#79c07c" }, light = { fg = "#2e7d32" } },
  NvimDiffPanelDeletions = { dark = { fg = "#d97b84" }, light = { fg = "#b3261e" } },
  NvimDiffPanelViewed = { dark = { link = "Comment" }, light = { link = "Comment" } },
  NvimDiffPanelRechanged = { dark = { fg = "#d7af5f" }, light = { fg = "#8a6d1f" } },
  NvimDiffPanelDeferred = { dark = { link = "Comment" }, light = { link = "Comment" } },
  -- A renamed file's old path, after the new one.
  NvimDiffPanelOldPath = { dark = { link = "Comment" }, light = { link = "Comment" } },
  -- The file showing in the diff.
  NvimDiffPanelSelected = { dark = { link = "Visual" }, light = { link = "Visual" } },
  -- The status letter: added (and copied, untracked), modified (and renamed, type change),
  -- deleted, conflicted.
  NvimDiffPanelStatusAdded = {
    dark = { link = "NvimDiffPanelInsertions" },
    light = { link = "NvimDiffPanelInsertions" },
  },
  NvimDiffPanelStatusModified = { dark = { fg = "#7aa2d6" }, light = { fg = "#2f5f93" } },
  NvimDiffPanelStatusDeleted = {
    dark = { link = "NvimDiffPanelDeletions" },
    light = { link = "NvimDiffPanelDeletions" },
  },
  NvimDiffPanelStatusConflicted = { dark = { link = "WarningMsg" }, light = { link = "WarningMsg" } },

  -- The history panel: a commit's abbreviated id, date and author, the row marking where a
  -- followed file was renamed, and a failed walk.
  NvimDiffHistoryHash = { dark = { link = "Identifier" }, light = { link = "Identifier" } },
  NvimDiffHistoryDate = { dark = { link = "Comment" }, light = { link = "Comment" } },
  NvimDiffHistoryAuthor = { dark = { link = "Comment" }, light = { link = "Comment" } },
  NvimDiffHistoryRename = {
    dark = { link = "NvimDiffPanelRechanged" },
    light = { link = "NvimDiffPanelRechanged" },
  },
  NvimDiffHistoryError = { dark = { link = "ErrorMsg" }, light = { link = "ErrorMsg" } },
}

--- Namespace-local remaps. These exist only inside plugin windows.
---@type table<string, string>
local REMAPS = {
  Folded = "NvimDiffContextSeparator",
}

local augroup = nil

--- Define every group, then apply the user's `highlights` overrides on top.
--- Idempotent: safe to call on every `ColorScheme`.
function M.define()
  local variant = vim.o.background == "dark" and "dark" or "light"
  for name, spec in pairs(M.groups) do
    local attrs = vim.tbl_extend("force", spec[variant], { default = true })
    api.nvim_set_hl(0, name, attrs)
  end

  -- The user wins over the shipped default, so these go in without `default`.
  for name, override in pairs(require("nvim-diff.config").get().highlights) do
    api.nvim_set_hl(0, name, type(override) == "string" and { link = override } or override)
  end

  for from, to in pairs(REMAPS) do
    api.nvim_set_hl(M.ns, from, { link = to })
  end
end

--- Define the groups and keep them defined across `:colorscheme` and `background` changes.
--- Idempotent.
function M.setup()
  M.define()
  if augroup then
    return
  end
  augroup = api.nvim_create_augroup("nvim-diff.hl", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = M.define,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = "background",
    callback = M.define,
  })
end

--- Bind a plugin window to the private namespace.
---@param win integer
function M.apply_window(win)
  api.nvim_win_set_hl_ns(win, M.ns)
end

return M
