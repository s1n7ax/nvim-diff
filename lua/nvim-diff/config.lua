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
---@field lru_size integer Non-local diff buffers kept before the oldest is evicted.

---@class NvimDiff.Config.Git
---@field bin string
---@field timeout_ms integer

---@class NvimDiff.Config.GitHub
---@field bin string
---@field timeout_ms integer
---@field host? string GitHub Enterprise host; resolved from the remote when unset.

---@class NvimDiff.Config.Log
---@field level "trace"|"debug"|"info"|"warn"|"error"|"off"

---@class NvimDiff.Config.Panel
---@field listing "tree"|"flat" How the file panel groups files; toggled per view.
---@field width integer Columns.

--- A key in `{lhs}` notation, or `false` for no mapping.
---@alias NvimDiff.Config.Key string|false

---@class NvimDiff.Config.PanelKeymaps
--- Open the file under the cursor (on a deferred file already showing its note: load it),
--- or fold/unfold the directory under it.
---@field select NvimDiff.Config.Key
---@field toggle_listing NvimDiff.Config.Key Switch between tree and flat.
---@field refresh NvimDiff.Config.Key Re-list the files.

---@class NvimDiff.Config.ViewKeymaps
---@field next_file NvimDiff.Config.Key In the panel and in the diff panes.
---@field prev_file NvimDiff.Config.Key

---@class NvimDiff.Config.Keymaps
---@field panel NvimDiff.Config.PanelKeymaps Buffer-local to the file panel.
---@field view NvimDiff.Config.ViewKeymaps Buffer-local to the file panel and every pane of a view.

---@class NvimDiff.Config
---@field layout "side_by_side"|"unified"
---@field diff NvimDiff.Config.Diff
---@field revs NvimDiff.Config.Revs
---@field thresholds NvimDiff.Config.Thresholds
---@field buffers NvimDiff.Config.Buffers
---@field git NvimDiff.Config.Git
---@field github NvimDiff.Config.GitHub
---@field highlights table<string, vim.api.keyset.highlight|string> Group name to attributes, or to a group to link to.
---@field log NvimDiff.Config.Log
---@field panel NvimDiff.Config.Panel
---@field keymaps NvimDiff.Config.Keymaps

---@type NvimDiff.Config
local defaults = {
  layout = "side_by_side",

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

  keymaps = {
    panel = {
      select = "<CR>",
      toggle_listing = "i",
      refresh = "R",
    },
    view = {
      next_file = "<Tab>",
      prev_file = "<S-Tab>",
    },
  },

  log = {
    level = "warn",
  },
}

--- A leaf rule is `{ type = ... }`, optionally with `one_of`, `min` or `integer`.
--- A table without a `type` key is a branch, and its values are rules for its children.
--- `free` marks a branch whose keys are user-chosen; `values` then validates each value.
local KEY = { type = { "string", "boolean" }, key = true }

local schema = {
  layout = { type = "string", one_of = { "side_by_side", "unified" } },

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
    lru_size = { type = "number", integer = true, min = 1 },
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

  keymaps = {
    panel = {
      select = KEY,
      toggle_listing = KEY,
      refresh = KEY,
    },
    view = {
      next_file = KEY,
      prev_file = KEY,
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
