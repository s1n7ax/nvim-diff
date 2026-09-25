--- The README and `doc/nvim-diff.txt` against the code: a doc that is wrong is worse than
--- none, so every default, command and highlight group they name is checked here.

local t = require("tests.harness")
local describe, it, expect = t.describe, t.it, t.expect

local config = require("nvim-diff.config")
local hl = require("nvim-diff.ui.hl")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

---@param rel string
---@return string
local function read(rel)
  local fd = assert(io.open(root .. "/" .. rel, "rb"))
  local text = fd:read("*a")
  fd:close()
  return text
end

local help = read("doc/nvim-diff.txt")
local help_lines = vim.split(help, "\n", { plain = true })
local readme = read("README.md")

--- Every `*tag*` the help file defines, in order, duplicates kept.
---@return string[]
local function help_tags()
  local tags = {}
  for _, line in ipairs(help_lines) do
    for tag in line:gmatch("%*([^%s*|]+)%*") do
      tags[#tags + 1] = tag
    end
  end
  return tags
end

---@return table<string, true>
local function tag_set()
  local set = {}
  for _, tag in ipairs(help_tags()) do
    set[tag] = true
  end
  return set
end

--- Dotted paths of every leaf option, with its default.
---@return table<string, any>
local function leaves()
  local out = {}
  local function walk(node, prefix)
    for key, value in pairs(node) do
      local p = prefix == "" and key or (prefix .. "." .. key)
      if type(value) == "table" and next(value) ~= nil then
        walk(value, p)
      else
        out[p] = value
      end
    end
  end
  walk(config.get_defaults(), "")
  return out
end

--- The user commands `plugin/nvim-diff.lua` defines.
---@return string[]
local function commands()
  local names = {}
  for name in read("plugin/nvim-diff.lua"):gmatch('nvim_create_user_command%("(%w+)"') do
    names[#names + 1] = name
  end
  return names
end

describe("doc", function()
  it("builds with :helptags and has no duplicate tags", function()
    local dir = vim.fn.tempname() .. "-doc"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(help_lines, dir .. "/nvim-diff.txt")
    local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(dir))
    local written = vim.uv.fs_stat(dir .. "/tags") ~= nil
    vim.fn.delete(dir, "rf")
    expect.truthy(ok, tostring(err))
    expect.truthy(written, "no tags file")

    local seen, dups = {}, {}
    for _, tag in ipairs(help_tags()) do
      if seen[tag] then
        dups[#dups + 1] = tag
      end
      seen[tag] = true
    end
    expect.eq({}, dups)
  end)

  it("keeps text within 78 columns", function()
    local long = {}
    for i, line in ipairs(help_lines) do
      if vim.fn.strdisplaywidth(line) > 78 then
        long[#long + 1] = ("%d: %s"):format(i, line)
      end
    end
    expect.eq({}, long)
  end)

  it("links only to tags that exist, here or in Neovim's own help", function()
    local own = tag_set()
    local missing = {}
    local in_code = false
    for _, line in ipairs(help_lines) do
      if line:match("^>%w*$") or line:match("%s>%w*$") then
        in_code = true
      elseif in_code and line:match("^<") then
        in_code = false
      elseif not in_code then
        for link in line:gmatch("|([^%s|`]+)|") do
          if not own[link] and not vim.tbl_contains(vim.fn.getcompletion(link, "help"), link) then
            missing[#missing + 1] = link
          end
        end
      end
    end
    expect.eq({}, missing)
  end)

  it("tags every command and names it in the README", function()
    local tags = tag_set()
    local names = commands()
    expect.truthy(#names >= 7, vim.inspect(names))
    for _, name in ipairs(names) do
      expect.truthy(tags[":" .. name], "no *:" .. name .. "* tag")
      expect.truthy(readme:find("`:" .. name, 1, true), name .. " is not in the README")
    end
  end)

  it("tags every option with the default that ships", function()
    local tags = tag_set()
    local opts = leaves()
    opts["github.host"] = vim.NIL -- valid, no default
    for p, value in pairs(opts) do
      local tag = "nvim-diff-config." .. p
      expect.truthy(tags[tag], "no *" .. tag .. "* tag")
      local shown
      for i, line in ipairs(help_lines) do
        if line:find("*" .. tag .. "*", 1, true) then
          shown = help_lines[i + 1]:match("%(default: (.-)%)$")
          break
        end
      end
      local want = value == vim.NIL and "unset" or ("`" .. vim.inspect(value) .. "`")
      expect.eq(want, shown, p)
    end
  end)

  it("documents no option that does not exist", function()
    local opts = leaves()
    opts["github.host"] = true
    for tag in pairs(tag_set()) do
      local p = tag:match("^nvim%-diff%-config%.(.+)$")
      if p then
        local known = opts[p] ~= nil
        for leaf in pairs(opts) do
          known = known or vim.startswith(leaf, p .. ".")
        end
        expect.truthy(known, "*" .. tag .. "* names no option")
      end
    end
  end)

  it("names every default key in the key reference of both the help and the README", function()
    local keys_section = help:match("%*nvim%-diff%-keys%*(.-)\n7%. CONFIGURATION")
    expect.truthy(keys_section, "no KEYS section")
    local tables = readme:match("\n## Keys\n(.-)\n## Configuration")
    expect.truthy(tables, "no ## Keys section in the README")
    for p, value in pairs(leaves()) do
      if (p:match("^keymaps%.") or p:match("^layout_keymaps%.")) and type(value) == "string" then
        expect.truthy(
          keys_section:find("`" .. value .. "`", 1, true),
          p .. " (" .. value .. ") not in :h nvim-diff-keys"
        )
        expect.truthy(tables:find("`" .. value .. "`", 1, true), p .. " (" .. value .. ") not in the README's keys")
      end
    end
  end)

  it("tags every highlight group, and only real ones, and lists each in the README", function()
    local tags = tag_set()
    for name in pairs(hl.groups) do
      expect.truthy(tags[name], "no *" .. name .. "* tag")
      expect.truthy(readme:find("`" .. name .. "`", 1, true), name .. " is not in the README")
    end
    for tag in pairs(tags) do
      if tag:match("^NvimDiff") then
        expect.truthy(hl.groups[tag], "*" .. tag .. "* is not a highlight group")
      end
    end
  end)
end)

describe("README", function()
  it("shows exactly the shipped defaults in its setup() block", function()
    local block = readme:match('```lua\nrequire%("nvim%-diff"%)%.setup(%(%b{}%))\n```')
    expect.truthy(block, "no setup({...}) block")
    local chunk = assert(loadstring("return " .. block))
    expect.eq(config.get_defaults(), chunk())
  end)
end)
