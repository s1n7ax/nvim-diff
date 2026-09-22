# Wayfinder: nvim-diff

## Destination

A Neovim plugin that fully replaces diffview.nvim and lets the user uninstall it.
It covers every diffview workflow — working-tree diff, branch-to-branch diff, file
history, merge conflict resolution — plus a GitHub PR review mode (open a PR, mark
files viewed back to GitHub, add / view / resolve inline review comments), with a
diff rendering that is unambiguously readable (diff colors never confused with fold
or context colors) and structural, difftastic-style diffs rather than line dumps.

## Requirements

- Full diffview replacement — including file history and merge conflict resolution — so diffview can be uninstalled.
- A commented line shows a collapsed one-line summary as a virtual line under it (author, first line, reply count, resolved state). A keymap expands that in place into multiple virtual lines showing the full thread with all replies — expanded inline, never in a floating window.
- Large files are deferred by a line-count threshold: a file over the limit shows in the panel with its stats and loads only when asked for, and structural diff falls back to plain line diff above a size limit. No configurable exclude globs — the threshold alone decides.
- A separate explicit command submits the review verdict — Approve / Request changes / Comment plus an optional summary body — posted as a review with no inline comments attached, since those went up already. It is never triggered automatically.
- The plugin keeps no local state. Reopening a PR refetches viewed marks and threads from GitHub, which is the only source of truth; nothing about cursor position, layout or expanded threads is remembered across sessions.
- Merge conflicts are resolved in a three-way layout — ours / base / theirs panes plus an editable result buffer — with keymaps to take ours, base, theirs or both per conflict and jump between conflicts. The base pane is required: it is what shows who actually changed the logic.
- File history covers three things: a commit panel for a file, folder or the whole repo with per-commit diff against its parent; marking two commits to diff the range between them; and history of just the line under the cursor (`git log -L`). Renames are followed by default for single files, with a marker in the panel where the trail crossed one.
- Diffing two branches defaults to merge-base (`main...feature`), so a branch diff shows the same thing a GitHub PR would. A keymap flips to the literal tip-to-tip comparison (`main..feature`) for checking what a rebase will bring in.
- Resolving a thread has two keys: one resolves straight away, one takes a reply first and then resolves. Either way the thread stays on screen dimmed with a ✓, and can be unresolved.
- Outdated threads and file-level comments have no line to anchor to, so they live in a side list.
- Resolved threads are dimmed or hidden by default so a busy PR stays readable.
- Inline comments post to GitHub immediately, one at a time, as standalone comments — not queued into a pending review batch.
- Marking a file viewed is an explicit keypress that also jumps to the next unviewed file, and it pushes the viewed state to GitHub. The file panel shows viewed/unviewed/re-changed state and a `3/7 viewed` counter; when GitHub un-views a file because new commits touched it, the panel reflects that rather than fighting it.
- Opening a PR always checks it out to disk so LSP, go-to-definition, running tests and debugging all work against the PR's code — but into a separate git worktree (`.git/nvim-diff/pr-<n>`), never the main working tree. Your branch and uncommitted changes are never touched, and ending the review removes the worktree.
- Side-by-side two panes is the default layout (as diffview does today), with a keymap to flip the current file to unified.
- Structural (treesitter) diff is the default view: only changed syntax nodes light up, and a pure reformat reads as "formatting only — no semantic change". A keymap toggles back to raw line diff, and languages with no parser fall back to line diff automatically.
- Unchanged parts of a file are hidden behind a loud separator row that can never be mistaken for code (`═════ 128 unchanged lines ═════ impl Server ═════`), and can be expanded inline — 10 lines at a time, or all of it.

## Out of scope

- Configurable exclude patterns (`*.lock`, `dist/**`, `*.min.js`) for collapsing generated files — the size threshold covers it, and globs are config to maintain.
- Any local persistence of review progress — no state directory, no cache, no session restore. GitHub holds the state; the plugin refetches.

## Open questions

<!-- requirement fog: known-coming questions not yet sharp enough to ask -->

- `git log -L` cannot follow renames and is slow on big repos — line history needs a visible "trail ended at a rename" state and probably an async/cancellable run.
- How you write a reply to a thread — inside the expanded virtual lines, or a separate prompt buffer.
- Whether the LSP indexing both the main tree and the PR worktree causes problems in practice.
- Whether structural diff must work for every language or degrade gracefully.
- What happens when the plugin is used in a repo whose remote is not GitHub.

## Map

- [ ] grill: requirements sweep (charting in progress)

## Implementation notes

<!-- decisions I made, not the user -->

- Map lives in this file, not a GitHub issue: the repo has no remote yet.
- Structural diff is computed in-plugin with treesitter, not via `git config diff.external difftastic`. An external difftool returns formatted text that would have to be re-parsed to recover real line numbers, and PR inline comments need exact line mapping.
