--- Review slots: kept worktrees at `<common git dir>/nvim-diff/review-<k>`.
---
--- A PR is checked out, detached, into a slot so LSP, tests and debugging see the PR's
--- code while the user's branch and uncommitted changes are never touched. A slot outlives
--- its review: the next PR is checked out into the same folder, so whatever git ignores
--- there — `node_modules/`, a virtualenv, build output — is still in place, and packages
--- installed by hand once serve every later review. The plugin never installs anything,
--- never removes a slot and has no cleanup command: the user removes slots by hand, and
--- `:checkhealth nvim-diff` lists them.
---
--- One open review holds one slot. A review takes the lowest-numbered slot no running
--- Neovim holds, so a second review open at the same time — in this Neovim or another —
--- gets `review-2`, and so on.
---
--- Holding is recorded in git itself, not in a state file: a held slot is locked with the
--- reason `nvim-diff pid <pid>` (`git worktree lock`), which also stops `git worktree
--- remove` and `prune` from taking it while it is in use. Ending the review unlocks it. A
--- lock whose Neovim is gone — a crash, `kill -9` — counts as free and is taken over; a
--- lock anyone else placed is theirs, and the slot is skipped.
---
--- Checking a commit out into a slot (`M.checkout`) discards changes to tracked files and
--- removes untracked files git does not ignore; ignored files stay. Git hooks are off for
--- it, so a `post-checkout` hook cannot run an install.
---
--- A slot git and the disk disagree about is handled when a review looks for one:
--- - registered, folder gone or empty (removed by hand with `rm`): re-created;
--- - folder present, not registered: `git worktree repair` is tried, which relinks a slot
---   of a repository that was moved; otherwise the folder is skipped, reported and never
---   deleted.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")

local M = {}

--- The lock reason a held slot carries. The pid names the Neovim holding it, so another
--- Neovim can tell a live review from a crashed one.
M.LOCK_REASON = "nvim-diff pid %d"

--- A bound on the slot search, far above the reviews anyone has open at once.
M.MAX_SLOTS = 100

--- Git variables that would point a command run inside a slot at another repository. A
--- dotfiles setup runs Neovim with `GIT_DIR`/`GIT_WORK_TREE` set, and a forced checkout and
--- a clean there would land in the user's home. Inside a slot, its own `.git` file decides.
local SLOT_ENV = {
  GIT_DIR = false,
  GIT_WORK_TREE = false,
  GIT_INDEX_FILE = false,
  GIT_COMMON_DIR = false,
}

---@alias NvimDiff.Git.SlotState
---| "held"         # locked by a running Neovim, this one included
---| "foreign"      # locked by something other than nvim-diff
---| "free"         # registered and on disk, ready for the next review
---| "missing"      # registered, but its folder is gone or empty
---| "unregistered" # a folder git does not know as a worktree
---| "absent"       # neither registered nor on disk

---@class NvimDiff.Git.Slot
---@field k integer
---@field path string
---@field state NvimDiff.Git.SlotState
---@field pid? integer The Neovim in the lock, for `held` and for a stale lock.
---@field stale boolean Locked by a Neovim that is gone: `free` or `missing` all the same.
---@field reason? string The lock reason, for `foreign`.

---@class NvimDiff.Git.WorktreeEntry
---@field path string
---@field locked boolean
---@field reason? string Nil when unlocked or locked without a reason.

--- The folder every slot of `repo` lives in, with symlinks resolved so it compares equal
--- to the paths git records. Inside the common git directory, so it is invisible to
--- `git status` and shared by every worktree of the repository.
---@param repo NvimDiff.Git.Repo
---@return string
function M.dir(repo)
  return path.join(path.real(repo.common_dir), "nvim-diff")
end

--- Slot `k`'s folder.
---@param repo NvimDiff.Git.Repo
---@param k integer
---@return string
function M.slot_path(repo, k)
  vim.validate("k", k, "number")
  return path.join(M.dir(repo), ("review-%d"):format(k))
end

--- Whether the Neovim with `pid` is still running. A process that exists but belongs to
--- someone else (`EPERM`) counts as running: skipping a slot costs nothing.
---@param pid integer
---@return boolean
function M.alive(pid)
  if pid == vim.fn.getpid() then
    return true
  end
  -- Signal 0 checks for existence without delivering anything.
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name == "EPERM"
end

--- The pid in one of nvim-diff's lock reasons; nil for a lock someone else placed.
---@param reason? string
---@return integer?
local function lock_pid(reason)
  return tonumber((reason or ""):match("^nvim%-diff pid (%d+)$"))
end

--- Whether `p` exists and is anything but an empty directory.
---@param p string
---@return boolean
local function occupied(p)
  if not path.exists(p) then
    return false
  end
  local handle = vim.uv.fs_scandir(p)
  return handle == nil or vim.uv.fs_scandir_next(handle) ~= nil
end

--- `repo`'s registered worktrees inside `M.dir(repo)`, by folder name.
---@param repo NvimDiff.Git.Repo
---@return table<string, NvimDiff.Git.WorktreeEntry>? entries
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
local function registered(repo)
  local porcelain, err = cmd.output(repo.toplevel, { "worktree", "list", "--porcelain" })
  if not porcelain then
    return nil, err
  end
  local dir = M.dir(repo)
  local entries = {}
  -- Records are separated by a blank line; `locked` is optional and may carry a reason.
  for record in (porcelain .. "\n\n"):gmatch("(.-)\n\n") do
    local listed = record:match("^worktree ([^\n]+)")
    if listed then
      listed = path.normalize(listed)
      if path.relative(path.real(vim.fs.dirname(listed)), dir) == "." then
        entries[vim.fs.basename(listed)] = {
          path = listed,
          locked = record:match("\nlocked") ~= nil,
          reason = record:match("\nlocked ([^\n]+)"),
        }
      end
    end
  end
  return entries
end

--- What slot `k` is, from `git worktree list` and the disk.
---@param repo NvimDiff.Git.Repo
---@param k integer
---@param entries table<string, NvimDiff.Git.WorktreeEntry>
---@return NvimDiff.Git.Slot
local function classify(repo, k, entries)
  local slot_path = M.slot_path(repo, k)
  local on_disk = occupied(slot_path)
  local entry = entries[vim.fs.basename(slot_path)]
  local slot = { k = k, path = slot_path, stale = false } ---@type NvimDiff.Git.Slot
  if not entry then
    slot.state = on_disk and "unregistered" or "absent"
    return slot
  end
  if entry.locked then
    slot.pid, slot.reason = lock_pid(entry.reason), entry.reason
    if not slot.pid then
      slot.state = "foreign"
      return slot
    end
    if M.alive(slot.pid) then
      slot.state = "held"
      return slot
    end
    slot.stale = true
  end
  slot.state = on_disk and "free" or "missing"
  return slot
end

--- Every slot of `repo` that is registered with git or has a folder on disk, by number.
---@param repo NvimDiff.Git.Repo
---@return NvimDiff.Git.Slot[]? slots
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.slots(repo)
  local entries, err = registered(repo)
  if not entries then
    return nil, err
  end
  local numbers = {}
  local function note(name)
    local k = tonumber(name:match("^review%-(%d+)$"))
    if k and k >= 1 then
      numbers[k] = true
    end
  end
  for name in pairs(entries) do
    note(name)
  end
  for name in vim.fs.dir(M.dir(repo)) do
    note(name)
  end
  local slots = {}
  for k in pairs(numbers) do
    local slot = classify(repo, k, entries)
    if slot.state ~= "absent" then
      slots[#slots + 1] = slot
    end
  end
  table.sort(slots, function(a, b)
    return a.k < b.k
  end)
  return slots
end

--- Worktrees an nvim-diff older than review slots left behind: `nvim-diff/pr-<n>`, which
--- it removed itself when a review ended. Nothing uses them any more.
---@param repo NvimDiff.Git.Repo
---@return string[]? paths
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.legacy(repo)
  local entries, err = registered(repo)
  if not entries then
    return nil, err
  end
  local paths = {}
  for name, entry in pairs(entries) do
    if name:match("^pr%-%d+$") then
      paths[#paths + 1] = entry.path
    end
  end
  table.sort(paths)
  return paths
end

--- Relink a slot folder git lost track of — its repository was moved, so both sides of
--- the link name the old place. `git worktree repair` is git 2.29 or newer; on an older git
--- this fails and the folder is skipped.
---@param repo NvimDiff.Git.Repo
---@param slot NvimDiff.Git.Slot
---@return boolean repaired
local function repair(repo, slot)
  if not path.exists(path.join(slot.path, ".git")) then
    return false
  end
  local _, err = cmd.output(repo.toplevel, { "worktree", "repair", slot.path })
  return err == nil
end

--- Whether a slot is locked by someone other than this Neovim right now.
---@param repo NvimDiff.Git.Repo
---@param slot NvimDiff.Git.Slot
---@return boolean
local function taken_by_other(repo, slot)
  local entries = registered(repo)
  local entry = entries and entries[vim.fs.basename(slot.path)]
  return entry ~= nil and entry.locked and lock_pid(entry.reason) ~= vim.fn.getpid()
end

--- Make `slot` this Neovim's: register it at `commit` when it has no worktree, and lock it.
--- A new slot's files are not checked out yet.
---@param repo NvimDiff.Git.Repo
---@param slot NvimDiff.Git.Slot
---@param commit NvimDiff.Git.Rev
---@return boolean? claimed False for a slot that is not this Neovim's to take, including
---one another Neovim took first.
---@return NvimDiff.Git.Error? err A failure that is not about who holds the slot.
local function claim(repo, slot, commit)
  if slot.state == "held" or slot.state == "foreign" then
    return false
  end
  if slot.state == "unregistered" then
    log.warn("%s is a folder git does not list as a worktree; skipped. See :checkhealth nvim-diff", slot.path)
    return false
  end
  if slot.stale then
    -- Read again right before unlocking: another Neovim may have taken the lock over since
    -- the listing, and unlocking its live lock would put two reviews in one slot.
    local entries = registered(repo)
    local entry = entries and entries[vim.fs.basename(slot.path)]
    if not (entry and entry.locked and entry.reason == slot.reason) then
      return false
    end
    local _, err = cmd.output(repo.toplevel, { "worktree", "unlock", slot.path })
    if err then
      return false
    end
  end
  if slot.state ~= "free" then
    -- `--no-checkout`: the files come with `M.checkout`, after the lock. `--force` replaces
    -- the registration of a slot whose folder was removed by hand.
    local args = { "worktree", "add", "--no-checkout", "--detach", slot.path, commit.oid }
    if slot.state == "missing" then
      table.insert(args, 3, "--force")
    end
    vim.fn.mkdir(vim.fs.dirname(slot.path), "p")
    local _, err = cmd.output(repo.toplevel, args)
    if err then
      -- A failed `add` removes what it created, so a folder there now is another Neovim's.
      if occupied(slot.path) then
        return false
      end
      return nil, err
    end
  end
  -- `worktree add --reason` is newer than the declared git floor, hence a separate lock.
  -- `lock` refuses a slot already locked, so of two Neovims racing for it one wins.
  local reason = M.LOCK_REASON:format(vim.fn.getpid())
  local _, err = cmd.output(repo.toplevel, { "worktree", "lock", "--reason", reason, slot.path })
  if err then
    if taken_by_other(repo, slot) then
      return false
    end
    return nil, err
  end
  return true
end

--- Check `commit` out into slot `slot_path`, detached. Changes to tracked files are
--- discarded and untracked files git does not ignore are removed; ignored files stay.
--- Git hooks do not run.
---@param slot_path string
---@param commit NvimDiff.Git.Rev A `commit`, already fetched.
---@return boolean? ok
---@return NvimDiff.Git.Error? err `invalid` for a non-commit or a folder that is not a
---worktree of its own, or git's failure (unknown commit, a stale `index.lock`, disk full).
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.checkout(slot_path, commit)
  if commit.type ~= "commit" then
    return nil, errors.new("invalid", "a review slot needs a commit, not the " .. commit.type)
  end
  local opts = { env = SLOT_ENV }
  -- A folder whose `.git` file is gone would resolve to an enclosing repository; the forced
  -- checkout and the clean below must only ever touch the slot.
  local top, err = cmd.output(slot_path, { "rev-parse", "--show-toplevel" }, opts)
  if not top then
    return nil, err
  end
  if path.relative(path.real(vim.trim(top)), path.real(slot_path)) ~= "." then
    return nil, errors.new("invalid", slot_path .. " is not a git worktree of its own")
  end
  -- `--force` also overwrites untracked files in the way of the commit's files.
  local hooks_off = "core.hooksPath=/dev/null"
  local _, checkout_err =
    cmd.output(slot_path, { "-c", hooks_off, "checkout", "--quiet", "--detach", "--force", commit.oid }, opts)
  if checkout_err then
    return nil, checkout_err
  end
  -- No `-x`: ignored files are what the slot is kept for.
  local _, clean_err = cmd.output(slot_path, { "clean", "--force", "-d", "--quiet" }, opts)
  if clean_err then
    return nil, clean_err
  end
  return true
end

--- Take the lowest free slot of `repo`, lock it to this Neovim and check `commit` out into
--- it. On failure the slot is released again and its folder kept.
---@param repo NvimDiff.Git.Repo
---@param commit NvimDiff.Git.Rev A `commit`; the PR head must already be fetched.
---@return string? path The slot.
---@return NvimDiff.Git.Error? err `invalid` for a non-commit, `failed` when every slot is
---taken, or git's failure.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.acquire(repo, commit)
  if commit.type ~= "commit" then
    return nil, errors.new("invalid", "a review slot needs a commit, not the " .. commit.type)
  end
  local entries, err = registered(repo)
  if not entries then
    return nil, err
  end
  for k = 1, M.MAX_SLOTS do
    local slot = classify(repo, k, entries)
    if slot.state == "unregistered" and repair(repo, slot) then
      entries, err = registered(repo)
      if not entries then
        return nil, err
      end
      slot = classify(repo, k, entries)
    end
    local claimed
    claimed, err = claim(repo, slot, commit)
    if err then
      return nil, err
    end
    if claimed then
      local ok
      ok, err = M.checkout(slot.path, commit)
      if not ok then
        M.release(repo, slot.path)
        ---@cast err NvimDiff.Git.Error
        return nil, errors.new(err.kind, ("%s: %s"):format(slot.path, err.message), err)
      end
      return slot.path
    end
  end
  return nil, errors.new("failed", ("all %d review slots in %s are taken"):format(M.MAX_SLOTS, M.dir(repo)))
end

--- Release slot `slot_path`: drop this Neovim's lock and keep the folder and its files. A
--- slot this Neovim does not hold is left alone.
---@param repo NvimDiff.Git.Repo
---@param slot_path string
---@return boolean? ok
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.release(repo, slot_path)
  local entries, err = registered(repo)
  if not entries then
    return nil, err
  end
  local entry = entries[vim.fs.basename(path.normalize(slot_path))]
  if not (entry and entry.locked and lock_pid(entry.reason) == vim.fn.getpid()) then
    return true
  end
  local _, unlock_err = cmd.output(repo.toplevel, { "worktree", "unlock", entry.path })
  if unlock_err then
    return nil, unlock_err
  end
  return true
end

return M
