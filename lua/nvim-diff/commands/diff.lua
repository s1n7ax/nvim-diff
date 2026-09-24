--- The working-tree and branch diff entry points: `:NvimDiffOpen`, `:NvimDiffClose` and
--- `require("nvim-diff").open()`.
---
---     :NvimDiffOpen                      HEAD against the worktree (untracked included)
---     :NvimDiffOpen --cached             HEAD against the index; `--staged` is the same
---     :NvimDiffOpen main                 main against the worktree
---     :NvimDiffOpen main...feature       merge-base(main, feature) against feature
---     :NvimDiffOpen main..feature        main against feature, tip to tip
---     :NvimDiffOpen main feature         as `main...feature` (`revs.merge_base`)
---     :NvimDiffOpen main -- lua/ a.txt   only these paths
---
--- The meaning of each form is git's own (`git/revparse.lua`). `--imply-local` swaps a
--- right side that is `HEAD`'s commit for the worktree, so the right pane shows the files on
--- disk. On an unborn branch `HEAD` is the empty tree.
---
--- The repository is the one containing the cwd, else the one containing the current file.
--- Paths are relative to the cwd, as a shell would take them.

local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")
local repo_mod = require("nvim-diff.git.repo")
local rev = require("nvim-diff.git.rev")
local revparse = require("nvim-diff.git.revparse")

local M = {}

---@class NvimDiff.OpenOpts
--- A range expression (`main...feature`, `main..feature`, `main`) or two revisions.
--- Omitted: `HEAD`.
---@field range? string|string[]
---@field cached? boolean Diff against the index instead of the worktree. Not with two revisions.
---@field imply_local? boolean A right side at `HEAD`'s commit becomes the worktree.
---@field paths? string[] Paths (relative to the cwd, or absolute) to limit the listing to.
---@field repo? NvimDiff.Git.Repo Defaults to the repository around the cwd or current file.

local FLAGS = { "--cached", "--staged", "--imply-local" }

--- Turn command arguments into `OpenOpts`. Pure.
---@param fargs string[]
---@return NvimDiff.OpenOpts? opts
---@return string? err
function M.parse(fargs)
  local opts = { paths = {} }
  local revs = {}
  local in_paths = false
  for _, arg in ipairs(fargs) do
    if in_paths then
      opts.paths[#opts.paths + 1] = arg
    elseif arg == "--" then
      in_paths = true
    elseif arg == "--cached" or arg == "--staged" then
      opts.cached = true
    elseif arg == "--imply-local" then
      opts.imply_local = true
    elseif arg:sub(1, 1) == "-" then
      return nil, ("unknown option %s (valid: %s, -- <paths>)"):format(arg, table.concat(FLAGS, ", "))
    else
      revs[#revs + 1] = arg
    end
  end
  if #revs > 2 then
    return nil, "at most two revisions: " .. table.concat(revs, " ")
  end
  if #revs == 1 then
    opts.range = revs[1]
  elseif #revs == 2 then
    opts.range = revs
  end
  if #opts.paths == 0 then
    opts.paths = nil
  end
  return opts
end

--- `HEAD`, or the empty tree on an unborn branch.
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Rev? rev
---@return NvimDiff.Git.Error? err
local function head_or_empty(repo)
  local head = rev.head(repo)
  if head then
    return head
  end
  local empty, err = rev.empty(repo)
  if not empty then
    return nil, err
  end
  empty.label = "HEAD (unborn)"
  return empty
end

---@class NvimDiff.ResolvedOpen
---@field left NvimDiff.Git.Rev
---@field right NvimDiff.Git.Rev
---@field range? NvimDiff.Git.Range Only for a range of two revisions, which can be flipped.
---@field resolve_opts NvimDiff.Git.ResolveOpts

--- The two revisions `opts` asks for.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.OpenOpts
---@return NvimDiff.ResolvedOpen? resolved
---@return string? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.resolve(repo, opts)
  local resolve_opts = { imply_local = opts.imply_local or false }
  local spec
  if type(opts.range) == "table" then
    spec = revparse.pair(opts.range[1], opts.range[2])
  elseif opts.range then
    local perr
    spec, perr = revparse.parse(opts.range)
    if not spec then
      return nil, perr and perr.message
    end
  end

  if not spec or spec.mode == "single" then
    local left, err
    if not spec or spec.left == "HEAD" then
      left, err = head_or_empty(repo)
    else
      left, err = rev.resolve(repo, spec.left)
    end
    if not left then
      return nil, err and err.message
    end
    return { left = left, right = opts.cached and rev.index() or rev.worktree(), resolve_opts = resolve_opts }
  end

  if opts.cached then
    return nil, "--cached compares one revision with the index; it does not take a range"
  end
  local range, err = revparse.resolve(repo, spec, resolve_opts)
  if not range then
    return nil, err and err.message
  end
  return { left = range.left, right = range.right, range = range, resolve_opts = resolve_opts }
end

--- The repository around the cwd, else around the current buffer's file.
---@return NvimDiff.Git.Repo? repo
---@return string? err
local function discover()
  local repo, err = repo_mod.discover()
  if repo then
    return repo
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and not name:match("^%a[%w+.-]*://") then
    repo = repo_mod.discover(name)
    if repo then
      return repo
    end
  end
  return nil, err and err.message or "not inside a git repository"
end

--- Command-line paths as git paths under the repository root.
---@param repo NvimDiff.Git.Repo
---@param paths string[]
---@return string[]? git_paths
---@return string? err
local function git_paths(repo, paths)
  local out = {}
  for _, p in ipairs(paths) do
    local abs = path.real(path.normalize(p))
    local rel = path.relative(abs, repo.toplevel)
    if not rel then
      return nil, ("%s is outside the repository %s"):format(p, repo.toplevel)
    end
    out[#out + 1] = rel
  end
  return out
end

--- Open a diff view in a new tabpage.
---@param opts? NvimDiff.OpenOpts
---@return NvimDiff.DiffView? view
---@return string? err Why nothing opened.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.open(opts)
  opts = opts or {}
  local repo, err = opts.repo
  if not repo then
    repo, err = discover()
    if not repo then
      return nil, err
    end
  end
  local resolved
  resolved, err = M.resolve(repo, opts)
  if not resolved then
    return nil, err
  end
  local paths
  if opts.paths and #opts.paths > 0 then
    paths, err = git_paths(repo, opts.paths)
    if not paths then
      return nil, err
    end
  end
  local ok, view = pcall(require("nvim-diff.views.diff").open, {
    repo = repo,
    left = resolved.left,
    right = resolved.right,
    range = resolved.range,
    resolve_opts = resolved.resolve_opts,
    paths = paths,
  })
  if not ok then
    return nil, (tostring(view):gsub("^nvim%-diff: ", ""))
  end
  return view
end

--- `:NvimDiffOpen {args}`: open, or say why not.
---@param fargs string[]
---@return NvimDiff.DiffView?
function M.run(fargs)
  local opts, err = M.parse(fargs)
  local view
  if opts then
    view, err = M.open(opts)
  end
  if not view then
    -- A command the user typed always answers, whatever `log.level` says.
    vim.notify("nvim-diff: " .. (err or "cannot open the diff"), vim.log.levels.ERROR, { title = "nvim-diff" })
  end
  return view
end

--- `:NvimDiffClose`: close the diff view in the current tabpage.
---@return boolean closed
function M.close()
  local view = require("nvim-diff.views.diff").get()
  if not view then
    log.warn("no diff view in this tabpage")
    return false
  end
  view:close()
  return true
end

--- Branch, remote-branch and tag names, plus `HEAD`.
---@param repo NvimDiff.Git.Repo
---@return string[]
local function refs(repo)
  local out = require("nvim-diff.git.cmd").output(repo.toplevel, {
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  })
  local names = { "HEAD" }
  for name in (out or ""):gmatch("[^\n]+") do
    names[#names + 1] = name
  end
  return names
end

--- Completion for `:NvimDiffOpen`: flags, refs (also after `..` or `...`), and files after `--`.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local before = cmdline:sub(1, #cmdline - #arglead)
  if before:match("%s%-%-%s") then
    return vim.fn.getcompletion(arglead, "file")
  end
  if arglead:sub(1, 1) == "-" then
    return vim.tbl_filter(function(flag)
      return vim.startswith(flag, arglead)
    end, vim.list_extend(vim.deepcopy(FLAGS), { "--" }))
  end
  local repo = discover()
  if not repo then
    return {}
  end
  -- Complete the part after the last range operator, keeping what came before it.
  local prefix, rest = arglead:match("^(.*%.%.%.?)(.*)$")
  if not prefix then
    prefix, rest = "", arglead
  end
  local out = {}
  for _, name in ipairs(refs(repo)) do
    if vim.startswith(name, rest) then
      out[#out + 1] = prefix .. name
    end
  end
  return out
end

return M
