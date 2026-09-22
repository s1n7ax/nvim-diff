# Wayfinder: nvim-diff

## Destination

A Neovim plugin that fully replaces diffview.nvim and lets the user uninstall it.
It covers every diffview workflow — working-tree diff, branch-to-branch diff, file
history, merge conflict resolution — plus a GitHub PR review mode (open a PR, mark
files viewed back to GitHub, add / view / resolve inline review comments), with a
diff rendering that is unambiguously readable (diff colors never confused with fold
or context colors) and structural, difftastic-style diffs rather than line dumps.

## Requirements

### Reading a diff

- Structural (treesitter) diff is the default view: only changed syntax nodes light up, and a pure reformat reads as "formatting only — no semantic change". A keymap toggles back to raw line diff, and languages with no parser fall back to line diff automatically.
- Unchanged parts of a file are hidden behind a loud separator row that can never be mistaken for code (`═════ 128 unchanged lines ═════ impl Server ═════`), and can be expanded inline — 10 lines at a time, or all of it.
- Side-by-side two panes is the default layout (as diffview does today), with a keymap to flip the current file to unified.
- Large files are deferred by a line-count threshold: a file over the limit shows in the panel with its stats and loads only when asked for, and structural diff falls back to plain line diff above a size limit. No configurable exclude globs — the threshold alone decides.

### Diffing revisions

- Diffing two branches defaults to merge-base (`main...feature`), so a branch diff shows the same thing a GitHub PR would. A keymap flips to the literal tip-to-tip comparison (`main..feature`) for checking what a rebase will bring in.
- File history covers three things: a commit panel for a file, folder or the whole repo with per-commit diff against its parent; marking two commits to diff the range between them; and history of just the line under the cursor (`git log -L`). Renames are followed by default for single files, with a marker in the panel where the trail crossed one.
- Merge conflicts are resolved in a three-way layout — ours / base / theirs panes plus an editable result buffer — with keymaps to take ours, base, theirs or both per conflict and jump between conflicts. The base pane is required: it is what shows who actually changed the logic.

### Reviewing a PR

- PR review works against github.com and GitHub Enterprise Server. Diffing, history and conflicts work in any git repo regardless of its remote.
- Opening a PR always checks it out to disk so LSP, go-to-definition, running tests and debugging all work against the PR's code — but into a separate git worktree (`.git/nvim-diff/pr-<n>`), never the main working tree. The user's branch and uncommitted changes are never touched, and ending the review removes the worktree.
- Marking a file viewed is an explicit keypress that also jumps to the next unviewed file, and it pushes the viewed state to GitHub. The file panel shows viewed/unviewed/re-changed state and a `3/7 viewed` counter; when GitHub un-views a file because new commits touched it, the panel reflects that rather than fighting it.
- A commented line shows a collapsed one-line summary as a virtual line under it (author, first line, reply count, resolved state). A keymap expands that in place into multiple virtual lines showing the full thread with all replies — expanded inline, never in a floating window.
- Outdated threads and file-level comments have no line to anchor to, so they live in a side list.
- Resolved threads are dimmed or hidden by default so a busy PR stays readable.
- Inline comments post to GitHub immediately, one at a time, as standalone comments — not queued into a pending review batch.
- Resolving a thread has two keys: one resolves straight away, one takes a reply first and then resolves. Either way the thread stays on screen dimmed with a ✓, and can be unresolved.
- A separate explicit command submits the review verdict — Approve / Request changes / Comment plus an optional summary body — posted as a review with no inline comments attached, since those went up already. It is never triggered automatically.
- The plugin keeps no local state. Reopening a PR refetches viewed marks and threads from GitHub, which is the only source of truth; nothing about cursor position, layout or expanded threads is remembered across sessions.

## Out of scope

- GitLab merge requests and any non-GitHub forge review layer — a second, genuinely different API for comments, resolve and auth.
- Configurable exclude patterns (`*.lock`, `dist/**`, `*.min.js`) for collapsing generated files — the size threshold covers it, and globs are config to maintain.
- Any local persistence of review progress — no state directory, no cache, no session restore. GitHub holds the state; the plugin refetches.
- Batching comments into a pending review — ruled out by choosing immediate posting.

## Open questions

<!-- requirement fog: known-coming questions not yet sharp enough to ask -->

- How the user writes a reply to a thread — inside the expanded virtual lines, or a separate prompt buffer.
- Whether structural diff must work for every language or degrade gracefully per-language; and what a "moved code" change should look like.
- `git log -L` cannot follow renames and is slow on big repos — line history needs a visible "trail ended at a rename" state and probably an async, cancellable run.
- Whether an LSP indexing both the main tree and the PR worktree causes problems in practice.
- Whether staging hunks belongs here at all, given diffview is being replaced but gitsigns already does it.

## Map

- [x] grill: requirements sweep — [result](#result-grill-requirements-sweep)
- [ ] research: GitHub API surface for PR review
- [ ] research: structural diff with treesitter
- [ ] research: Neovim rendering primitives for diff display
- [ ] research: prior art — diffview.nvim and octo.nvim architecture
- [ ] prototype: the visual language (highlight groups, separator row, structural output)
- [ ] implement: plugin skeleton, config, health check, test harness
- [ ] implement: git layer — revs, merge-base, file lists, blobs, worktrees
- [ ] implement: line diff engine and the hunk data model
- [ ] implement: side-by-side renderer with scroll sync
- [ ] implement: context folding — separator row, expand 10, expand all
- [ ] implement: unified renderer and the layout toggle
- [ ] implement: file panel — list, stats, navigation, size-threshold deferral
- [ ] implement: working-tree and branch diff entry points
- [ ] implement: structural diff as the default view, with the raw-line toggle
- [ ] implement: file history panel — commits for file, folder and repo
- [ ] implement: range compare and line history
- [ ] implement: merge conflict three-way layout
- [ ] implement: GitHub client — gh auth, Enterprise hosts, PR fetch
- [ ] implement: PR review mode — worktree checkout, viewed marks, jump to next unviewed
- [ ] implement: reading comment threads — collapsed virtual line, expand in place, side list
- [ ] implement: writing inline comments and replies
- [ ] implement: resolve, reply-and-resolve, unresolve
- [ ] implement: review verdict command
- [ ] implement: README, docs, and health check polish

## Implementation notes

<!-- decisions I made, not the user -->

- Map lives in this file, not a GitHub issue: the repo has no remote yet. Moving it to an issue is easy later.
- Structural diff is computed in-plugin with treesitter, not via `git config diff.external difftastic`. An external difftool returns formatted text that would have to be re-parsed to recover real line numbers, and PR inline comments need exact line mapping.
- GitHub access goes through the `gh` CLI rather than a token the plugin manages. `gh` is already installed and authenticated here, it handles Enterprise hosts and SSO, and it removes token storage from the plugin's problem list. `gh api graphql` covers the parts that are GraphQL-only (viewed state, thread resolve).
- Comment threads render with extmark virtual lines, not floating windows — this is what makes expand-in-place possible, and it was the user's explicit correction.

## Results

### result: grill: requirements sweep

Charting session, 2026-09-23. Fourteen requirement questions answered; every answer is
recorded under **Requirements** above and each was committed to this file as it landed.

Two answers overrode an earlier one and are worth flagging, because they changed the
design rather than adding to it:

1. **"Always checkout the PR branch"** followed by **"separate git worktree"**. The
   first answer would have meant stashing or refusing on a dirty tree. The worktree
   answer keeps the promise (PR code on disk, LSP works) with none of the risk to
   uncommitted work.
2. **Comment threads expand in place as virtual lines, never in a float.** The layout
   answer had carried a note saying threads open in a floating window in side-by-side
   mode; the user corrected this directly. Floats are out everywhere.

The requirements sweep is complete: nothing is left that only the user can decide.
Everything still unknown is a thing I can answer by reading docs, reading prior art,
or trying it — which is what the four `research:` steps are for.

**Next step:** `research: GitHub API surface for PR review`.
