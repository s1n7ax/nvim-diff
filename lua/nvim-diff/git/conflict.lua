--- Merge conflicts: the markers in a conflicted file, and the index stages behind them.
---
--- A conflicted path has up to three index stages — 1 base, 2 ours, 3 theirs — and a work
--- tree file holding conflict markers:
---
---     <<<<<<< HEAD            ours label
---     ours lines
---     ||||||| base            only with merge.conflictStyle = diff3 or zdiff3
---     base lines
---     =======
---     theirs lines
---     >>>>>>> feature         theirs label
---
--- `parse` reads the markers in one tolerant forward pass: it never raises, a region missing
--- its `=======` or `>>>>>>>` is dropped, and a `<<<<<<<` inside an unfinished region
--- abandons that region and starts a new one. Markers are the default size, 7 characters;
--- the `conflict-marker-size` attribute is not read.
---
--- Parsing and choosing are pure. `stages` and `other_head` run git.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local path = require("nvim-diff.core.path")
local rev = require("nvim-diff.git.rev")

local M = {}

---@alias NvimDiff.ConflictSide "ours"|"base"|"theirs"

--- Lines of one section, `count` lines from `start`. An empty section has `count = 0` and
--- `start` the line after its opening marker.
---@class NvimDiff.ConflictSection
---@field start integer
---@field count integer

---@class NvimDiff.ConflictRegion
---@field first integer Line of the `<<<<<<<` marker.
---@field last integer Line of the `>>>>>>>` marker.
---@field ours NvimDiff.ConflictSection
---@field base? NvimDiff.ConflictSection Present only when the file was written with a base section.
---@field theirs NvimDiff.ConflictSection
--- Text after each marker, e.g. `HEAD` or `feature`; `""` when the marker has none.
---@field labels { ours: string, base?: string, theirs: string }

--- What `choose` can replace a region with. `both` is ours followed by theirs.
---@alias NvimDiff.ConflictChoice "ours"|"base"|"theirs"|"both"|"none"

---@param line string
---@param ch string One marker character.
---@return string? label Nil when `line` is not that marker.
local function marker(line, ch)
  local run = ch:rep(7)
  if line:sub(1, 7) ~= run then
    return nil
  end
  local rest = line:sub(8)
  if rest == "" then
    return ""
  end
  if rest:sub(1, 1) == " " then
    return rest:sub(2)
  end
  return nil
end

--- Parse the conflict markers in `lines`.
---
--- With `cursor`, also says where that line sits: the region holding it, and an index for
--- stepping — `i` inside region `i`, else `k + 0.5` with `k` regions wholly above it. So the
--- next region is `floor(index) + 1` and the previous `ceil(index) - 1`, from anywhere.
---@param lines string[]
---@param cursor? integer
---@return NvimDiff.ConflictRegion[] regions In file order.
---@return NvimDiff.ConflictRegion? current The region holding `cursor`.
---@return number? index
function M.parse(lines, cursor)
  local regions = {}
  local state, open = nil, nil ---@type string?, table?

  for lnum, line in ipairs(lines) do
    local label = marker(line, "<")
    if label then
      -- A new region, even inside an unfinished one: that one is abandoned.
      open = { first = lnum, labels = { ours = label }, ours = { start = lnum + 1 } }
      state = "ours"
    elseif state == "ours" or state == "base" then
      local base_label = state == "ours" and marker(line, "|")
      if base_label then
        open.ours.count = lnum - open.ours.start
        open.base = { start = lnum + 1 }
        open.labels.base = base_label
        state = "base"
      elseif line == "=======" then
        local section = open[state]
        section.count = lnum - section.start
        open.theirs = { start = lnum + 1 }
        state = "theirs"
      end
    elseif state == "theirs" then
      label = marker(line, ">")
      if label then
        open.theirs.count = lnum - open.theirs.start
        open.last = lnum
        open.labels.theirs = label
        regions[#regions + 1] = open
        open, state = nil, nil
      end
    end
  end

  if not cursor then
    return regions
  end
  local above = 0
  for i, r in ipairs(regions) do
    if cursor >= r.first and cursor <= r.last then
      return regions, r, i
    elseif r.last < cursor then
      above = i
    end
  end
  return regions, nil, above + 0.5
end

--- The region holding `lnum`, and its index.
---@param regions NvimDiff.ConflictRegion[]
---@param lnum integer
---@return NvimDiff.ConflictRegion?
---@return integer?
function M.at(regions, lnum)
  for i, r in ipairs(regions) do
    if lnum >= r.first and lnum <= r.last then
      return r, i
    end
  end
  return nil, nil
end

--- The lines of one section of a region.
---@param lines string[] The whole file.
---@param section NvimDiff.ConflictSection
---@return string[]
function M.section_lines(lines, section)
  local out = {}
  for i = 1, section.count do
    out[i] = lines[section.start + i - 1]
  end
  return out
end

--- What the region `first..last` becomes for `choice`. Nil when `choice` is `base` and the
--- region has no base section to take.
---@param lines string[] The whole file.
---@param region NvimDiff.ConflictRegion
---@param choice NvimDiff.ConflictChoice
---@return string[]?
function M.choose(lines, region, choice)
  if choice == "none" then
    return {}
  elseif choice == "both" then
    return vim.list_extend(M.section_lines(lines, region.ours), M.section_lines(lines, region.theirs))
  elseif choice == "base" and not region.base then
    return nil
  end
  local section = region[choice]
  assert(section, "nvim-diff: unknown conflict choice " .. tostring(choice))
  return M.section_lines(lines, section)
end

--- Object ids of the index stages of a conflicted path: `base` (stage 1), `ours` (2),
--- `theirs` (3). A side absent from the conflict — base of an add/add, ours or theirs of a
--- modify/delete — is absent here too.
---@param repo NvimDiff.Git.Repo
---@param git_path string
---@return { base?: string, ours?: string, theirs?: string }? stages
---@return NvimDiff.Git.Error? err `invalid` when the path is not conflicted.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.stages(repo, git_path)
  git_path = path.to_git(git_path)
  local out, err = cmd.output(repo.toplevel, { "ls-files", "-u", "-z", "--", git_path })
  if not out then
    return nil, err
  end
  local names = { "base", "ours", "theirs" }
  local stages, any = {}, false
  for _, record in ipairs(cmd.split_z(out)) do
    local oid, stage, p = record:match("^%d+ (%x+) (%d)\t(.*)$")
    if oid and p == git_path and names[tonumber(stage)] then
      stages[names[tonumber(stage)]] = oid
      any = true
    end
  end
  if not any then
    return nil, errors.new("invalid", git_path .. " is not in a conflicted state")
  end
  return stages
end

--- The heads git writes while an operation stops on conflicts, in the order they are tried.
M.OTHER_HEADS = { "MERGE_HEAD", "REBASE_HEAD", "REVERT_HEAD", "CHERRY_PICK_HEAD" }

--- The commit the conflict is with — the "theirs" side — from whichever operation is in
--- progress. Nil when none is (a conflict from `git stash pop` or `checkout -m` leaves no
--- head behind).
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Rev? rev A `commit` labelled with the head's name.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.other_head(repo)
  for _, name in ipairs(M.OTHER_HEADS) do
    if vim.uv.fs_stat(repo.gitdir .. "/" .. name) then
      local r = rev.resolve(repo, name)
      if r then
        return r
      end
    end
  end
  return nil
end

return M
