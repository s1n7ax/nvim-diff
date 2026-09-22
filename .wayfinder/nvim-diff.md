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
- Outdated threads and file-level comments have no line to anchor to, so they live in a side list.
- Resolved threads are dimmed or hidden by default so a busy PR stays readable.
- Inline comments post to GitHub immediately, one at a time, as standalone comments — not queued into a pending review batch.
- Marking a file viewed is an explicit keypress that also jumps to the next unviewed file, and it pushes the viewed state to GitHub. The file panel shows viewed/unviewed/re-changed state and a `3/7 viewed` counter; when GitHub un-views a file because new commits touched it, the panel reflects that rather than fighting it.
- Opening a PR always checks out the PR branch, so the PR's code is on disk: LSP, go-to-definition, running tests and debugging all work against it.
- Side-by-side two panes is the default layout (as diffview does today), with a keymap to flip the current file to unified.
- Structural (treesitter) diff is the default view: only changed syntax nodes light up, and a pure reformat reads as "formatting only — no semantic change". A keymap toggles back to raw line diff, and languages with no parser fall back to line diff automatically.
- Unchanged parts of a file are hidden behind a loud separator row that can never be mistaken for code (`═════ 128 unchanged lines ═════ impl Server ═════`), and can be expanded inline — 10 lines at a time, or all of it.

## Out of scope

<!-- nothing ruled out yet -->

## Open questions

<!-- requirement fog: known-coming questions not yet sharp enough to ask -->

- How you write a reply to a thread — inside the expanded virtual lines, or a separate prompt buffer.
- Since comments post immediately and carry no review verdict, does the plugin still need to Approve / Request changes / submit a review separately?
- What happens when you open a PR with a dirty working tree — auto-stash, refuse, or use a separate worktree. Follows directly from "always checkout".
- How you return to what you were doing after a review ends.
- How PR review state (viewed marks, draft comments) survives Neovim restarts.
- Whether structural diff must work for every language or degrade gracefully.
- What happens when the plugin is used in a repo whose remote is not GitHub.

## Map

- [ ] grill: requirements sweep (charting in progress)

## Implementation notes

<!-- decisions I made, not the user -->

- Map lives in this file, not a GitHub issue: the repo has no remote yet.
- Structural diff is computed in-plugin with treesitter, not via `git config diff.external difftastic`. An external difftool returns formatted text that would have to be re-parsed to recover real line numbers, and PR inline comments need exact line mapping.
