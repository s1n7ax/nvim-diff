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

- Injected languages (a Lua fence in markdown, a script tag in HTML, Vue SFCs) need the token list spliced together from one tree per language by byte offset. Whether that is worth doing in the first structural-diff step or deferred to its own step.
- How the user writes a reply to a thread — inside the expanded virtual lines, or a separate prompt buffer.
- What a "moved code" change should look like. Neither the token-stream design nor difftastic detects a moved block; it reads as a delete plus an add. (The per-language degradation half of this question is answered: it degrades, on three measured triggers.)
- `git log -L` cannot follow renames and is slow on big repos — line history needs a visible "trail ended at a rename" state and probably an async, cancellable run.
- Whether an LSP indexing both the main tree and the PR worktree causes problems in practice.
- Whether staging hunks belongs here at all, given diffview is being replaced but gitsigns already does it.
- Nothing is refetched while a review is open, so another reviewer's new comment stays invisible until the PR is reopened — probably a manual refresh keymap rather than polling.
- Whether to feature-detect GHES capabilities by introspecting the schema at startup, or just let the API error surface.

## Map

- [x] grill: requirements sweep — [result](#result-grill-requirements-sweep)
- [x] research: GitHub API surface for PR review — [result](#result-research-github-api-surface-for-pr-review)
- [x] research: structural diff with treesitter — [result](#result-research-structural-diff-with-treesitter)
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
- Structural diff is computed in-plugin with treesitter, not by shelling out to difftastic. (The original reason given here — that an external difftool returns unparseable formatted text — was wrong; `difft --display json` does give line and column ranges. The real reasons are in the research result: unstable env-gated format, a second binary to install, difftastic's own grammars disagreeing with the editor's, and no reuse of an already-parsed buffer tree.)
- GitHub access goes through the `gh` CLI rather than a token the plugin manages. `gh` is already installed and authenticated here, it handles Enterprise hosts and SSO, and it removes token storage from the plugin's problem list. `gh api graphql` covers the parts that are GraphQL-only (viewed state, thread resolve).
- Comment threads render with extmark virtual lines, not floating windows — this is what makes expand-in-place possible, and it was the user's explicit correction.

- Reads go over GraphQL, writes over REST. Viewed state and thread structure exist only in GraphQL; immediate standalone posting exists only in REST (`addPullRequestReviewThread` is pending-review only). The two id spaces bridge by `node_id` / `fullDatabaseId`.
- The diff is computed locally with git from the PR worktree, never fetched from `/pulls/{n}/files` — that endpoint paginates, truncates big patches and caps at 3000 files. GitHub is asked only for SHAs, viewed state and threads.
- `resolveReviewThread` is called without `resolutionReason`; the field is recent and GHES may not have it.

- Structural diff is a token-stream diff, not tree-edit-distance: flatten each tree to leaf tokens, diff the token text, roll each changed token up to its smallest enclosing named node. Difftastic's Dijkstra search and GumTree-style matching buy nothing the requirements ask for and cost far more.
- The token diff is handed to `vim.text.diff` (Neovim's built-in xdiff, in C) as a synthetic token-per-line document, with `algorithm = "histogram"`. A pure-Lua LCS takes 2.8 s on a worst-case 12K-token file; this takes 0.58 ms.
- Structural diff falls back to line diff on three triggers: no parser for the language, `root:has_error()`, or more than ~5,000 lines per side.
- Parser availability is probed with `pcall(vim.treesitter.get_string_parser, "", lang)`. `vim.treesitter.language.add` is not usable as a probe — it returns true for languages that do not exist.
- A changed token highlights its whole enclosing named node, not the character delta inside it — this is what difftastic does and it is what makes a diff scannable.
- Comment text is compared with whitespace normalised, so rewrapping a comment is a formatting change, while editing its words is a real one.

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

### result: research: GitHub API surface for PR review

Everything below was checked against the live API with `gh` (2.101.0), not recalled.
Schema facts come from GraphQL introspection; line-anchoring facts come from real
threads on `cli/cli#10513`.

**Shape of the answer: reads are GraphQL, writes are REST.** Neither API covers the
whole job.

- Only GraphQL exposes viewed state and thread grouping (`isResolved`, `isOutdated`,
  reply structure). REST `/pulls/{n}/comments` returns a flat comment list with no
  viewed state and no resolved flag; threads would have to be rebuilt from
  `in_reply_to_id`.
- Only REST posts a comment *immediately*. The GraphQL `addPullRequestReviewThread`
  mutation is described by the schema itself as "Adds a new thread to a **pending**
  Pull Request Review" — the batching model the user ruled out.
- The two id spaces bridge cleanly: a REST comment's `node_id` is the GraphQL `id`,
  and a GraphQL comment's `fullDatabaseId` is the REST numeric `id`. So a thread read
  over GraphQL can be replied to over REST with no extra fetch.

**Viewed state** — `pullRequest.files(first:100){ nodes { path additions deletions
changeType viewerViewedState } }`, write with `markFileAsViewed(pullRequestId, path)`
and `unmarkFileAsViewed`. Both mutations take the PR **node id** (`PR_kwDO…`, from
`pullRequest.id`), not the number. `FileViewedState` is `VIEWED / UNVIEWED /
DISMISSED`, and **`DISMISSED` is exactly the "I marked it viewed and new commits
changed it" state** the panel needs — GitHub computes it, the plugin just renders it.
`changeType` is `ADDED DELETED RENAMED COPIED MODIFIED CHANGED`; note it gives no
previous path for a rename, so rename trails come from local git, not here.

**Threads** — `reviewThreads(first:100, after:$endCursor)` gives `id path line
startLine originalLine originalStartLine diffSide startDiffSide isResolved isOutdated
isCollapsed subjectType viewerCanReply viewerCanResolve viewerCanUnresolve resolvedBy`,
and nested `comments(first:100)` gives `id fullDatabaseId author.login body outdated
createdAt diffHunk replyTo url viewerDidAuthor`. Page size caps at 100 and
`gh api graphql --paginate` with `$endCursor` works (verified: 84 threads returned in
one page). Cost is 1 rate-limit point per call against a 5000/hr budget, so the
"refetch everything on open, keep no local state" requirement is essentially free —
a whole PR is one or two calls.

**Outdated threads really have no line.** Verified: an outdated thread returns
`line: null` while keeping `originalLine` and its original commit (REST agrees —
`line: null`, `original_line: 679`). `subjectType: FILE` threads have no line either.
So the side list is not a UI preference, it is the only place these can go.

**Posting a comment** — `POST /repos/{o}/{r}/pulls/{n}/comments` with `body`,
`commit_id`, `path`, `line`, `side` (`RIGHT`/`LEFT`), plus `start_line`/`start_side`
for a multi-line comment and `subject_type: file` for a file-level one. It posts
immediately and notifies; GitHub wraps it in an auto-created `COMMENTED` review. The
GHES 3.17 docs list the identical parameter set, so nothing here is dotcom-only.
`commit_id` must be the head SHA the line belongs to — that is `headRefOid`, which is
what the worktree is checked out at.

**Replying** — `POST /repos/{o}/{r}/pulls/{n}/comments/{comment_id}/replies` with only
`body`, where `comment_id` is the `fullDatabaseId` of the thread's first comment.

**Resolving** — `resolveReviewThread(threadId)` / `unresolveReviewThread(threadId)`,
both GraphQL, both taking the thread node id straight from the read. The optional
`resolutionReason` (`ADDRESSED / WONT_FIX / INVALID`) is recent; the plugin should not
send it, since GHES may not know the field. Reply-and-resolve is two calls (REST then
GraphQL) and is not atomic: if the resolve fails, the reply is already public, so that
case must be reported rather than retried.

**Verdict** — `POST /repos/{o}/{r}/pulls/{n}/reviews` with `event` of `APPROVE`,
`REQUEST_CHANGES` or `COMMENT` and an optional `body`, and **no** `comments` array.
That is precisely the requirement: a review carrying only the verdict. Omitting
`event` creates a PENDING review instead — it must never be omitted. Approving your
own PR is a 422, so the verdict command needs that error path.

**Enterprise** — `gh api --hostname <host>` and `gh auth token --hostname <host>` both
exist, and `GH_HOST` / `GH_ENTERPRISE_TOKEN` are honoured. The host comes from the
remote URL, so the plugin never asks for it. All of the above exists on GHES 3.17.

**Rate limits** — 5000 REST requests/hr and 5000 GraphQL points/hr (primary), and
secondary limits of 80 content-creating requests per minute, 500 per hour, 100
concurrent. Posting one comment at a time is nowhere near these; the client only needs
to surface the 403 secondary-limit error with its retry-after rather than silently
retrying.

**The diff does not come from GitHub.** `/pulls/{n}/files` paginates, truncates large
patches and stops at 3000 files. Since the PR is checked out into a worktree anyway,
the diff is computed locally with git against the merge-base — which is the same thing
GitHub's PR view shows. The API is used only for head/base SHAs, the file list with
`viewerViewedState`, and threads.

**Why the worktree decision pays off twice.** A thread's `line` is a line number in the
file at the PR head (for `RIGHT`) or in the base file (for `LEFT`) — not a diff
position. With the worktree checked out at `headRefOid`, `RIGHT` thread lines map 1:1
onto buffer lines with no position arithmetic at all. The legacy `position` /
`original_position` fields can be ignored entirely.

**Next step:** `research: structural diff with treesitter`.

### result: research: structural diff with treesitter

Every number below was measured in this environment (Neovim 0.12.4, LuaJIT, difftastic
0.69.0), not recalled. The throwaway prototype lived in the scratchpad and is gone.

**The algorithm: flatten, diff tokens, roll up.** Tree-edit-distance (difftastic's
Dijkstra over a graph of node pairs, or GumTree's match-then-align) is not needed and
not affordable in Lua. Three cheap steps get the same output:

1. Walk each tree and collect **leaf nodes** as tokens (`text`, `srow/scol/erow/ecol`,
   `type`). Whitespace is not a node in tree-sitter, so it disappears for free.
2. Diff the two token **text** streams.
3. For every changed token, walk up to the **smallest enclosing named node** and light
   that up. `descendant_for_range` → `while not n:named() do n = n:parent() end` gives
   it; `n:parent()` widens one step if a coarser highlight reads better.

Verified against difftastic on a file reformatted *and* edited — `opts or {}` split
across lines, a call exploded into four lines, plus `"DiffAdd"` → `"DiffAdded"`.
`git diff` calls it **8 insertions, 3 deletions**. Both difftastic and the prototype
report **exactly one change**: the string literal. The whole reformat is silent. That
is the requirement, reproduced.

**The token diff must be `vim.text.diff`, not Lua.** This is the load-bearing finding.
A hand-written LCS is fine when the edit is small — prefix/suffix trimming collapses
the DP to nothing — but it dies the moment a file changes at both ends:

| token diff of 12,226 vs 12,234 tokens (81 KB Lua) | time |
| --- | --- |
| pure-Lua LCS, edits at both ends | **2,854 ms** (150M DP cells) |
| `vim.text.diff`, `algorithm = "myers"` | 1.43 ms |
| `vim.text.diff`, `algorithm = "histogram"` | **0.58 ms** |

`vim.text.diff` is Neovim's built-in xdiff in C. It takes two strings and with
`result_type = "indices"` returns `{start_a, count_a, start_b, count_b}` hunks. Feed it
a synthetic **token-per-line document** — one token per line, newlines inside tokens
escaped — and hunk indices come back as token indices directly. Building that document
costs 6.3 ms for 12K tokens. A 5000× speedup for about fifteen lines of code.

**Cost, measured** (parse + flatten, per side, Lua):

| size | lines | tokens | time |
| --- | --- | --- | --- |
| 79 KB | 2,367 | 12,226 | 34 ms |
| 317 KB | 9,471 | 48,904 | 133 ms |
| 950 KB | 28,415 | 146,712 | 493 ms |
| 3.1 MB | 94,719 | 489,040 | 1,864 ms |

Linear, ~14 µs per 100 lines. Both sides plus the diff on the 79 KB file is **~77 ms**
total. Two things pull it down further: the **new** side is usually an open buffer whose
tree Neovim already parsed for highlighting (`vim.treesitter.get_parser(bufnr)` — free),
and `parser:parse(true, callback)` is **genuinely async** (verified: returned after
143 ms of a 224 ms parse, callback fired at 224 ms), so the big-file path never freezes
the UI and is cancellable by dropping the callback.

**Detecting "formatting only — no semantic change"** falls out with no extra work: the
token streams are identical while the bytes differ. Verified on a whitespace-only edit
of the 81 KB file — zero changed tokens, 34 ms.

**Falling back to line diff.** Three separate triggers, all cheap to test:

- *No parser.* `vim.filetype.match({ filename = path })` → `vim.treesitter.language.get_lang(ft)`
  → probe. **`vim.treesitter.language.add(lang)` is not a valid probe** — in 0.12.4 it
  returned `true` for `zig`, `haskell` and `totally_fake_lang`. Use
  `pcall(vim.treesitter.get_string_parser, "", lang)`, which fails correctly with
  `No parser for language "…"`. For a blob with no usable extension,
  `vim.filetype.match({ contents = …, filename = "blob" })` resolves a shebang.
- *Syntax errors.* `root:has_error()`. A file holding conflict markers parses to 5
  ERROR/missing nodes — its token stream is garbage, so line diff is the honest answer.
- *Size.* Above roughly **5,000 lines per side**, where both parses cross ~100 ms.

**Injections are the one real complication.** `parser:parse(true)` plus
`for_each_tree` returns a tree per embedded language with its row range — a markdown
file with one Lua fence gives `markdown 0..7`, `lua 3..4`, `markdown_inline 0..0`,
`markdown_inline 6..6`. This matters because in the **parent** tree the fence body is a
single `code_fence_content` leaf: one changed character there would light up the entire
block. So flattening has to run per-tree and splice the token lists together by byte
offset, not walk the root tree alone. Same for Vue, HTML with script tags, and SQL in
strings.

**Correcting an earlier implementation note.** The note under **Implementation notes**
said an external difftool "returns formatted text that would have to be re-parsed to
recover real line numbers". That is wrong: `DFT_UNSTABLE=yes difft --display json`
returns `aligned_lines` (lhs↔rhs line pairing) and per-line `changes` with character
`start`/`end` offsets and a highlight kind — exactly what a renderer needs. The
decision to compute in-plugin still stands, for different and better reasons: the JSON
format is explicitly unstable and gated behind an env var, it is a second binary the
user must install, it parses with difftastic's own bundled grammars rather than the
user's Neovim parsers (so "no parser → line diff" would disagree with what the editor
highlights), and it cannot reuse the tree Neovim already has for an open buffer.

**Next step:** `research: Neovim rendering primitives for diff display`.
