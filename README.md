# nvim-diff

Diffs, file history, merge conflicts and GitHub pull request review for Neovim. Built to
replace [diffview.nvim](https://github.com/sindrets/diffview.nvim) outright, with a PR
review mode on top.

- **Structural diff by default.** With a treesitter parser, only the syntax nodes that
  changed light up, and a pure reformat collapses to one row: `reformatted into 5 lines —
  no semantic change`. `gs` flips to a plain line diff; files with no parser get one
  automatically.
- **Readable colours.** A changed line is red in the old pane and green in the new one,
  with the changed tokens brighter. Unchanged code folds behind a steel-blue band that can
  never be mistaken for code or for a diff colour. The plugin never uses `DiffAdd` and
  friends, so a colorscheme cannot make them collide.
- **Every diffview workflow**: working tree, index, branch to branch (merge-base by
  default, like a PR), file / folder / repository / line history, range compare, and a
  three-way merge conflict view with a base pane.
- **GitHub PR review**: the PR is checked out into its own git worktree so LSP and tests
  work on its code; viewed marks sync with GitHub; comment threads show inline and expand
  in place; comments, replies, edits, suggestions, resolve and the review verdict all post
  straight to GitHub. github.com and GitHub Enterprise Server.

Side-by-side is the default layout; `g<C-x>` flips a file to unified.

## Requirements

- Neovim **0.12** or newer
- git **2.25** or newer (2.31 or newer to see merge commits' files in history)
- [`gh`](https://cli.github.com), logged in to the PR's host — for PR review only
- treesitter parsers for the languages you want structural diffs in — optional; a file
  without one gets a line diff

`:checkhealth nvim-diff` checks all of it, including whether `gh` is logged in to the host
of the repository you are in.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "s1n7ax/nvim-diff", opts = {} }
```

`setup()` is optional; without it the plugin runs on the defaults. The commands are
defined at startup and load the rest on first use.

## Commands

| Command | What it does |
| --- | --- |
| `:NvimDiffOpen` | `HEAD` against the worktree, untracked files included |
| `:NvimDiffOpen --cached` | `HEAD` against the index (`--staged` is the same) |
| `:NvimDiffOpen main` | `main` against the worktree |
| `:NvimDiffOpen main...feature` | from the merge-base to `feature`: what a PR shows |
| `:NvimDiffOpen main..feature` | `main` against `feature`, tip to tip |
| `:NvimDiffOpen main feature` | as `main...feature` (as `main..feature` with `revs.merge_base = false`) |
| `:NvimDiffOpen main -- lua/ a.txt` | only these paths, relative to the cwd |
| `:NvimDiffClose` | close the diff view (or end the PR review) in this tabpage |
| `:NvimDiffHistory [path]` | commits touching a file or directory (`%` = current file), or the whole repository |
| `:NvimDiffLineHistory` | history of the line under the cursor (`git log -L`), as of `HEAD` |
| `:NvimDiffConflict [path]` | resolve the conflicts in a file (default: the current one) three-way |
| `:NvimDiffPR <n>` | review GitHub PR `n` (`42` or `#42`) |
| `:NvimDiffVerdict [approve\|request-changes\|comment]` | submit the review verdict with a summary |

`:NvimDiffOpen` also takes `--imply-local`, which shows the files on disk when the right
side is `HEAD`'s commit. From Lua: `require("nvim-diff").open({ range = "main...feature",
paths = { "lua" } })`.

Every view opens in its own tabpage. History and conflict views close with `:tabclose`.

## Keys

All buffer-local, all configurable under `keymaps` / `layout_keymaps`; set one to `false`
to drop it.

**File panel**

| Key | Action |
| --- | --- |
| `<CR>` | open the file / fold the directory; on a deferred file, load it |
| `i` | tree ↔ flat listing |
| `R` | refresh |
| `<Tab>` / `<S-Tab>` | next / previous file (also in diff panes) |
| `gm` | branch diff: merge-base (`a...b`) ↔ tip to tip (`a..b`) (also in diff panes) |

**Diff panes**

| Key | Action |
| --- | --- |
| `g<C-x>` | side-by-side ↔ unified, for this file |
| `gs` | structural ↔ line diff, for this file |
| `gL` | history of the line under the cursor, at this pane's revision |

**Folds** (diff panes; mirrored across both panes)

| Key | Action |
| --- | --- |
| `zo` | show 10 more lines (a count multiplies) |
| `zO` / `zv` | open the whole fold |
| `zc` / `zC` | fold it again |
| `za` / `zA` | toggle |
| `zR` / `zM` | open / close every fold |
| `zx` / `zX` | reapply the folds |

**History panel**

| Key | Action |
| --- | --- |
| `<CR>` | open the commit; on a folder/repository commit, fold / unfold its files |
| `R` | read the history again |
| `m` | mark the commit for range compare (at most two) |
| `M` | diff the two marked commits in a new tabpage |
| `<Tab>` / `<S-Tab>` | next / previous file, across commits |

**Conflict view** (all four windows)

| Key | Action |
| --- | --- |
| `<leader>co` / `<leader>cb` / `<leader>ct` | take ours / base / theirs |
| `<leader>ca` | take both, ours then theirs |
| `dx` | take none |
| `]x` / `[x` | next / previous conflict |
| `<Tab>` / `<S-Tab>` | next / previous conflicted file |

Each take is one undoable change to the real file. Nothing is saved or staged for you.

**PR review** — file panel and diff panes

| Key | Action |
| --- | --- |
| `<leader><space>` | mark the file viewed on GitHub, jump to the next unviewed one |
| `<leader><BS>` | clear the viewed mark |
| `<leader>cc` | in the file panel: a file-level comment on the file under the cursor |

**PR review** — diff panes (comment threads)

| Key | Action |
| --- | --- |
| `<CR>` | expand / collapse the thread on this line (elsewhere, a normal `<CR>`) |
| `]t` / `[t` | next / previous thread |
| `gR` | resolved threads: dimmed ↔ hidden |
| `gC` | side list of outdated and file-level comments (`q` closes it) |
| `<leader>cc` | comment on this line, in either pane; in visual mode, on the selected lines |
| `<leader>cr` | reply to the thread on this line |
| `<leader>ce` / `<leader>cd` | edit / delete your comment in the thread (also in the side list) |
| `<leader>cx` | resolve the thread |
| `<leader>cR` | reply, then resolve |
| `<leader>cu` | unresolve |

**Comment and verdict split** (normal and insert mode)

| Key | Action |
| --- | --- |
| `<C-s>` | post (`:w` posts a comment too, but never a verdict) |
| `<C-c>` | cancel; asks first if text would be lost |
| `<C-g>s` | insert a ```` ```suggestion ```` block with the commented lines (new side only) |

A failed post leaves the split open with your text and the error. Closing it with `:q`
keeps the draft; `<leader>cc` (or `:NvimDiffVerdict`) brings it back. If `<C-s>` freezes
your terminal, run `stty -ixon` or use `:w`.

## Configuration

These are the defaults; pass only what you want to change.

```lua
require("nvim-diff").setup({
  layout = "side_by_side", -- "side_by_side" | "unified": how a file opens
  layout_keymaps = {
    toggle = "g<C-x>", -- side-by-side <-> unified
    toggle_structural = "gs", -- structural <-> line diff
  },

  diff = {
    structural = true, -- open files in structural (treesitter) diff
    algorithm = "histogram", -- "myers" | "minimal" | "patience" | "histogram"
    normalize_comment_whitespace = true, -- rewrapping a comment is formatting only
  },

  revs = {
    merge_base = true, -- `:NvimDiffOpen a b` means a...b
  },

  thresholds = {
    defer_lines = 50000, -- a larger file is listed but loads only when asked
    structural_lines = 5000, -- above this per side, structural falls back to line diff
    panel_entries = 2000, -- above this, the panel starts with every directory folded
  },

  buffers = {
    lru_size = 64, -- committed-file diff buffers kept for reuse; 0 keeps none
  },

  git = { bin = "git", timeout_ms = 15000 },
  -- `host = "ghe.example.com"` overrides the host taken from the `origin` remote
  github = { bin = "gh", timeout_ms = 20000 },

  highlights = {}, -- group -> attributes, or group -> name of a group to link to

  panel = {
    listing = "tree", -- "tree" | "flat"
    width = 35,
  },

  history = {
    follow = true, -- a single file's history follows renames
    height = 16, -- rows of the commit panel
  },

  threads = {
    resolved = "dim", -- "dim" | "hide"
  },

  comment = {
    height = 10, -- rows of the comment and verdict split
  },

  keymaps = {
    panel = { select = "<CR>", toggle_listing = "i", refresh = "R" },
    view = { next_file = "<Tab>", prev_file = "<S-Tab>", toggle_range = "gm", line_history = "gL" },
    history = { mark = "m", compare = "M" },
    conflict = {
      take_ours = "<leader>co",
      take_base = "<leader>cb",
      take_theirs = "<leader>ct",
      take_both = "<leader>ca",
      take_none = "dx",
      next_conflict = "]x",
      prev_conflict = "[x",
    },
    review = { mark_viewed = "<leader><space>", unmark_viewed = "<leader><BS>" },
    threads = {
      toggle = "<CR>",
      next = "]t",
      prev = "[t",
      toggle_resolved = "gR",
      list = "gC",
      resolve = "<leader>cx",
      reply_resolve = "<leader>cR",
      unresolve = "<leader>cu",
    },
    comment = {
      add = "<leader>cc",
      reply = "<leader>cr",
      submit = "<C-s>",
      cancel = "<C-c>",
      edit = "<leader>ce",
      delete = "<leader>cd",
      suggest = "<C-g>s",
    },
    verdict = { post = "<C-s>", cancel = "<C-c>" },
  },

  log = { level = "warn" }, -- "trace" | "debug" | "info" | "warn" | "error" | "off"
})
```

A misspelled option or a wrong type makes `setup()` raise, naming the full path of every
offending key. Each call starts from the defaults again. `:h nvim-diff-config` describes
every option.

## Highlight groups

Every group is defined with `default`, so a colorscheme that sets one keeps it, and
`highlights` in the config overrides any of them:

```lua
highlights = {
  NvimDiffAddLine = { bg = "#12351f" },
  NvimDiffThreadResolved = "NonText",
}
```

| Where | Groups |
| --- | --- |
| Diff panes | `NvimDiffDelLine` `NvimDiffAddLine` `NvimDiffDelToken` `NvimDiffAddToken` `NvimDiffContextSeparator` `NvimDiffReformatSeparator` `NvimDiffFiller` `NvimDiffHeader` |
| Comment threads | `NvimDiffThreadBar` `NvimDiffThreadAuthor` `NvimDiffThreadBody` `NvimDiffThreadMeta` `NvimDiffThreadResolved` |
| Comment split | `NvimDiffCommentHeader` `NvimDiffCommentHint` `NvimDiffCommentError` |
| File panel | `NvimDiffPanelTitle` `NvimDiffPanelDir` `NvimDiffPanelPath` `NvimDiffPanelOldPath` `NvimDiffPanelInsertions` `NvimDiffPanelDeletions` `NvimDiffPanelSelected` `NvimDiffPanelViewed` `NvimDiffPanelRechanged` `NvimDiffPanelDeferred` `NvimDiffPanelStatusAdded` `NvimDiffPanelStatusModified` `NvimDiffPanelStatusDeleted` `NvimDiffPanelStatusConflicted` |
| Conflict result | `NvimDiffConflictMarker` `NvimDiffConflictOurs` `NvimDiffConflictBase` `NvimDiffConflictTheirs` |
| History panel | `NvimDiffHistoryHash` `NvimDiffHistoryDate` `NvimDiffHistoryAuthor` `NvimDiffHistoryRename` `NvimDiffHistoryError` `NvimDiffHistoryMarked` `NvimDiffHistoryLineRange` |

Diff groups set a background only, so syntax colours show through. Inside plugin windows
`Folded` links to `NvimDiffContextSeparator`. `:h nvim-diff-highlights` says what each one
colours.

## PR review in short

`:NvimDiffPR 42` fetches the PR through `gh`, checks its head out into
`<git dir>/nvim-diff/pr-42` (a separate worktree — your branch and uncommitted changes are
never touched) and opens it in a tabpage whose `:tcd` is that worktree. The diff is
computed locally with git. Closing the tab removes the worktree. Nothing is kept locally:
reopening a PR refetches viewed marks and threads from GitHub.

Comments post immediately, one at a time, as standalone comments — there is no pending
review batch. `:NvimDiffVerdict` submits Approve / Request changes / Comment separately,
and only when you run it.

## Limitations

- PR review is GitHub only (github.com and GitHub Enterprise Server).
- Every GitHub write path — comments, replies, edits, deletes, resolve, viewed marks, the
  verdict — is tested against a stub `gh`, not a live PR.
- Nothing is refetched while a review is open; reopen the PR to see new comments.
- File-level comments need a GHES version that supports `subject_type=file`.
- Opening the same PR in two Neovim instances hands the worktree to the second.
- Structural diff ignores injected languages and has no notion of moved code; it runs
  synchronously when a file opens.
- No hunk or file staging, and no staged/unstaged split in the working-tree view.
- `:NvimDiffClose` does not close history or conflict views.

## Development

```
make check           # format check, lint, tests
make test            # nvim --clean --headless -l tests/runner.lua
make test T=config   # only tests whose name matches
make health          # :checkhealth nvim-diff with nothing else loaded
```

Tests need only `nvim` on `$PATH`; `make lint` and `make fmt` need `luacheck` and
`stylua`. Scrolling is tested in a second Neovim driven over RPC (`tests/child.lua`); keep
test screens at or below 80x24, since a headless Neovim with no UI segfaults on redraw
when larger. `tests/spec/doc_spec.lua` checks this README's defaults block and the help
file's tags against the code.

## Licence

MIT — see [LICENSE](LICENSE). No code is copied from diffview.nvim, which is
GPL-3.0-or-later; see [LICENSES/README.md](LICENSES/README.md).
