--- Defaults, user-option merging and validation.
---
--- Validation runs against a hand-written spec rather than against the defaults, so an
--- option may be valid without having a default (`github.host`). Every problem in a user
--- table is collected and reported in one message: an option that is misspelled or of the
--- wrong type fails here, at `setup()`, not fifteen modules deeper.

local M = {}

---@class NvimDiff.Config.Diff
---@field structural boolean Structural (treesitter) diff is the default view.
---@field algorithm "myers"|"minimal"|"patience"|"histogram" Passed to `vim.text.diff`.
---@field normalize_comment_whitespace boolean Rewrapping a comment is a formatting change.

---@class NvimDiff.Config.Revs
---@field merge_base boolean Branch diff means `a...b` (merge-base) rather than `a..b`.

---@class NvimDiff.Config.Thresholds
---@field defer_lines integer Above this line count a file is listed but not loaded.
---@field structural_lines integer Above this line count per side, structural falls back to line diff.
---@field panel_entries integer Above this many changed files the panel shows a summary.

---@class NvimDiff.Config.Buffers
--- Diff buffers of blobs at a commit kept after their view moves on, for reuse; beyond
--- this, the least recently used one not on screen is wiped. `0` keeps none.
---@field lru_size integer

---@class NvimDiff.Config.Git
---@field bin string
---@field timeout_ms integer

---@class NvimDiff.Config.GitHub
---@field bin string
---@field timeout_ms integer
---@field host? string GitHub Enterprise host; resolved from the remote when unset.

--- Keys of the layout toggle, buffer-local to diff panes. `false` disables a key.
---@class NvimDiff.Config.LayoutKeymaps
---@field toggle string|false Flip the current file between side-by-side and unified.
---@field toggle_structural string|false Flip the current file between structural and line diff.

---@class NvimDiff.Config.Log
---@field level "trace"|"debug"|"info"|"warn"|"error"|"off"

---@class NvimDiff.Config.Panel
---@field listing "tree"|"flat" How the file panel groups files; toggled per view.
---@field width integer Columns.

---@class NvimDiff.Config.History
---@field follow boolean A single file's history follows it across renames.
---@field height integer Rows of the commit panel, which sits under the diff.

--- A key in `{lhs}` notation, or `false` for no mapping.
---@alias NvimDiff.Config.Key string|false

---@class NvimDiff.Config.PanelKeymaps
--- Open the file under the cursor (on a deferred file already showing its note: load it),
--- or fold/unfold the directory under it.
---@field select NvimDiff.Config.Key
---@field toggle_listing NvimDiff.Config.Key Switch between tree and flat.
---@field refresh NvimDiff.Config.Key Re-list the files.

---@class NvimDiff.Config.ViewKeymaps
--- In the panel and in the diff panes; also in a conflict view's four windows, where it
--- steps across just the conflicted files rather than every entry.
---@field next_file NvimDiff.Config.Key
---@field prev_file NvimDiff.Config.Key
--- Flip a branch diff between merge-base (`a...b`) and tip-to-tip (`a..b`).
---@field toggle_range NvimDiff.Config.Key
--- History of the line under the cursor (`git log -L`), from a diff pane.
---@field line_history NvimDiff.Config.Key

---@class NvimDiff.Config.HistoryKeymaps
--- Mark the commit under the panel's cursor for range compare. A third mark drops the
--- oldest: marks are a ring of at most two.
---@field mark NvimDiff.Config.Key
--- Diff the two marked commits, older against newer, in a new tabpage.
---@field compare NvimDiff.Config.Key

--- Buffer-local to the four windows of a merge conflict view. The take keys act on the
--- conflict under the result's cursor.
---@class NvimDiff.Config.ConflictKeymaps
---@field take_ours NvimDiff.Config.Key
---@field take_base NvimDiff.Config.Key
---@field take_theirs NvimDiff.Config.Key
---@field take_both NvimDiff.Config.Key Ours, then theirs.
---@field take_none NvimDiff.Config.Key Delete the conflict.
---@field next_conflict NvimDiff.Config.Key
---@field prev_conflict NvimDiff.Config.Key

--- Buffer-local to the file panel and every pane of a PR review. They act on the file row
--- under the panel's cursor, else on the file showing.
---@class NvimDiff.Config.ReviewKeymaps
--- Mark the file viewed on GitHub, then jump to the next file not viewed.
---@field mark_viewed NvimDiff.Config.Key
--- Clear the file's viewed mark on GitHub.
---@field unmark_viewed NvimDiff.Config.Key

--- Buffer-local to the diff panes of a view showing PR review comment threads.
---@class NvimDiff.Config.ThreadKeymaps
--- Expand the threads under the cursor's line in place, or collapse them. On a line with
--- no thread the key does what it would otherwise do.
---@field toggle NvimDiff.Config.Key
---@field next NvimDiff.Config.Key Cursor to the next thread's line, wrapping.
---@field prev NvimDiff.Config.Key
---@field toggle_resolved NvimDiff.Config.Key Flip resolved threads between dimmed and hidden.
---@field list NvimDiff.Config.Key Open or close the side list of outdated and file-level comments.
--- In a PR review only, on the thread on the cursor's line: resolve it on GitHub at once.
---@field resolve NvimDiff.Config.Key
--- Open the comment split for a reply; posting it resolves the thread too.
---@field reply_resolve NvimDiff.Config.Key
--- Unresolve the resolved thread on the cursor's line.
---@field unresolve NvimDiff.Config.Key

--- Buffer-local to the review verdict split (`:NvimDiffVerdict`), in normal and insert mode.
---@class NvimDiff.Config.VerdictKeymaps
--- Submit the verdict and summary to GitHub.
---@field post NvimDiff.Config.Key
--- Close the split; asks first when a summary was typed.
---@field cancel NvimDiff.Config.Key

---@class NvimDiff.Config.Threads
--- What a resolved thread looks like until toggled: drawn dimmed with a ✓, or not at all.
---@field resolved "dim"|"hide"

--- `add`, `reply`, `edit` and `delete` are buffer-local to the diff panes of a PR review;
--- `submit`, `cancel` and `suggest` to the comment split, in normal and insert mode. `:w` in
--- the split posts too.
---@class NvimDiff.Config.CommentKeymaps
--- New comment on the cursor's line of the pane it is in (old or new); in visual mode, on
--- the selected lines; in the file panel, a file-level comment on the file under the cursor.
---@field add NvimDiff.Config.Key
--- Reply to the thread on the cursor's line.
---@field reply NvimDiff.Config.Key
--- Edit your comment in the thread on the cursor's line (also in the side list).
---@field edit NvimDiff.Config.Key
--- Delete your comment in the thread on the cursor's line, after asking (also in the side list).
---@field delete NvimDiff.Config.Key
---@field submit NvimDiff.Config.Key Post what the split holds.
--- Close the split; asks first when it holds text.
---@field cancel NvimDiff.Config.Key
--- Insert a ```` ```suggestion ```` block holding the commented lines as they are.
---@field suggest NvimDiff.Config.Key

---@class NvimDiff.Config.Comment
---@field height integer Rows of the comment split.

---@class NvimDiff.Config.Keymaps
---@field review NvimDiff.Config.ReviewKeymaps
---@field panel NvimDiff.Config.PanelKeymaps Buffer-local to the file panel.
---@field view NvimDiff.Config.ViewKeymaps Buffer-local to the file panel and every pane of a view.
---@field history NvimDiff.Config.HistoryKeymaps Buffer-local to the history panel.
---@field conflict NvimDiff.Config.ConflictKeymaps
---@field threads NvimDiff.Config.ThreadKeymaps
---@field comment NvimDiff.Config.CommentKeymaps
---@field verdict NvimDiff.Config.VerdictKeymaps

---@class NvimDiff.Config
---@field layout "side_by_side"|"unified"
---@field layout_keymaps NvimDiff.Config.LayoutKeymaps
---@field diff NvimDiff.Config.Diff
---@field revs NvimDiff.Config.Revs
---@field thresholds NvimDiff.Config.Thresholds
---@field buffers NvimDiff.Config.Buffers
---@field git NvimDiff.Config.Git
---@field github NvimDiff.Config.GitHub
---@field highlights table<string, vim.api.keyset.highlight|string> Group name to attributes, or to a group to link to.
---@field log NvimDiff.Config.Log
---@field panel NvimDiff.Config.Panel
---@field history NvimDiff.Config.History
---@field threads NvimDiff.Config.Threads
---@field comment NvimDiff.Config.Comment
---@field keymaps NvimDiff.Config.Keymaps

---@type NvimDiff.Config
local defaults = {
  layout = "side_by_side",
  -- diffview's cycle-layout key, so muscle memory carries over.
  layout_keymaps = {
    toggle = "g<C-x>",
    -- "go structural"; plain `gs` only sleeps.
    toggle_structural = "gs",
  },

  diff = {
    structural = true,
    algorithm = "histogram",
    normalize_comment_whitespace = true,
  },

  revs = {
    merge_base = true,
  },

  -- A parse-and-fetch budget, not a rendering one: rendering 50,000 lines costs 68 ms,
  -- while a treesitter parse of 95,000 lines costs 1.9 s.
  thresholds = {
    defer_lines = 50000,
    structural_lines = 5000,
    panel_entries = 2000,
  },

  buffers = {
    lru_size = 64,
  },

  git = {
    bin = "git",
    timeout_ms = 15000,
  },

  github = {
    bin = "gh",
    timeout_ms = 20000,
  },

  highlights = {},

  panel = {
    listing = "tree",
    width = 35,
  },

  history = {
    follow = true,
    height = 16,
  },

  threads = {
    resolved = "dim",
  },

  comment = {
    height = 10,
  },

  keymaps = {
    panel = {
      select = "<CR>",
      toggle_listing = "i",
      refresh = "R",
    },
    view = {
      next_file = "<Tab>",
      prev_file = "<S-Tab>",
      toggle_range = "gm",
      line_history = "gL",
    },
    history = {
      mark = "m",
      compare = "M",
    },
    -- diffview's merge-tool keys, so muscle memory carries over.
    conflict = {
      take_ours = "<leader>co",
      take_base = "<leader>cb",
      take_theirs = "<leader>ct",
      take_both = "<leader>ca",
      take_none = "dx",
      next_conflict = "]x",
      prev_conflict = "[x",
    },
    -- octo.nvim's viewed key, so muscle memory carries over; backspace takes it back.
    review = {
      mark_viewed = "<leader><space>",
      unmark_viewed = "<leader><BS>",
    },
    threads = {
      toggle = "<CR>",
      next = "]t",
      prev = "[t",
      toggle_resolved = "gR",
      list = "gC",
      -- The comment family: `cr` replies, so `cR` replies and resolves.
      resolve = "<leader>cx",
      reply_resolve = "<leader>cR",
      unresolve = "<leader>cu",
    },
    -- `<C-s>` may freeze a terminal with flow control on (`stty -ixon` frees it); `:w`
    -- posts as well.
    comment = {
      add = "<leader>cc",
      reply = "<leader>cr",
      submit = "<C-s>",
      cancel = "<C-c>",
      edit = "<leader>ce",
      delete = "<leader>cd",
      -- `<C-g>` is insert mode's own prefix for small commands; `s` is free there.
      suggest = "<C-g>s",
    },
    -- The same editor split as a comment, so the same keys.
    verdict = {
      post = "<C-s>",
      cancel = "<C-c>",
    },
  },

  log = {
    level = "warn",
  },
}

--- A leaf rule is `{ type = ... }`, optionally with `one_of`, `min`, `integer`, or `keymap`
--- (a non-empty key string, or `false` to disable).
--- A table without a `type` key is a branch, and its values are rules for its children.
--- `free` marks a branch whose keys are user-chosen; `values` then validates each value.
local KEY = { type = { "string", "boolean" }, key = true }

local schema = {
  layout = { type = "string", one_of = { "side_by_side", "unified" } },
  layout_keymaps = {
    toggle = { type = { "string", "boolean" }, keymap = true },
    toggle_structural = { type = { "string", "boolean" }, keymap = true },
  },

  diff = {
    structural = { type = "boolean" },
    algorithm = { type = "string", one_of = { "myers", "minimal", "patience", "histogram" } },
    normalize_comment_whitespace = { type = "boolean" },
  },

  revs = {
    merge_base = { type = "boolean" },
  },

  thresholds = {
    defer_lines = { type = "number", integer = true, min = 1 },
    structural_lines = { type = "number", integer = true, min = 1 },
    panel_entries = { type = "number", integer = true, min = 1 },
  },

  buffers = {
    lru_size = { type = "number", integer = true, min = 0 },
  },

  git = {
    bin = { type = "string" },
    timeout_ms = { type = "number", integer = true, min = 1 },
  },

  github = {
    bin = { type = "string" },
    timeout_ms = { type = "number", integer = true, min = 1 },
    host = { type = "string" },
  },

  highlights = { free = true, values = { type = { "table", "string" } } },

  panel = {
    listing = { type = "string", one_of = { "tree", "flat" } },
    width = { type = "number", integer = true, min = 1 },
  },

  history = {
    follow = { type = "boolean" },
    height = { type = "number", integer = true, min = 1 },
  },

  threads = {
    resolved = { type = "string", one_of = { "dim", "hide" } },
  },

  comment = {
    height = { type = "number", integer = true, min = 1 },
  },

  keymaps = {
    panel = {
      select = KEY,
      toggle_listing = KEY,
      refresh = KEY,
    },
    view = {
      next_file = KEY,
      prev_file = KEY,
      toggle_range = KEY,
      line_history = KEY,
    },
    history = {
      mark = KEY,
      compare = KEY,
    },
    conflict = {
      take_ours = KEY,
      take_base = KEY,
      take_theirs = KEY,
      take_both = KEY,
      take_none = KEY,
      next_conflict = KEY,
      prev_conflict = KEY,
    },
    review = {
      mark_viewed = KEY,
      unmark_viewed = KEY,
    },
    threads = {
      toggle = KEY,
      next = KEY,
      prev = KEY,
      toggle_resolved = KEY,
      list = KEY,
      resolve = KEY,
      reply_resolve = KEY,
      unresolve = KEY,
    },
    comment = {
      add = KEY,
      reply = KEY,
      submit = KEY,
      cancel = KEY,
      edit = KEY,
      delete = KEY,
      suggest = KEY,
    },
    verdict = {
      post = KEY,
      cancel = KEY,
    },
  },

  log = {
    level = { type = "string", one_of = { "trace", "debug", "info", "warn", "error", "off" } },
  },
}

---@param t table
---@return string
local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return table.concat(keys, ", ")
end

---@param rule table
---@return string
local function type_name(rule)
  return type(rule.type) == "table" and table.concat(rule.type, " or ") or tostring(rule.type)
end

---@param rule table
---@param value any
---@return boolean
local function type_matches(rule, value)
  if type(rule.type) == "table" then
    return vim.tbl_contains(rule.type, type(value))
  end
  return type(value) == rule.type
end

---@param value any
---@param rule table
---@param path string
---@param errors string[]
local function check_leaf(value, rule, path, errors)
  if not type_matches(rule, value) then
    errors[#errors + 1] = ("`%s`: expected %s, got %s"):format(path, type_name(rule), type(value))
    return
  end
  if rule.one_of and not vim.tbl_contains(rule.one_of, value) then
    errors[#errors + 1] = ("`%s`: expected one of %s, got %s"):format(
      path,
      table.concat(rule.one_of, ", "),
      vim.inspect(value)
    )
  end
  if rule.keymap and (value == true or value == "") then
    errors[#errors + 1] = ("`%s`: expected a key or false, got %s"):format(path, vim.inspect(value))
  end
  if rule.integer and value % 1 ~= 0 then
    errors[#errors + 1] = ("`%s`: expected a whole number, got %s"):format(path, tostring(value))
  end
  if rule.key and value == true then
    errors[#errors + 1] = ("`%s`: expected a key or false, got true"):format(path)
  end
  if rule.min and value < rule.min then
    errors[#errors + 1] = ("`%s`: expected at least %d, got %s"):format(path, rule.min, tostring(value))
  end
end

---@param opts table
---@param node table
---@param prefix string
---@param errors string[]
local function check_node(opts, node, prefix, errors)
  for key, value in pairs(opts) do
    local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    local rule = node[key]
    if rule == nil then
      errors[#errors + 1] = ("unknown option `%s` (valid here: %s)"):format(path, sorted_keys(node))
    elseif rule.free then
      if type(value) ~= "table" then
        errors[#errors + 1] = ("`%s`: expected table, got %s"):format(path, type(value))
      elseif rule.values then
        for subkey, subvalue in pairs(value) do
          check_leaf(subvalue, rule.values, path .. "." .. tostring(subkey), errors)
        end
      end
    elseif rule.type then
      check_leaf(value, rule, path, errors)
    elseif type(value) ~= "table" then
      errors[#errors + 1] = ("`%s`: expected table, got %s"):format(path, type(value))
    else
      check_node(value, rule, path, errors)
    end
  end
end

--- Collect everything wrong with a user option table.
---@param opts table? The table as passed to `setup()`.
---@return string[] errors One human-readable line per problem, empty when the table is fine.
function M.validate(opts)
  local errors = {}
  if opts == nil then
    return errors
  end
  if type(opts) ~= "table" then
    return { ("expected a table of options, got %s"):format(type(opts)) }
  end
  check_node(opts, schema, "", errors)
  table.sort(errors)
  return errors
end

---@type NvimDiff.Config
local current = vim.deepcopy(defaults)
local configured = false

--- Validate `opts`, merge it over the defaults and make it the active configuration.
--- Each call starts from the defaults again, so calling `setup()` twice is not cumulative.
---@param opts NvimDiff.Config? Partial; anything omitted keeps its default.
---@return NvimDiff.Config config The merged configuration.
function M.setup(opts)
  local errors = M.validate(opts)
  if #errors > 0 then
    error("nvim-diff: invalid setup() options:\n  - " .. table.concat(errors, "\n  - "), 0)
  end
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  configured = true
  return current
end

--- The active configuration. Returns the defaults when `setup()` has not been called,
--- so every module may read config without ordering itself after `setup()`.
---@return NvimDiff.Config
function M.get()
  return current
end

--- A fresh copy of the shipped defaults. Mutating it does not affect the active config.
---@return NvimDiff.Config
function M.get_defaults()
  return vim.deepcopy(defaults)
end

---@return boolean called Whether `setup()` has run.
function M.did_setup()
  return configured
end

--- Drop any user configuration. Exists for tests; the plugin never calls it.
function M.reset()
  current = vim.deepcopy(defaults)
  configured = false
end

return M
