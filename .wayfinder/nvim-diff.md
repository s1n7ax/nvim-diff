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

## Out of scope

<!-- nothing ruled out yet -->

## Open questions

<!-- requirement fog: known-coming questions not yet sharp enough to ask -->

- How PR review state (viewed marks, draft comments) survives Neovim restarts.
- Whether structural diff must work for every language or degrade gracefully.
- What happens when the plugin is used in a repo whose remote is not GitHub.

## Map

- [ ] grill: requirements sweep (charting in progress)

## Implementation notes

<!-- decisions I made, not the user -->

- Map lives in this file, not a GitHub issue: the repo has no remote yet.
