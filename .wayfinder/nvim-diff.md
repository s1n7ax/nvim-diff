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
- Should a file with many expanded threads **auto-switch to unified layout** when the mirrored padding gets large, or stay side-by-side however ugly it looks? Alignment holds either way; this is taste.
- Can new inline comments be posted on the **LEFT** pane at all, or is commenting right-side-only? Supporting LEFT roughly doubles the anchoring and padding cases.
- When the PR worktree cannot be created — fork not fetched, disk full, stale lock — should the review refuse to open, or open read-only from `git show` blobs with no LSP?
- Confirm **MIT** as nvim-diff's licence. If any diffview code is to be reused directly, the project must be GPL-3.0-or-later and that has to be decided now, not later.
- How `virt_lines` interact with `foldmethod=diff` fold boundaries, whether `virt_lines_above` anchors the context separator better, and whether a native diff filler region can hold virtual lines at all. (Research, not a requirement — belongs to the rendering-primitives step.)
- Whether `nvim_win_set_hl_ns` or `winhl` survives a colorscheme reload better and composes correctly with treesitter highlight priorities.
- The real cost of `git worktree add` on a large repo, and whether `--no-checkout` plus a sparse checkout is worth it for big PRs.
- Whether Neovim 0.12's `vim.async` covers cancellation, join, chain and protected await, or whether a thin shim is needed.

## Map

- [x] grill: requirements sweep — [result](#result-grill-requirements-sweep)
- [x] research: GitHub API surface for PR review — [result](#result-research-github-api-surface-for-pr-review)
- [x] research: structural diff with treesitter — [result](#result-research-structural-diff-with-treesitter)
- [ ] research: Neovim rendering primitives for diff display
- [x] research: prior art — diffview.nvim and octo.nvim architecture — [result](#result-research-prior-art--diffviewnvim-and-octonvim-architecture)
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

- nvim-diff is **MIT-licensed, and no code is copied from diffview.nvim** — diffview is GPL-3.0-or-later and copying would force nvim-diff to GPL. It is read for ideas only. Code may be lifted verbatim from octo.nvim / gh.nvim / gitlab.nvim (all MIT) provided the notice ships in `LICENSES/`.
- The diff is rendered with Neovim's **native diff mode** — `vim.wo[win].diff`, `scrollbind`, `cursorbind`, `foldmethod=diff` set per window — not a hand-rolled renderer. `:diffthis` is never called. (Subject to the structural-diff collision in contradiction 1 of the prior-art result.)
- No VCS adapter abstraction. There is a `git/` module; Mercurial support is out of scope permanently. That abstraction is ~3900 lines of diffview.
- No bespoke async framework and no FFI. `vim.system` plus Neovim 0.12 coroutines. diffview's `async.lua` reads C globals through FFI to skip a `vim.schedule` round-trip — a maintenance liability we do not inherit.
- Left and right panes get differentiated diff colours by default, via per-window highlight namespaces remapping `DiffChange`/`DiffText`/`DiffAdd`/`DiffDelete` per side. diffview has this as `enhanced_diff_hl`, off by default; ours is on.
- Every file's rev tuple is `{a,b,c,d}` = old/ours, new/local, theirs, base, and every layout maps the same four symbols, so one entry model serves 2-, 3- and 4-pane layouts.
- Diff buffers are named `nvim-diff://<gitdir>/<rev>/<path>` and the name is set **before** content is fetched, so concurrent requests for one blob dedupe on the name.
- Diff buffers for non-local revisions are capped by an LRU and evicted. Only working-tree buffers are exempt. diffview's unbounded accumulation is its #613 memory leak (48 GB reported).
- Historical-blob buffers are `buftype = "nofile"` to keep LSP servers off them; only the PR worktree's real files get LSP.
- Diff windows set `cursorlineopt = "number"` — `cursorline` overrides diff highlighting (neovim/neovim#9800).
- Every git invocation carries `--no-optional-locks` and `-c core.quotePath=false`, plus `-c gc.auto=0` for log. diffview omits the first and it causes measurable lock contention (its #535, ~1 s to stage a file).
- The file panel is subject to the same size threshold as file content: above it, a summary rather than the full tree.
- The conflict parser returns regions, the region under the cursor, and the cursor's region index in a single tolerant pass; a repeated marker flushes a partial region rather than erroring.
- File history streams: one `git log` with NUL record separators, records through an async stream, panel re-rendered on a 15 fps throttle, cancellable by a signal. Malformed records are retried per-commit twice, then skipped with a warning.
- Refreshing a file list morphs the existing list via an edit script keyed on `(path, oldpath)` rather than rebuilding, so buffers for unchanged entries survive.
- GraphQL is sent with `-F`/`-f` variables only; query text is never built with `string.format`. Every GraphQL call carries `X-Github-Next-Global-ID: 1`.
- The `gh` subprocess gets an explicit environment allow-list, not Neovim's inherited environment.
- Two internal events exist from the skeleton step — `diff_buf_ready(bufnr, ctx)` and `view_opened`/`view_closed`, each fired with the relevant buffer and window current. A public user-facing hook table is deferred.
- Marking a file viewed is one action that posts to GitHub and jumps to the next unviewed file. octo has these as two separate actions.
- `diff/hunk.lua` owns `commentable_ranges(side)`, derived from our local line hunks, and the comment keymap is gated on it. Structural diff never changes commentable ranges.
- `git/worktree.lua` prunes orphaned `.git/nvim-diff/pr-*` worktrees at startup, and the health check reports them.

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
- Only REST posts a comment _immediately_. The GraphQL `addPullRequestReviewThread`
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

Verified against difftastic on a file reformatted _and_ edited — `opts or {}` split
across lines, a call exploded into four lines, plus `"DiffAdd"` → `"DiffAdded"`.
`git diff` calls it **8 insertions, 3 deletions**. Both difftastic and the prototype
report **exactly one change**: the string literal. The whole reformat is silent. That
is the requirement, reproduced.

**The token diff must be `vim.text.diff`, not Lua.** This is the load-bearing finding.
A hand-written LCS is fine when the edit is small — prefix/suffix trimming collapses
the DP to nothing — but it dies the moment a file changes at both ends:

| token diff of 12,226 vs 12,234 tokens (81 KB Lua) | time                         |
| ------------------------------------------------- | ---------------------------- |
| pure-Lua LCS, edits at both ends                  | **2,854 ms** (150M DP cells) |
| `vim.text.diff`, `algorithm = "myers"`            | 1.43 ms                      |
| `vim.text.diff`, `algorithm = "histogram"`        | **0.58 ms**                  |

`vim.text.diff` is Neovim's built-in xdiff in C. It takes two strings and with
`result_type = "indices"` returns `{start_a, count_a, start_b, count_b}` hunks. Feed it
a synthetic **token-per-line document** — one token per line, newlines inside tokens
escaped — and hunk indices come back as token indices directly. Building that document
costs 6.3 ms for 12K tokens. A 5000× speedup for about fifteen lines of code.

**Cost, measured** (parse + flatten, per side, Lua):

| size   | lines  | tokens  | time     |
| ------ | ------ | ------- | -------- |
| 79 KB  | 2,367  | 12,226  | 34 ms    |
| 317 KB | 9,471  | 48,904  | 133 ms   |
| 950 KB | 28,415 | 146,712 | 493 ms   |
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

- _No parser._ `vim.filetype.match({ filename = path })` → `vim.treesitter.language.get_lang(ft)`
  → probe. **`vim.treesitter.language.add(lang)` is not a valid probe** — in 0.12.4 it
  returned `true` for `zig`, `haskell` and `totally_fake_lang`. Use
  `pcall(vim.treesitter.get_string_parser, "", lang)`, which fails correctly with
  `No parser for language "…"`. For a blob with no usable extension,
  `vim.filetype.match({ contents = …, filename = "blob" })` resolves a shebang.
- _Syntax errors._ `root:has_error()`. A file holding conflict markers parses to 5
  ERROR/missing nodes — its token stream is garbage, so line diff is the honest answer.
- _Size._ Above roughly **5,000 lines per side**, where both parses cross ~100 ms.

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

### result: research: prior art — diffview.nvim and octo.nvim architecture

Read the actual source of both, plus three secondary plugins. Commits read:

| repo | commit | date | license |
| --- | --- | --- | --- |
| `sindrets/diffview.nvim` | `4516612fe98ff56ae0415a259ff6361a89419b0a` | 2024-06-13 | **GPL-3.0-or-later** |
| `pwntester/octo.nvim` | `af2411604b51cb4a0f3e2de50b1b7cacc2581c48` | 2026-08-28 | MIT |
| `NeogitOrg/neogit` | `5adc81b26232954cd7a90f158aa7844c18fc3165` | — | MIT |
| `ldelossa/gh.nvim` | `6f367b2ab8f9d4a0a23df2b703a3f91137618387` | — | MIT |
| `harrisoncramer/gitlab.nvim` | `3ece95dbcf9b2e21fabd5b88b64e3639e02d5402` | — | MIT |

File references below are `path:line` within the commit named above.

#### The finding that reframes the project

**diffview does not compute or render the diff. Neovim's native diff mode does all of
it.** `:diffthis` is never called anywhere in the codebase; diff mode is a *window
option* set through a winopts table — `diff = true, scrollbind = true, cursorbind =
true, foldmethod = "diff", foldlevel = 0` (`vcs/file.lua:83-98`, applied at
`scene/window.lua:274`). Filler lines, intra-line `DiffText`, and context folding are
all xdiff inside Neovim. diffview supplies two buffers and gets the rest free. Its own
Myers implementation (`diff.lua`) is used for exactly one thing: morphing the old file
list into the new one on refresh (`diff_view.lua:386`). Never for content.

octo does the same, and inherits diffview's scroll-sync trick verbatim — find the
window with the most lines, `nvim_win_call` it, press `<c-e><c-y>` (a scroll down then
up), because `:syncbind` is unreliable (`diffview scene/layout.lua:281`, `octo
reviews/file-entry.lua:366`).

That is the single biggest saving available to this project, and it is also the source
of the biggest risk — see the contradiction section below.

#### diffview: the data model worth copying

Five nested classes:

```
View (scene/view.lua:31)                     owns a tabpage
 └ StandardView                              view + one Panel + a current Layout
    ├ DiffView (scene/views/diff/diff_view.lua:49)
    └ FileHistoryView
FileEntry (scene/file_entry.lua:45)          ONE FILE across revs: path, oldpath,
                                             RevMap{a,b,c,d}, status, stats, a Layout
 └ Layout (scene/layout.lua:19)              N Windows; Diff1/Diff2Hor/Diff3Mixed/Diff4Mixed
    └ Window (scene/window.lua:27)           winid + a vcs.File; owns winopt save/restore
       └ vcs.File (vcs/file.lua:47)          a bufnr for (path, rev)
```

The abstraction doing the most work is **`FileEntry` = file × revision-tuple ×
layout**, with the symbol scheme `a` = old/ours, `b` = new/local (always the "main"
window), `c` = theirs, `d` = base. Every layout maps the same four symbols, so one
entry model serves 2-, 3- and 4-pane layouts; switching files keeps the windows and
swaps only the bound file (`layouts/diff_2.lua:46`); switching layout reuses existing
buffers where symbols match (`file_entry.lua:108`); and one predicate `should_null(rev,
status, sym)` (`diff_2.lua:66`) decides which panes get the shared null buffer.

Buffer identity is the buffer *name*: `diffview://<gitdir>/<context>/<path>`, and it is
set **before** the async `git show` returns (`vcs/file.lua:239-251`) so two requests for
the same blob cannot both create a buffer. Local files reuse the user's real buffer
(`file.lua:157`), which is what makes the working-tree side editable.

The file panel is a **declarative component tree**, not string building
(`renderer.lua:43-528`): components carry a `context` (the `FileEntry` or `DirData`),
`process_component` assigns each one its line range, `get_comp_on_line` does hit-testing
so every panel action is "find the component under the cursor", and
`create_cursor_constraint` clamps `j`/`k` to skip headers and blank lines. The tree also
does directory flattening — a chain of single-child dirs collapses to one `a/b/c` row
(`file_tree.lua:117-130`).

The git layer: `RevType = LOCAL | COMMIT | STAGE | CUSTOM`, empty-tree SHA
`4b825dc642cb6eb9a060e54bf8d69288fbee4904` as the left side of an added file
(`git/rev.lua:11`). `main...feature` is resolved **eagerly to two SHAs** by
`symmetric_diff_revs` (`git/init.lua:1334`) — `git merge-base` for the left, `rev-parse`
for the right. `imply_local` (`git/init.lua:1464`) swaps a side to `LOCAL` when its SHA
equals HEAD, so you diff the live working tree and the buffer stays editable. Binary
detection is a trick worth stealing: `git grep -I --name-only -e . <rev> -- <path>`,
where `-I` skips binaries so a non-zero exit means binary-or-missing
(`git/init.lua:1908`).

File history is a streaming pipeline and the most sophisticated thing in the plugin: one
`git log` with a **NUL byte as record separator on its own line** (`git/init.lua:573`),
records pushed through an async stream, the worker yielding to the scheduler every 1/15 s
(`git/init.lua:903-916`), the panel re-rendered on a 15 fps throttle
(`file_history_panel.lua:214`), cancellable by a `Signal`. It validates each record
(`#namestat == #numstat`) and, because git omits stat data for some large commits and
merges, re-runs `git show` for that one SHA up to twice before warning and skipping
(`git/init.lua:938-982`). `--follow` is added only for single files
(`git/init.lua:389`), and **there is no marker in the panel where the trail crossed a
rename** — one of our requirements that diffview does not meet.

Merge conflicts: layout `Diff4Mixed` is OURS | BASE | THEIRS on top, editable result
below, labelled via `winbar` (`scene/file_entry.lua:180`). "Theirs" is found by probing
`.git/` for `MERGE_HEAD`, `REBASE_HEAD`, `REVERT_HEAD`, `CHERRY_PICK_HEAD` in that order
(`git/init.lua:297`). `parse_conflicts` (`vcs/utils.lua:484-604`) is a single tolerant
forward pass that returns three things at once — all regions, the region under the
cursor, and the cursor's region index (0 before the first, `#+1` after the last, which
is what makes next/prev wrap correctly). It handles a missing base, a missing `=======`,
and **flushes a partial region when a marker repeats** instead of throwing. Applying a
choice is a plain buffer splice; "resolve all" loops regions maintaining a running line
offset (`actions.lua:348-390`).

#### octo: the comment-thread design we are not using, and why

**octo does not use virtual lines. It steals one of your two diff panes.**
`show_review_threads` (`reviews/thread-panel.lua:9`) is driven by a broad `CursorHold`
autocmd; it collects threads matching the cursor line and side, grabs **the opposite
window** (`file-entry.lua:177`), swaps a rendered markdown buffer into it, and calls
`vim.cmd [[diffoff!]]` (`thread-panel.lua:84`). Moving off the line puts the buffer back
and re-enables diff mode, saving and restoring the cursor around it because the
scroll-sync nudge moves it.

The costs are visible in their tracker: you lose half the diff while reading a comment
(**#715** asks for our design), diff mode is torn down and rebuilt on every cursor move
(**#1518**), and nothing is expandable in place. In the diff buffer itself octo places
only signs plus one right-aligned `virt_text` summary per thread
(`reviews/file-entry.lua:483-491`).

**No plugin in this set uses `virt_lines` for review threads.** `grep -rn virt_lines`
returns zero hits in octo, gh.nvim, gitlab.nvim and diffview. Our expand-in-place design
is unexplored territory in this ecosystem.

Threads anchor by `(diffSide, path, startLine..line)` as plain integers, re-derived on
every render, never extmark-tracked — which works only because diff buffers are
`modifiable = false`. `strict = false` is passed on every thread extmark
(`file-entry.lua:489`) because the anchor line may not exist in the current commit.
**Outdated threads are dropped entirely** (`reviews/init.lua:318-320`), and open issue
**#877** asks for them back — direct validation of our side-list requirement.

octo's GitHub layer is `gh` CLI via `plenary.job`, same choice as ours. Three details
worth lifting: an explicit **environment allow-list** for the subprocess
(`gh/init.lua:23-39`) rather than inheriting Neovim's env; hostname resolution as
explicit option → config → git remote, with `--hostname` appended only when it is not
`github.com` (`gh/init.lua:214-232`); and **`X-Github-Next-Global-ID: 1`** on every
GraphQL call (`gh/init.lua:220`), which opts into the new node-ID format — without it
you get legacy ids that are being phased out, and our design bridges ids constantly.

What to avoid there: octo builds some mutations by `string.format` **into the query
text** — `resolveReviewThread(input: {threadId: "%s"})` (`mutations.lua:31`),
`submitPullRequestReview(… body: """%s""")` (`mutations.lua:168`) — defended only by an
`escape_char` that escapes backslashes (`utils.lua:1091`). A review body containing `"""`
breaks the query. Newer code passes `-F key=value`; only that path is safe.

octo's review model is the server-side **pending review**: `Review:start` creates a
PENDING review via `addPullRequestReview` and everything hangs off its id
(`reviews/init.lua:86`). Commenting is refused outright without one
(`reviews/init.lua:546-550`). That single decision produces **#570** (double-posting),
**#823** (cannot reply while a review is in progress) and **#1409** (cannot add inline
comments during a review). Our immediate-posting requirement removes all of it.

#### Secondary prior art

- **neogit has no merge-conflict UI of its own** — it prompts with `vim.fn.confirm` and
  delegates resolution to diffview or codediff.nvim. diffview's 3/4-way merge tool is
  the ecosystem's only real answer.
- **gitlab.nvim uses diffview as its diff engine** (`DiffviewOpen --imply-local`) and
  anchors discussions as **`vim.diagnostic` entries** in the diff buffer, with bodies in
  a separate panel. That buys `]d` navigation and a loclist for free. It fights our
  "expand in place, no floats" requirement, but diagnostic-namespace-as-anchor is worth
  remembering if extmark bookkeeping gets hairy.

#### Licensing — this constrains every implement step

**diffview.nvim is GPL-3.0-or-later.** Copying any non-trivial amount of its Lua would
make nvim-diff GPL-3.0-or-later, which is an adoption barrier for a Neovim plugin and
cannot be undone later without the author's consent. The rule is therefore: **read
diffview for ideas, write everything from scratch.** Architectures, algorithms, the
`a/b/c/d` symbol scheme, "use native diff mode", the shape of the conflict parser's
state machine — all fine, ideas are not copyrightable. Verbatim or lightly-edited
functions, its type annotations, its config-table shape — not fine. Short factual
constants (the empty-tree SHA, the four conflict-marker patterns, git flag sets) are
fine.

Note the precedent in the other direction: octo.nvim (MIT) heads two files with "Heavily
derived from `diffview.nvim`" (`reviews/file-entry.lua:1-2`, `reviews/layout.lua:1-2`),
and those files are structurally very close to diffview's. **That is a licence conflict
in octo, not permission for us.**

octo, neogit, gh.nvim and gitlab.nvim are MIT, so verbatim reuse is allowed provided the
notice ships with it in `LICENSES/`. Shortlist actually worth lifting rather than
rewriting: the `gh` env allow-list, the `--paginate` slurp shim (`gh/init.lua:170`), and
the patch-hunk parser (`utils.lua:1572`).

#### Gaps — what the Destination needs that neither plugin does

| Gap | Would their architecture accommodate it? |
| --- | --- |
| Structural / treesitter diff | **Fights it hard.** Both delegate 100% to native diff mode, which bundles hunks + fillers + folds and cannot be handed a precomputed alignment. See contradiction 1. |
| Context folding with an expandable separator row | Half. `update_patch_folds` (`scene/file_entry.lua:214-269`) merges unchanged regions into manual folds, but only in `-L` mode, with a plain `foldtext` and no expand action. "Expand 10 more" means mutating fold ranges **symmetrically in both panes** or alignment breaks. |
| No-local-state review | Ours is strictly simpler. Nothing to port. |
| Worktree checkout | **Nobody does this.** octo runs `gh pr checkout` in the user's working tree after a confirm prompt (`utils.lua:683`). Entirely new ground — and the cleanest part of our design, since at `headRefOid` a RIGHT-side thread line maps 1:1 to a buffer line. |
| Immediate standalone comment posting | Nobody. Simplifies everything except commentable ranges — see contradiction 2. |
| Expand-in-place virtual-line threads | Nobody, in any of the five. New ground with a measured obstacle — see contradiction 3. |
| Rename marker in the history panel | Trivial on top of data diffview already tracks (`oldpath`). |
| One key that marks viewed *and* jumps | octo has the two halves as separate actions; collapsing them is trivial. |

#### Proposed module decomposition

Feeds `implement: plugin skeleton`. Dependencies point downward only; nothing in `git/`,
`diff/` or `github/` knows about windows.

```
lua/nvim-diff/
  init.lua      setup(), public API, lazy module accessors
  config.lua    defaults, validation, keymap tables, size thresholds
  health.lua    git version, gh presence + auth, treesitter parsers
  command.lua   :NvimDiff* commands, arg parsing, completion

  core/     job (vim.system wrapper), event (tiny emitter), log (+ PerfTimer), path
  git/      repo, rev, revparse (merge-base / tip-to-tip / imply_local), files,
            blob, log (streaming NUL-delimited + -L), conflict, worktree
  diff/     hunk (+ commentable_ranges), line (vim.text.diff), structural
            (treesitter token stream), entry (FileDiff)
  ui/       hl (per-window namespaces), render (component tree + hit-test),
            panel, tree (path tree + flattening + status rollup)
  scene/    window, buffer (naming + LRU eviction), layout (validate/recover/
            sync_scroll), layouts, entry (FileEntry), view
  render/   sidebyside (native diff mode, mirrored padding, scroll sync),
            unified, fold (separator row, expand 10, expand all, symmetric)
  views/    diff, history, conflict, review
  github/   gh (exec, hostname, env allow-list, headers), query (variables only),
            read (GraphQL), write (REST post/reply + GraphQL resolve/viewed)
  review/   session (in-memory, no persistence), thread, threadview
            (collapsed summary + expanded virt_lines + mirrored padding),
            sidelist, viewed
```

Build order matching the map: `core` + `config` + `health` → `git/repo,rev,revparse,blob`
→ `diff/line,hunk,entry` → `scene` + `render/sidebyside` → `render/fold` →
`render/unified` → `ui/tree` + panel → `views/diff` → `diff/structural` → `git/log` +
`views/history` → `git/conflict` + `views/conflict` → `github/*` → `git/worktree` +
`review/*` → `views/review`.

#### ⚠️ Contradictions with the map

**1. "Structural diff is the default view" collides with using native diff mode, and
neither plugin can advise.** Native diff mode computes its own line hunks, fillers and
folds internally; you cannot hand it a precomputed alignment. Three resolutions: (a)
keep native diff for alignment/fillers/folding and overlay structural highlights as
extmarks — cheapest, but line hunks stay native, so a pure reformat still shows as
changed *lines* even when nothing is highlighted, which weakens the "formatting only"
requirement; (b) compute everything ourselves and turn native diff off — full control,
but we reimplement filler lines and alignment, the exact work using native diff was
meant to avoid; (c) hybrid — native for the raw-line toggle, custom for structural. The
map currently assumes (a) and (b) are both true. **This is the highest-risk unknown in
the project** and must be resolved in `prototype: the visual language`, informed by
`research: Neovim rendering primitives`.

**2. Commentable line ranges must now come from our own hunks.** octo enforces
GitHub's "inline comments only on diff lines" rule client-side, deriving ranges from the
`patch` field of `/pulls/{n}/files` (`utils.lua:1572`) and refusing otherwise
(`reviews/init.lua:446-449`). We ruled that endpoint out and compute the diff locally —
correctly — but that has an unrecorded consequence: `diff/hunk.lua` must expose
`commentable_ranges(side)` and gate the comment keymap on it, and the POST error path
must distinguish "line not in diff" (stale base, force-push between fetch and post →
tell the user to refetch) from other 422s. Note also that **structural diff changes
which lines light up but must not change commentable ranges** — those always follow the
line hunks.

**3. `virt_lines` break side-by-side alignment.** Measured on Neovim 0.12.4: with two
`diffthis` windows under `scrollbind`, two virtual lines added under line 5 of the right
buffer only put buffer line 10 at screen row 6 on the left and 8 on the right.
`scrollbind` equalizes toplines, not content below a virtual line. Verified fix: place
an equal count of empty padding `virt_lines` at the same buffer line in the other pane —
alignment is then exact. So every thread render is a **paired** operation, collapse and
expand must update both sides atomically, threads on LEFT and RIGHT at overlapping
positions need their padding composed rather than summed, and **the context-folding
separator row has the same constraint** if built from virtual lines. Unified layout has
none of this problem, which is a point in its favour for heavily-commented files.

**4. "The plugin keeps no local state" vs. the PR worktree.** The worktree is state on
disk. It is not *review* state, so the requirement stands, but the plugin now needs
orphan cleanup: after a crash or `:qa!` the worktree survives. `git worktree list` +
prune of stale `nvim-diff/` entries belongs in `git/worktree.lua` and in the health
check.

**5. diffview.nvim is effectively unmaintained** — last commit 2024-06-13, over two
years ago, 106 open issues including a memory leak reaching 48 GB (#613) and a hard
freeze on file history (#552). There is an actively-patched fork
(`dlyongemallo/diffview.nvim`). This strengthens the Destination: the incumbent is
abandoned, not merely imperfect.

**6. `enhanced_diff_hl` already exists in diffview and is `false` by default**
(`config.lua:41`). The mechanism our "diff colours never confused" requirement needs is
in the incumbent — just opt-in and undiscoverable, which is why issue #595 exists. Our
differentiator is **the default**, not the capability. Say that plainly in the README
rather than claiming invention.

**Next step:** `research: Neovim rendering primitives for diff display` — which now
carries contradictions 1 and 3 as its two load-bearing questions. The verification
scripts are at `…/scratchpad/vt.lua` and `vt2.lua`.
