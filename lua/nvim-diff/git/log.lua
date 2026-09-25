--- Commit history of a file, a directory or the whole repository, streamed.
---
--- One `git log` walks the history. Each commit is a record: a header in a fixed
--- NUL-separated format, then the commit's `--raw --numstat -z` file records — the same
--- shape `git/files.lua` parses for a plain diff, so a commit's files are ordinary
--- `FileChange`s. Records are read off the pipe as they arrive and handed on in batches,
--- so a view can show the first page of a long history while git is still walking it.
---
--- Merges are diffed against their **first parent** (`--diff-merges=first-parent`). Git
--- older than 2.31 has no such option, and its `-m` prints a record per parent while
--- skipping empty ones, so a later parent's diff cannot be told from the first's; there a
--- merge lists no files. A repeated commit id is dropped either way.
---
--- A single file's history follows renames (`--follow`) unless told not to; the commit
--- where the trail crossed a rename lists the file as `R` with its `oldpath`.
---
--- Git occasionally omits the stat half of a record (seen by diffview on some large
--- commits and merges). A record whose files lack stats is fetched again on its own, up to
--- twice, and skipped with a warning after that.
---
--- `walk_line` is the other walk in this file: one line range's history (`git log -L`),
--- for `views/history.lua`'s line history. It is not a variant of `walk` — `-L`'s patch
--- output has a different shape from `--raw --numstat`, so it gets its own record parser
--- (`parse_line_record`) that shares only the commit header format and the `MARKER`
--- splitter with the walk above.

local cmd = require("nvim-diff.git.cmd")
local errors = require("nvim-diff.git.error")
local files = require("nvim-diff.git.files")
local log = require("nvim-diff.core.log")
local path = require("nvim-diff.core.path")

local M = {}

--- Starts every record. Two control bytes: a single one could occur in a path.
M.MARKER = "\30\31"

--- Header fields, each NUL-terminated: oid, parents, author name, author email, author
--- time (unix), subject.
local FORMAT = "--format=%x1e%x1f%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00"
local HEADER_FIELDS = 6

--- Attempts at re-reading a record that came back without stats.
M.RETRIES = 2

---@class NvimDiff.Git.Commit
---@field oid string
---@field parents string[] Empty for a root commit.
---@field author string
---@field email string
---@field time integer Author time, unix seconds.
---@field subject string
--- The files the commit changed against its first parent (the empty tree for a root
--- commit), limited to the walked path.
---@field files NvimDiff.Git.FileChange[]

---@alias NvimDiff.Git.LogKind "file"|"dir"|"repo"

---@class NvimDiff.Git.LogOpts
---@field path? string Git path of a file or directory. Nil or `""` walks the whole repository.
---@field follow? boolean Follow renames. Only for a single file; git refuses it otherwise.
---@field rev? string Where the walk starts. Defaults to `HEAD`.
---@field max_count? integer

--- The `git log` arguments for `opts`.
---@param opts NvimDiff.Git.LogOpts
---@param first_parent? boolean Git has `--diff-merges` (see `M.first_parent`).
---@return string[]? args
---@return NvimDiff.Git.Error? err `bad_revision` for a revision that looks like an option.
function M.args(opts, first_parent)
  local args = {
    "log",
    "-z",
    "--raw",
    "--numstat",
    "--no-abbrev",
    "-M",
    "--no-ext-diff",
    "--no-textconv",
    "--no-color",
    "--no-show-signature",
    FORMAT,
  }
  if first_parent then
    args[#args + 1] = "--diff-merges=first-parent"
  end
  if opts.max_count then
    vim.list_extend(args, { "-n", tostring(opts.max_count) })
  end
  if opts.follow then
    args[#args + 1] = "--follow"
  end
  local rev = opts.rev or "HEAD"
  if rev == "" or rev:sub(1, 1) == "-" then
    return nil, errors.new("bad_revision", ("%q is not a revision"):format(rev))
  end
  args[#args + 1] = rev
  args[#args + 1] = "--"
  if opts.path and opts.path ~= "" then
    args[#args + 1] = ":(literal)" .. opts.path
  end
  return args
end

--- The header fields of a record, shared by the raw/numstat walk and the `-L` walk: an oid,
--- its parents, author, and the byte offset in `text` right after the header, where the
--- diff-specific body (raw+numstat, or a `-L` patch) begins.
---@param text string
---@return string[]? fields
---@return integer? pos
local function parse_header(text)
  local fields, pos = {}, 1
  for i = 1, HEADER_FIELDS do
    local nul = text:find("\0", pos, true)
    if not nul then
      return nil, nil
    end
    fields[i] = text:sub(pos, nul - 1)
    pos = nul + 1
  end
  if not fields[1]:match("^%x+$") then
    return nil, nil
  end
  return fields, pos
end

--- Parse one record: the text after a `MARKER`, up to the next.
---@param text string
---@return NvimDiff.Git.Commit? commit Nil when even the header is unreadable.
---@return boolean malformed The header is fine but a file record has no stats.
function M.parse_record(text)
  local fields, pos = parse_header(text)
  if not fields then
    return nil, true
  end
  -- The file records follow after `-z`'s record terminator and a newline.
  local rest = text:sub(pos):gsub("^[%z\n]+", "")
  local changes = files.parse(rest)
  local malformed = false
  for _, change in ipairs(changes) do
    if not change.additions and not change.binary then
      malformed = true
    end
  end
  return {
    oid = fields[1],
    parents = fields[2] == "" and {} or vim.split(fields[2], " ", { plain = true }),
    author = fields[3],
    email = fields[4],
    time = tonumber(fields[5]) or 0,
    subject = fields[6],
    files = changes,
  },
    malformed
end

--- Splits a byte stream into records at `MARKER`, however the pipe chunked it.
---@class NvimDiff.Git.LogSplitter
---@field private buf string
local Splitter = {}
Splitter.__index = Splitter

---@return NvimDiff.Git.LogSplitter
function M.splitter()
  return setmetatable({ buf = "" }, Splitter)
end

--- Feed a chunk; returns the records it completed.
---@param chunk string
---@return string[]
function Splitter:push(chunk)
  local buf = self.buf .. chunk
  local out = {}
  local start = buf:find(M.MARKER, 1, true)
  if not start then
    self.buf = buf
    return out
  end
  while true do
    local next_start = buf:find(M.MARKER, start + #M.MARKER, true)
    if not next_start then
      break
    end
    out[#out + 1] = buf:sub(start + #M.MARKER, next_start - 1)
    start = next_start
  end
  self.buf = buf:sub(start)
  return out
end

--- The last record, once the stream is over.
---@return string[]
function Splitter:finish()
  local buf = self.buf
  self.buf = ""
  if buf:sub(1, #M.MARKER) == M.MARKER then
    return { buf:sub(#M.MARKER + 1) }
  end
  return {}
end

---@type table<string, boolean>
local has_first_parent = {}

--- Whether this git can diff a merge against its first parent (`--diff-merges`, 2.31).
--- Probed once per git binary: an unknown option is named in the error, while a known one
--- fails, if at all, for some other reason.
---@param repo NvimDiff.Git.Repo
---@return boolean
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.first_parent(repo)
  local bin = require("nvim-diff.config").get().git.bin
  if has_first_parent[bin] == nil then
    local res = cmd.run(repo.toplevel, { "log", "-n0", "--diff-merges=first-parent" })
    has_first_parent[bin] = res ~= nil and not res.stderr:find("diff-merges", 1, true)
  end
  return has_first_parent[bin]
end

---@param res NvimDiff.Job.Result
---@return NvimDiff.Git.Error
local function classify(res)
  local stderr = res.stderr
  local extra = { cmd = require("nvim-diff.core.job").describe(res.cmd), stderr = stderr }
  local reason = require("nvim-diff.core.job").reason(res)
  if
    stderr:find("does not have any commits yet", 1, true)
    or stderr:find("unknown revision", 1, true)
    or stderr:find("bad revision", 1, true)
    or stderr:find("bad default revision", 1, true)
  then
    return errors.new("bad_revision", reason, extra)
  end
  return errors.new("failed", reason, extra)
end

--- One commit's record on its own, for a retry.
---@param repo NvimDiff.Git.Repo
---@param oid string
---@param opts NvimDiff.Git.LogOpts
---@return NvimDiff.Git.Commit? commit
---@return boolean malformed
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
local function reread(repo, oid, opts)
  local args = assert(M.args(vim.tbl_extend("force", opts, { rev = oid, max_count = 1 }), M.first_parent(repo)))
  local out = cmd.output(repo.toplevel, args, { log = true })
  if not out then
    return nil, true
  end
  local splitter = M.splitter()
  local records = splitter:push(out)
  vim.list_extend(records, splitter:finish())
  for _, text in ipairs(records) do
    local commit, malformed = M.parse_record(text)
    if commit and commit.oid == oid then
      return commit, malformed
    end
  end
  return nil, true
end

--- Turn a stream of `git log` output into commits. `read` returns the next chunk, or nil
--- at the end. Split from `walk` so tests can feed it output git did not produce.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.LogOpts
---@param read fun(): string?
---@param on_commits fun(commits: NvimDiff.Git.Commit[])
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.consume(repo, opts, read, on_commits)
  local splitter = M.splitter()
  -- In a followed history the file's name changes at each rename; a retry must ask for
  -- the name it had at that commit.
  local trail = opts.path
  local limited = opts.path ~= nil and opts.path ~= ""
  local last_oid

  ---@param texts string[]
  local function handle(texts)
    local batch = {}
    for _, text in ipairs(texts) do
      local commit, malformed = M.parse_record(text)
      if not commit then
        log.warn("skipping an unreadable git log record")
      elseif commit.oid ~= last_oid then
        last_oid = commit.oid
        local tries = 0
        while commit and malformed and tries < M.RETRIES do
          tries = tries + 1
          commit, malformed = reread(repo, last_oid, vim.tbl_extend("force", opts, { path = trail }))
        end
        if not commit or malformed then
          log.warn("skipping commit %s: git gave no file stats for it", last_oid:sub(1, 12))
        elseif limited and #commit.files == 0 then
          -- A merge that changed nothing under the path against its first parent: git
          -- walks it because it differs from another parent, which is not this history.
          log.trace("skipping %s: nothing under the path against its first parent", last_oid:sub(1, 12))
        else
          batch[#batch + 1] = commit
          if opts.follow then
            for _, change in ipairs(commit.files) do
              if change.path == trail and change.oldpath then
                trail = change.oldpath
              end
            end
          end
        end
      end
    end
    if #batch > 0 then
      on_commits(batch)
    end
  end

  while true do
    local chunk = read()
    if not chunk then
      break
    end
    handle(splitter:push(chunk))
  end
  handle(splitter:finish())
end

--- Walk the history, newest first, calling `on_commits` with each batch as it is read.
--- Inside a task this yields between chunks; cancelling the task kills git.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.LogOpts
---@param on_commits fun(commits: NvimDiff.Git.Commit[])
---@return boolean? ok
---@return NvimDiff.Git.Error? err `bad_revision` (an unborn branch included), or a failure
--- to run git. Commits read before a failure have already been delivered.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.walk(repo, opts, on_commits)
  local args, err = M.args(opts, M.first_parent(repo))
  if not args then
    return nil, err
  end
  local stream = cmd.stream(repo.toplevel, args, { log = true })
  M.consume(repo, opts, function()
    return stream:read()
  end, on_commits)
  local res = stream:result()
  if not res.spawned then
    return nil, errors.new("spawn_failed", "could not run git: " .. res.stderr)
  end
  if res.code ~= 0 then
    return nil, classify(res)
  end
  return true
end

--- The whole history at once. For tests and small histories; views use `walk`.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.LogOpts
---@return NvimDiff.Git.Commit[]? commits
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.commits(repo, opts)
  local all = {}
  local ok, err = M.walk(repo, opts, function(batch)
    vim.list_extend(all, batch)
  end)
  if not ok then
    return nil, err
  end
  return all
end

--- History of one line range in one file (`git log -L`), for `views/history.lua`'s line
--- history. Unlike the raw/numstat walk above, a range's content is tracked directly: a
--- commit whose diff pairs the range's old blob with a different path is a followed
--- rename, found straight from that commit's own `--- a/`/`+++ b/` headers — no `-M`
--- rename-pairing games are needed across separate raw records, and no `--follow` flag
--- exists for `-L` to begin with. Measured on this plugin's own repository (git 2.54): a
--- pure rename with no content change in the range is skipped over with no record at all,
--- the same as if the file had always lived at its current path; a commit that both
--- renames the file and edits the tracked range in one step *is* reported, headers and
--- all, exactly like an ordinary rename shows up in `git diff`. Where `-L`'s own
--- similarity-based tracking cannot find an earlier name (very heavy rewrite alongside a
--- rename), the walk simply ends — the same silent limit `--follow` already has elsewhere
--- in this file, not a `-L`-specific one, so nothing here tries to detect or announce it.
---@class NvimDiff.Git.LineHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class NvimDiff.Git.LineCommit
---@field oid string
---@field parents string[]
---@field author string
---@field email string
---@field time integer
---@field subject string
---@field path string The path the range lives at in this commit.
--- Set only when this exact commit both renamed the file and touched the range: the path
--- it had in the parent. `views/history.lua` reads it exactly like a raw `FileChange`'s
--- `oldpath`, so the existing rename marker row shows unmodified.
---@field oldpath? string
---@field added boolean The range has no earlier content at any path: git's `/dev/null` side.
---@field hunks NvimDiff.Git.LineHunk[] Empty when the patch could not be parsed.
---@field additions integer
---@field deletions integer

---@class NvimDiff.Git.LineLogOpts
---@field path string Git path of the file.
---@field start integer 1-based, in `rev`'s blob.
---@field stop integer 1-based, inclusive; `>= start`.
---@field rev? string Defaults to `HEAD`.

--- The `git log -L` arguments for `opts`.
---@param opts NvimDiff.Git.LineLogOpts
---@return string[]? args
---@return NvimDiff.Git.Error? err `invalid` for a bad range, `bad_revision` for a revision
--- that looks like an option.
function M.line_args(opts)
  if not opts.path or opts.path == "" then
    return nil, errors.new("invalid", "line history needs a path")
  end
  if not opts.start or not opts.stop or opts.start < 1 or opts.stop < opts.start then
    return nil, errors.new("invalid", "not a line range")
  end
  local rev = opts.rev or "HEAD"
  if rev == "" or rev:sub(1, 1) == "-" then
    return nil, errors.new("bad_revision", ("%q is not a revision"):format(rev))
  end
  return {
    "log",
    "-z",
    "-M",
    "--no-color",
    "--no-textconv",
    "--no-ext-diff",
    FORMAT,
    ("-L%d,%d:%s"):format(opts.start, opts.stop, opts.path),
    rev,
    "--",
  }
end

--- Parse one `-L` record: the header (shared with `parse_record`) plus the unified patch
--- that follows it. Only the hunk headers and the `+++`/`---` path lines are read; the
--- patch body is scanned once for the `+`/`-` counts and otherwise ignored — the caller
--- already has a blob-diffing path (`diff/line.lua`) for the file itself.
---@param text string
---@return NvimDiff.Git.LineCommit? commit Nil when the header, or the patch's own paths,
--- could not be read.
function M.parse_line_record(text)
  local fields, pos = parse_header(text)
  if not fields then
    return nil
  end
  local rest = text:sub(pos):gsub("^[%z\n]+", "")
  local old_path = rest:match("\n%-%-%- a/(.-)\n") or rest:match("^%-%-%- a/(.-)\n")
  local is_new = rest:find("\n--- /dev/null\n", 1, true) or rest:match("^%-%-%- /dev/null\n")
  local new_path = rest:match("\n%+%+%+ b/(.-)\n") or rest:match("^%+%+%+ b/(.-)\n")
  if not new_path or (not old_path and not is_new) then
    return nil
  end

  local hunks = {}
  for old_start, old_count, new_start, new_count in rest:gmatch("\n@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@") do
    hunks[#hunks + 1] = {
      old_start = tonumber(old_start),
      old_count = old_count ~= "" and tonumber(old_count) or 1,
      new_start = tonumber(new_start),
      new_count = new_count ~= "" and tonumber(new_count) or 1,
    }
  end

  local additions, deletions = 0, 0
  for line in rest:gmatch("\n([^\n]*)") do
    local c = line:sub(1, 1)
    if c == "+" and line:sub(1, 4) ~= "+++ " then
      additions = additions + 1
    elseif c == "-" and line:sub(1, 4) ~= "--- " then
      deletions = deletions + 1
    end
  end

  return {
    oid = fields[1],
    parents = fields[2] == "" and {} or vim.split(fields[2], " ", { plain = true }),
    author = fields[3],
    email = fields[4],
    time = tonumber(fields[5]) or 0,
    subject = fields[6],
    path = new_path,
    oldpath = (old_path and old_path ~= new_path) and old_path or nil,
    added = is_new and true or false,
    hunks = hunks,
    additions = additions,
    deletions = deletions,
  }
end

--- Walk one line range's history, newest first, calling `on_commits` with each batch as it
--- is read. Inside a task this yields between chunks; cancelling the task kills git. An
--- unreadable record is skipped with a warning rather than retried — `-L`'s patch output
--- does not have the raw/numstat walk's known missing-stats failure mode.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.LineLogOpts
---@param on_commits fun(commits: NvimDiff.Git.LineCommit[])
---@return boolean? ok
---@return NvimDiff.Git.Error? err `invalid`, `bad_revision`, or a failure to run git.
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.walk_line(repo, opts, on_commits)
  local args, err = M.line_args(opts)
  if not args then
    return nil, err
  end
  local stream = cmd.stream(repo.toplevel, args, { log = true })
  local splitter = M.splitter()
  local last_oid

  ---@param texts string[]
  local function handle(texts)
    local batch = {}
    for _, text in ipairs(texts) do
      local commit = M.parse_line_record(text)
      if not commit then
        log.warn("skipping an unreadable git log -L record")
      elseif commit.oid ~= last_oid then
        last_oid = commit.oid
        batch[#batch + 1] = commit
      end
    end
    if #batch > 0 then
      on_commits(batch)
    end
  end

  while true do
    local chunk = stream:read()
    if not chunk then
      break
    end
    handle(splitter:push(chunk))
  end
  handle(splitter:finish())

  local res = stream:result()
  if not res.spawned then
    return nil, errors.new("spawn_failed", "could not run git: " .. res.stderr)
  end
  if res.code ~= 0 then
    return nil, classify(res)
  end
  return true
end

--- The whole line history at once. For tests and short histories; `views/history.lua` uses
--- `walk_line`.
---@param repo NvimDiff.Git.Repo
---@param opts NvimDiff.Git.LineLogOpts
---@return NvimDiff.Git.LineCommit[]? commits
---@return NvimDiff.Git.Error? err
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.line_commits(repo, opts)
  local all = {}
  local ok, err = M.walk_line(repo, opts, function(batch)
    vim.list_extend(all, batch)
  end)
  if not ok then
    return nil, err
  end
  return all
end

--- Whether a git path names a file, a directory, or (empty) the whole repository. A path
--- gone from the disk is asked of `HEAD`; one gone from both counts as a file, since a
--- deleted file's history is the common reason to ask.
---@param repo NvimDiff.Git.Repo
---@param git_path? string
---@return NvimDiff.Git.LogKind
---@throws NvimDiff.Job.Cancelled when the enclosing task is cancelled.
function M.kind(repo, git_path)
  if not git_path or git_path == "" or git_path == "." then
    return "repo"
  end
  local stat = vim.uv.fs_stat(path.from_git(repo.toplevel, git_path))
  if stat then
    return stat.type == "directory" and "dir" or "file"
  end
  local res = cmd.run(repo.toplevel, { "cat-file", "-t", "HEAD:" .. git_path })
  if res and res.code == 0 and vim.trim(res.stdout) == "tree" then
    return "dir"
  end
  return "file"
end

return M
