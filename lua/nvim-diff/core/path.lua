--- Path arithmetic.
---
--- Two vocabularies meet in the git layer and this module keeps them apart.
--- *System paths* are absolute and platform-shaped; they name things on disk. *Git paths*
--- are repo-relative, forward-slashed and never expanded; they name entries in a tree and
--- are used verbatim in buffer names and pathspecs.
---
--- `normalize` is for the first kind only. Running it over a git path would expand a file
--- literally called `~` into the home directory, so `to_git` converts separators and
--- nothing else.

local M = {}

local is_windows = package.config:sub(1, 1) == "\\"

--- Absolute, `~`-expanded, `..`-resolved, forward-slashed, with no trailing separator.
---@param p string
---@param base? string Directory a relative `p` is resolved against; the cwd when omitted.
---@return string
function M.normalize(p, base)
  vim.validate("p", p, "string")
  if base and not M.is_absolute(p) and p:sub(1, 1) ~= "~" then
    p = base .. "/" .. p
  end
  local normalized = vim.fs.normalize(vim.fs.abspath(vim.fs.normalize(p, { expand_env = false })))
  -- A trailing separator survives only on a root ("/" or "C:/"); elsewhere it would make
  -- two names for one directory compare unequal.
  if #normalized > 1 and normalized:sub(-1) == "/" and not normalized:match("^%a:/$") then
    normalized = normalized:sub(1, -2)
  end
  return normalized
end

---@param p string
---@return boolean
function M.is_absolute(p)
  if is_windows then
    return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\]") ~= nil
  end
  return p:sub(1, 1) == "/"
end

--- Join path fragments with `/`, skipping empty ones.
---@param ... string
---@return string
function M.join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    if part ~= nil and part ~= "" then
      parts[#parts + 1] = #parts == 0 and (part:gsub("(.)[/\\]+$", "%1"))
        or (part:gsub("^[/\\]+", ""):gsub("[/\\]+$", ""))
    end
  end
  return (table.concat(parts, "/"):gsub("//+", "/"))
end

---@param a string
---@param b string
---@return boolean
local function same(a, b)
  if is_windows then
    return a:lower() == b:lower()
  end
  return a == b
end

--- `p` relative to `base`, or nil when it is not inside it. Both are normalized first.
---@param p string
---@param base string
---@return string? relative Forward-slashed; `"."` when the two are the same directory.
function M.relative(p, base)
  local target, root = M.normalize(p), M.normalize(base)
  if same(target, root) then
    return "."
  end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  if not same(target:sub(1, #prefix), prefix) then
    return nil
  end
  return target:sub(#prefix + 1)
end

--- Whether `p` is `base` or lives inside it.
---@param p string
---@param base string
---@return boolean
function M.is_under(p, base)
  return M.relative(p, base) ~= nil
end

--- A path in the shape git uses in a tree: forward slashes, no `./` prefix, no trailing
--- slash. Nothing is expanded and nothing is resolved.
---@param p string
---@return string
function M.to_git(p)
  vim.validate("p", p, "string")
  local converted = p:gsub("\\", "/"):gsub("//+", "/"):gsub("^%./", ""):gsub("/+$", "")
  return converted
end

--- A git path turned back into a system path under the worktree `root`.
---@param root string
---@param git_path string
---@return string
function M.from_git(root, git_path)
  return M.join(root, M.to_git(git_path))
end

--- The last component of a git path.
---@param git_path string
---@return string
function M.name(git_path)
  return (M.to_git(git_path):match("[^/]*$"))
end

--- Everything but the last component of a git path; `""` at the top level.
---@param git_path string
---@return string
function M.parent(git_path)
  return M.to_git(git_path):match("^(.*)/[^/]*$") or ""
end

--- `p` with symlinks resolved when it exists, else just normalized. For comparing a path
--- git printed with one the plugin built.
---@param p string
---@return string
function M.real(p)
  local real = vim.uv.fs_realpath(p)
  return real and M.normalize(real) or M.normalize(p)
end

---@param p string
---@return boolean
function M.exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

---@param p string
---@return boolean
function M.is_dir(p)
  local stat = vim.uv.fs_stat(p)
  return stat ~= nil and stat.type == "directory"
end

--- `p` itself when it is a directory, otherwise the directory holding it. A path that does
--- not exist counts as a file, so an unwritten buffer still names its directory.
---@param p string
---@return string
function M.dir_of(p)
  local normalized = M.normalize(p)
  if M.is_dir(normalized) then
    return normalized
  end
  return vim.fs.dirname(normalized)
end

return M
