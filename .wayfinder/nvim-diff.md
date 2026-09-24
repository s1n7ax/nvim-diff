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
- The separator is a **steel band**: pale text on dark blue, filled with `·` from column 1 to the window edge. Loud enough to be a landmark, calmer than amber.
- A pure reformat collapses to a single separator row on both sides — `═══ reformatted into 5 lines — no semantic change ═══` — expandable like folded context. It never costs five rows and filler to say nothing changed.
- A changed line is coloured by side, not by a third colour: red in the old pane, green in the new pane, with the changed tokens brighter inside. A wholly added line is uniform green with no bright token, which is how "new" reads differently from "edited".
- Both panes carry line numbers, each showing its own revision's numbers. They drift apart after the first hunk, which is the point.
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
- The old pane stays blank opposite an expanded thread — no mirror, no dashes. Dashed filler keeps one meaning only: a line exists on the other side that is missing here.
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
- How `virt_lines` interact with `foldmethod=diff` fold boundaries, whether `virt_lines_above` anchors the context separator better, and whether a native diff filler region can hold virtual lines at all. (Research, not a requirement — belongs to the rendering-primitives step.)
- Whether `nvim_win_set_hl_ns` or `winhl` survives a colorscheme reload better and composes correctly with treesitter highlight priorities.
- The real cost of `git worktree add` on a large repo, and whether `--no-checkout` plus a sparse checkout is worth it for big PRs.
- ~~Whether Neovim 0.12's `vim.async` covers cancellation…~~ Settled for now: `vim.async` exists only on the 0.13 nightly, so `core/job.lua` is a hand-written shim. Revisit when the minimum moves to 0.13.

- Is the "new" pane the **real, editable file buffer** (LSP attached, edits hit disk), or a read-only rendered copy? This decides whether separators and filler could be real buffer text, whether `gd`/rename/code-actions work inside the diff, and whether editing-in-the-diff is a feature at all. Everything decided so far assumes a read-only rendered copy, which is the safe superset.
- All fold rows in one window share a single background, because the colour comes from the `Folded` remap. The context separator and the reformat separator therefore differ in text only — unknown whether a `foldtext` chunk's own highlight group can carry a background over that remap.
- Should the normal fold keys (`zo`/`zc`/`zR`/`zM`) open and close context folds, or only the plugin's expand-10 / expand-all keys? They work but desync the panes unless intercepted, and intercepting them surprises people who use folds reflexively.
- Is a review tab with its own `:tcd` welcome, or intrusive?
- Exact corrector behaviour under `smoothscroll`, `splitkeep` and horizontal sync (`scrollopt+=hor`, `sidescrolloff`); whether `WinScrolled` alone catches every scroll or `WinResized`/`TabEnter` are also needed.
- Whether a merged filler extmark's `virt_lines` array can be updated **in place** cheaply enough for expand-10, or must be deleted and recreated.
- Fold creation cost at 50,000 lines with hundreds of context folds, and whether `foldmethod=expr` with a lookup table beats `manual` + `zE` for rebuilds.
- Whether treesitter's highlighter attaches cleanly to a `buftype=nofile` scratch buffer with no file on disk, and whether injections still resolve there.
- TUI paint cost with a real terminal attached — every redraw number measured so far is a headless grid-update cost.

- The `LICENSE` file says `Copyright (c) 2026 s1n7ax`. Whether that should be a legal name instead.
- The test harness has no screen-capture facility. Whether the renderer step adds the prototype's child-nvim-in-a-terminal capture to it, or verifies layout another way.
- Which parsers the structural-diff tests run against: the four a `--clean` Neovim has here (c, lua, markdown, vim), or the user's own runtimepath.

## Map

- [x] grill: requirements sweep — [result](#result-grill-requirements-sweep)
- [x] research: GitHub API surface for PR review — [result](#result-research-github-api-surface-for-pr-review)
- [x] research: structural diff with treesitter — [result](#result-research-structural-diff-with-treesitter)
- [x] research: Neovim rendering primitives for diff display — [result](#result-research-neovim-rendering-primitives-for-diff-display)
- [x] research: prior art — diffview.nvim and octo.nvim architecture — [result](#result-research-prior-art--diffviewnvim-and-octonvim-architecture)
- [x] prototype: the visual language (highlight groups, separator row, structural output) — [result](#result-prototype-the-visual-language)
- [x] implement: plugin skeleton, config, health check, test harness — [result](#result-implement-plugin-skeleton-config-health-check-test-harness)
- [x] implement: git layer — revs, merge-base, file lists, blobs, worktrees — [result](#result-implement-git-layer)
- [x] implement: line diff engine and the hunk data model — [result](#result-implement-line-diff-engine-and-the-hunk-data-model)
- [ ] implement: side-by-side renderer with scroll sync
- [ ] implement: context folding — separator row, expand 10, expand all — needs: side-by-side renderer with scroll sync
- [ ] implement: unified renderer and the layout toggle — needs: side-by-side renderer with scroll sync
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
- **The plugin does not use Neovim's native diff mode.** `vim.wo.diff` stays `false` in every plugin window; the plugin computes hunks and renders both panes itself with extmarks. (This reverses the note recorded from the prior-art step, on four measured grounds: diff highlights beat extmarks at every priority, native diff computes its own fillers and cannot be handed ours, `diffexpr` is line-level-only and global, and a native filler region cannot hold `virt_lines`.) Both diffview.nvim and octo.nvim delegate everything to native diff mode, so the renderer has **no reference implementation** and is the riskiest step on the map.
- No VCS adapter abstraction. There is a `git/` module; Mercurial support is out of scope permanently. That abstraction is ~3900 lines of diffview.
- No bespoke async framework and no FFI. `vim.system` plus Neovim 0.12 coroutines. diffview's `async.lua` reads C globals through FFI to skip a `vim.schedule` round-trip — a maintenance liability we do not inherit.
- The built-in `DiffAdd`/`DiffChange`/`DiffText`/`DiffDelete` groups are **never used**. The plugin owns its own groups, so no colorscheme can make its diff colours collide with its fold colours. diffview's `enhanced_diff_hl` solves the same problem by remapping the built-ins and is off by default; we sidestep it entirely.
- Every file's rev tuple is `{a,b,c,d}` = old/ours, new/local, theirs, base, and every layout maps the same four symbols, so one entry model serves 2-, 3- and 4-pane layouts.
- Diff buffers are named `nvim-diff://<gitdir>/<rev>/<path>` and the name is set **before** content is fetched, so concurrent requests for one blob dedupe on the name.
- Diff buffers for non-local revisions are capped by an LRU and evicted. Only working-tree buffers are exempt. diffview's unbounded accumulation is its #613 memory leak (48 GB reported).
- Historical-blob buffers are `buftype = "nofile"` to keep LSP servers off them; only the PR worktree's real files get LSP.
- `cursorlineopt` is not forced. neovim/neovim#9800 does not reproduce on 0.12.4 — `CursorLine` resolves below both diff and extmark highlights.
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
- Filler lines are `virt_lines` extmarks — one merged extmark per contiguous filler run, never one per row. A comment thread and its padding are one extmark per side per anchor row, whose `virt_lines` array is own-content followed by `max(n_left, n_right) - n_own` blanks.
- Scroll sync is a plugin-owned corrector on `WinScrolled` using `winrestview{topline, topfill}` driven by a display-row map. `scrollbind` is **off** — measured, it fights the corrector (3/200 misaligned with both, 0/200 with the corrector alone). `cursorbind` is off too; cursor correspondence comes from the hunk map, not line numbers.
- `wrap` is forced off in diff panes. A long line on one side only takes more screen rows there, which is permanent drift.
- Every diff pane gets a **header line at buffer line 1**, because `virt_lines_above` on row 0 never renders. A top-of-file hunk's filler then attaches below the header as ordinary `virt_lines`.
- The changed-line background is a **range extmark** (`end_row = row + 1, end_col = 0, hl_eol = true`), never `line_hl_group` — whose background cannot be beaten by a token highlight at any priority.
- Priority band: line background **150**, structural token **250**, both above treesitter's 100. The default extmark priority (4096) is never relied on.
- Diff highlight groups set **background only, never foreground**, so treesitter's syntax colours survive inside a changed token.
- Highlight groups live in a private namespace bound with `nvim_win_set_hl_ns`, with global `default = true` groups as the user's override surface, redefined on `ColorScheme` and on `background` change. A namespace survives `:colorscheme` and `:hi clear`; `winhighlight` survives but its targets do not.
- Context folding uses **real manual folds** with a custom `foldtext`, window-local `fillchars` `fold:═`, and a `Folded` remap for the loud colour — the colour comes from the remap, not the `foldtext` chunk. Expanding rebuilds the fold (`zE` + re-fold) and restores the view on both windows explicitly. Fold open/close is mirrored across panes and `zo`/`zc`/`za`/`zR`/`zM` are intercepted.
- `conceal_lines` is ruled out: measured, it breaks scroll sync outright, and a `virt_lines` separator on a concealed line is not drawn.
- All extmarks are **persistent**; no `nvim_set_decoration_provider`. Ephemeral marks cannot render `virt_lines`, and a decoration provider measured slower at redraw than persistent marks.
- Marks are applied eagerly and in full. Rendering is viewport-bounded and flat: 50,000 lines with 10,000 changed cost 68 ms to render and 0.049 ms/frame to scroll.
- Diff panes are `buftype=nofile`, `bufhidden=wipe`, `noswapfile`, `nobuflisted`, `undolevels=-1`, `nomodifiable`, `winfixbuf`. The file panel is created with `nvim_open_win{split="left"}` + `winfixwidth` + `winfixbuf`, not `:vsplit`.
- `statuscolumn` renders file line numbers and blanks them when `v:virtnum < 0`, offset for the header line.
- A PR review opens in its own tabpage with a tab-local cwd (`:tcd`) set to the PR worktree, so `:find`, `:grep` and terminals resolve against the PR's tree. `:tabclose` is trapped to clean up.
- The plugin never persistently sets the global options `diffexpr`, `diffopt`, `scrollopt` or `splitkeep`.
- The size threshold is a **parse and diff** threshold, not a rendering one. Rendering would not justify deferring anything under ~50,000 lines; the treesitter parse (1,864 ms at 94,719 lines) and the blob fetch are the real costs.

- Rendering colour cannot be verified through a terminal-buffer capture — `nvim_buf_get_extmarks` on a `:terminal` buffer returns nothing. Layout and text can. Colour work needs a UI attached.
- `foldminlines = 0` is a rendering invariant, not a preference: at the default of 1 a one-line fold never closes, which breaks the reformat-collapse on the old side.

- The test harness is **hand-written** (`tests/runner.lua` + `tests/harness.lua`, ~180 lines, `describe`/`it`/`expect`), not vendored mini.test — mini.test would be a second plugin checked into a repo with zero runtime dependencies. Specs are `tests/spec/*_spec.lua`, loaded with `loadfile` so test code stays out of `lua/`. The Makefile variable is `NVIM_BIN`, not `NVIM`: inside `:terminal`, `$NVIM` already holds a server socket path.
- Only the modules this step needs exist. `core/job.lua` and `core/path.lua` are **not** stubbed — they belong to the git layer. `ui/hl.lua` is built now, because a `highlights` config key with nothing to override is not a real override surface. `plugin/` holds the load guard and nothing else; a `:NvimDiff` that errors is worse than no command.
- **No `keymaps` config table yet.** Each step that adds actions adds its own keymap block, rather than twenty lhs names being invented now with nothing behind them.
- `setup()` **raises** on bad options — every problem in one message with its full dotted path — and leaves the previously active config intact. It is **not cumulative**: each call restarts from the defaults. Validation runs against a hand-written schema, not the defaults table, so an option can be valid with no default (`github.host`). `config.get()` returns the defaults when `setup()` has never run, so no module has to order itself after setup.
- The event bus is a **closed enum of exactly three names**; `on`/`emit` with an unknown name errors. `on()` returns an idempotent unsubscribe closure (no `off(handle)`). A throwing handler is caught with `xpcall`, logged at error level, and emission continues. `emit` iterates a snapshot, so a handler may unsubscribe itself mid-emit. `emit_in({win, buf}, name, ...)` delivers the "fired with the relevant buffer and window current" contract — callers must pass a matching pair, or `nvim_buf_call` may use the hidden autocmd window. **No `User` autocmd mirroring**, which would be the public hook surface the map defers.
- Highlight groups as shipped: `NvimDiff{Del,Add}{Line,Token}`, `NvimDiffContextSeparator`, `NvimDiffReformatSeparator` (links to ContextSeparator, so the two differ in text today but can diverge), `NvimDiffFiller`, `NvimDiffHeader`, `NvimDiffThread{Bar,Author,Body,Meta,Resolved}`, `NvimDiffPanel{Title,Dir,Path,Insertions,Deletions,Viewed,Rechanged,Deferred}`. The separator is dark blue `#1c3a5e` on pale `#c9d8e8`. Light-background variants are invented — nothing in the map measured a light colorscheme. The namespace remap table currently holds only `Folded → NvimDiffContextSeparator`.
- Health severities: missing `git` is an **error**; missing or unauthenticated `gh` is a **warn**, because diff, history and conflicts do not need it; zero parsers is a warn. Declared minimums are Neovim 0.12 (feature-probed via `vim.text.diff` and `&winfixbuf`) and git 2.25. `health.orphan_worktrees()` is public so `git/worktree.lua`'s startup prune uses the same matcher rather than two copies drifting.
- `LICENSES/README.md` records the working rule: diffview is never copied; MIT projects are copied only with a file-header provenance line (project, file, commit) **and** the licence text added as `LICENSES/<project>.txt`.

- Git functions return `value, err` and never raise for git-level failures; `err.kind` ∈ `not_a_repository | bad_revision | no_merge_base | not_found | not_a_blob | invalid | spawn_failed | timeout | failed`. Only `job.Cancelled` propagates as an error.
- `core/job.lua`: `job.task(fn)` runs a coroutine; `job.await(cmd)` yields inside a task and blocks outside one, so every git function serves async views and sync tests alike. `task:cancel()` kills the child. Output is raw bytes, never `text = true` (it corrupts CRLF blobs). A timeout is detected by exit 124 plus a signal, not by elapsed time.
- Git children inherit Neovim's environment (dotfiles setups rely on `GIT_DIR`/`GIT_WORK_TREE`) plus `GIT_TERMINAL_PROMPT=0`; the `gh` env allow-list does not apply to git. `git/cmd.lua` is the only place a git command is built.
- Revisions resolve to full ids up front (`label` kept for display); kinds are `commit | index(stage) | worktree`. The empty-tree id is hashed per repo (SHA-256 repos differ). A revision starting with `-` is rejected — `--end-of-options` is newer than git 2.25.
- `a...b` = merge-base, `a..b` = tip to tip, bare `a` = against the working tree, empty side = `HEAD`. `imply_local` (swap a `HEAD` right side for the worktree) is an off-by-default option on `revparse.resolve`, not in config.
- File lists are one `git diff --raw --numstat -z --no-abbrev -M --no-ext-diff --no-textconv` call. Renames are forced on. Supported pairs: commit→commit, commit→index, commit→worktree, index→worktree. A conflicted path's duplicate records merge into one `U` entry. Untracked files have status `?` and no counts. The entry type is `FileChange`, leaving `FileEntry` to the scene layer.
- **Every git call that parses diff output passes `--no-ext-diff`** — the user's own git config routes `git diff` through an external tool, and plain `git diff` printed no hunk headers.
- Blobs come from `git cat-file --batch` (exact bytes; missing/not-a-blob reported in-band). Binary = NUL in the first 8000 bytes. One process per read for now; a long-lived batch process is a later optimisation.
- PR worktree ownership lives in git: `git worktree lock --reason "nvim-diff pid <pid>"` (separate from `add`, since `add --reason` is newer than 2.25). The prune removes a `pr-*` worktree only when unlocked or locked by our reason with a dead pid. `worktree.add` replaces any existing worktree for that PR; `remove` is `--force --force`. `setup()` schedules one background prune for the cwd's repo. Worktrees live under the **shared** git dir.
- Tests build throwaway repos via `tests/gitrepo.lua` with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.

- The hunk model names sides `"old"`/`"new"` everywhere; GitHub's `LEFT`/`RIGHT` and the rev tuple's `a`/`b` map onto them. Hunk `start`/`count` follow unified-diff convention (count 0 → start is the line it sits after; 0 = top). Filler `after = 0` means above line 1; the renderer adds its header-line offset.
- `Diff` = `{old_count, new_count, rows, hunks, unchanged, fillers{old,new}, tokens{old,new}, token_source, algorithm}`. Display rows are counted **before** folding — folding and `topfill` mapping are the renderer's. Structural diff plugs in by replacing `tokens`, setting `token_source = "structural"` and `formatting_only` on hunks; the shape never changes.
- **Histogram degrades with hunk count**: 50K lines with a change every 10th line took 2,470 ms (myers: 12 ms). The engine falls back to myers when a cheap myers pre-pass gives lines × hunks > 2e7; `diff.algorithm` records which ran. The earlier "0.58 ms" figure holds only for few hunks.
- `linematch` (limit 40) runs per hunk, never in the whole-file call (937 ms whole-file on the same input), so hunks always equal what `git diff` reports. When it can't cover a hunk exactly, lines pair by position: changed pairs first, then deletions, then additions.
- `indent_heuristic` is on, matching git and GitHub. `commentable_ranges(side, context=3)` merges exactly like `git diff -U3` and is tested against git on 25 random files.
- Intra-line tokens: word runs (multi-byte safe), whitespace runs, single punctuation, diffed with the token-per-line `vim.text.diff` trick. Lines over 4,096 bytes get one span over the differing middle. `tokens[side][lnum]` exists exactly on changed lines and may be empty.
- `vim.text.diff` quirks handled: an empty array joined with a trailing newline is one empty line; a missing trailing newline on one side fakes a last-line change; a NUL arrives as `\n` and splits the line.
- The diff engine never reads `config`; callers pass options, defaults live in `line.defaults`.

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

### result: research: Neovim rendering primitives for diff display

Tested against **Neovim v0.12.4** (Release, LuaJIT 2.1.1774638290) on Linux 6.18.52.

Nearly everything here was run, not recalled. The harness drove a real child Neovim over
an RPC socket (`nvim --headless --listen`), fed it **real keystrokes through
`nvim_input`** so the actual input loop and `do_check_scrollbind` ran, then read back the
real screen grid with `screenstring()` and the resolved per-cell colours with
`nvim__inspect_cell()`. Driving `:normal!` from a script gives false answers for scroll
questions. Claims marked *(doc)* come from `:help` in the 0.12.4 runtime; everything else
is measured.

#### 1. Substrate: **drop native diff mode and render both panes ourselves**

This reverses the note recorded from the prior-art step. Four measured facts force it.

**In native diff mode, diff highlights beat extmarks at every priority.** Two `diff=true`
windows, treesitter on, an extmark painting a token background `#d75f00`:

```
priority    50 -> rendered bg #007373   stack [NDTok,String,DiffText]
priority   200 -> rendered bg #007373   stack [String,NDTok,DiffText]
priority 20000 -> rendered bg #007373   stack [String,NDTok,DiffText]   <- DiffText still wins
diff mode OFF  -> rendered bg #d75f00   stack [String,NDLine,NDTok]     <- extmark wins
```

`DiffChange`/`DiffText` are applied as the line's base attribute *after* extmark
decorations, exactly like `line_hl_group`. Priority never reaches them. **There is no
priority at which a structural token highlight is visible inside native diff mode.**

There is an escape hatch — remapping the diff groups to an *empty* group per window
restores extmark control (`winhighlight = "DiffChange:NDDiffOff,DiffText:NDDiffOff,…"`
where `NDDiffOff` is `{}`; mapping to `Normal` instead does **not** work, Normal's bg
then paints over the extmarks). But it does not save the hybrid, because:

**Native diff computes its own line hunks and fillers and cannot be handed ours.** The
point of the structural view is that a pure reformat reads as no semantic change. A
reformat that explodes one call across four lines produces three filler rows under native
diff. You can neutralise the *colours*; you cannot neutralise the *layout*. `iwhiteall`
rescues pure-whitespace edits, not re-wrapping.

`diffexpr` is the only way to feed native diff an alignment, and it is a dead end:
*(doc)* its output must be ed-style or `diff -U0` unified — **line-level only, no column
or token information**, so it structurally cannot express a token diff; it is a **global
option** (measured: `nvim_get_option_info2` says `scope = "global"`), so setting it
hijacks every `:diffsplit` the user has open; and it receives temp *file paths*, not
buffers.

**A native filler region cannot hold `virt_lines`.** OLD has 3 native filler rows
opposite NEW's `ADD1/ADD2/ADD3`. Attach a 2-line comment thread to `ADD2` and try to pad
OLD — measured, at every anchor:

```
pad BELOW old L05 (before the block)     pad BELOW old L06 (after the block)
 6 |PAD    |ADD1 |                        6 |-------|ADD1 |
 7 |PAD    |ADD2 |                        7 |-------|ADD2 |
 8 |-------|>>thr|                        8 |-------|>>thr|
 9 |-------|>>thr|                        9 |L06    |>>thr|   <- L06 faces a comment
10 |-------|ADD3 |                       10 |PAD    |ADD3 |
```

Alignment below the hunk is restored either way, but **inside the hunk the correspondence
is scrambled** — you cannot insert padding at an offset *within* a native filler block,
and `virt_lines_above` on the following line lands after the block too. The custom
renderer does it in one extmark because it owns the filler:

```lua
vim.api.nvim_buf_set_extmark(bo, ns, 4, 0, { virt_lines_leftcol = true, virt_lines = {
  {{"",""}}, {{"",""}},      -- opposite ADD1, ADD2
  {{"",""}}, {{"",""}},      -- opposite the 2 thread lines
  {{"",""}},                 -- opposite ADD3
}})
```

Measured: `ADD1↔fill, ADD2↔fill, thr↔pad, thr↔pad, ADD3↔fill` — exact, row for row.

**Rejected:** (a) native-for-alignment with overlaid structural highlights — dies on the
reformat requirement and the inline-thread requirement. (c) hybrid, native for the
raw-line toggle and custom for structural — doubles the renderer and the scroll-sync
model, makes the layout toggle a full teardown, and gains nothing, since a raw line diff
is just the structural renderer with the token pass switched off.

**What we give up:** `]c`/`[c`, `do`/`dp`, `foldmethod=diff`, `:diffupdate`-on-edit, and
`diffopt`'s `linematch`/`inline:char`. All are implementable; `linematch` is the only
genuinely useful one, and its job — pairing the most similar lines inside a hunk — is
subsumed by the token diff already chosen.

#### 2. Scroll sync and alignment

The prior-art finding reproduces, but its **mechanism is different from what was
recorded**. Two `diff=true` windows, 2 `virt_lines` under NEW line 5:

```
 5 |L05    |L05      |
 6 |L06    |>> thread|
 7 |L07    |>> thread|
...
12 |X_old  |L10      |      <- X_old@12, X_new@14. Drift 2.
```

Both windows were at `topline=1, topfill=0` — **nothing scrolled**. It is not scrollbind
equalizing toplines; it is a **filler** failure. Native diff does not know about extmark
virtual lines, so it inserts no compensating filler.

The padding fix works and composes:

| case | result |
| --- | --- |
| matching empty `virt_lines` at the same row on the other side | aligned |
| threads on both sides at *different* rows, each padded opposite | aligned |
| threads on both sides at the *same* row, unequal counts, unpadded | drift |
| same row both sides, each padded by the other's full count | aligned, but over-padded |

Correct composition rule: **per anchor row, each side emits one extmark whose
`virt_lines` array is `own_content` followed by `max(n_left, n_right) - n_own` blank
lines.** One mark per side per row keeps ordering deterministic.

**Without diff mode, `virt_lines` really are filler — `topfill` proves it.** This is the
load-bearing finding. `winsaveview().topfill` is populated by extmark virtual lines, not
only by native diff filler:

```
OLD 20C-E  OLD=f03 (21) NEW=A1 (21)  o[tl=21 tf=3] n[tl=19 tf=0]
OLD 21C-E  OLD=f04 (22) NEW=A2 (22)  o[tl=21 tf=2] n[tl=20 tf=0]
OLD 22C-E  OLD=f05 (23) NEW=A3 (23)  o[tl=21 tf=1] n[tl=21 tf=0]
```

Because `topfill` is live, `scrollbind` mostly works — a 75-operation directed sweep and
a 300-operation randomized fuzz over a 20-hunk diff gave **0 drifts**. But it is not
exact: a second fuzz with a different seed found 4 failures in 400 ops, all the same
shape — the top lands *inside* a filler block (`topfill=3`, `topfill=4`) while the other
side is at `topfill=0`:

```
scrollbind only, scrolloff=0     1/200   wn <C-d>
scrollbind only, scrolloff=8     3/200   wo zb, wo 19zt, wo 18zt
```

`zt`/`zb`/`<C-d>` position by buffer line, and scrollbind cannot express the fill offset.
Those are exactly the keys a reviewer presses to frame a hunk.

**`winrestview` accepts `topfill` and round-trips exactly** against extmark virtual lines
— measured against a 5-line filler block below line 12:

```
req topfill=0 -> topline=13 topfill=0  row1='c031'   (the real line)
req topfill=1 -> topline=13 topfill=1  row1='F007'
req topfill=3 -> topline=13 topfill=3  row1='F005'
req topfill=5 -> topline=13 topfill=5  row1='F003'   (top of the block)
```

So the renderer keeps a row map `display_index -> {topline, topfill}` per side and syncs
on `WinScrolled`:

```lua
local function sync(src, dst, smap, dmap)
  local v = vim.api.nvim_win_call(src, vim.fn.winsaveview)
  local i = index_of(smap, v.topline, v.topfill)      -- display row of src's top
  local d = dmap[i]; if not d then return end
  vim.api.nvim_win_call(dst, function()
    local dv = vim.fn.winsaveview(); dv.topline = d.topline; dv.topfill = d.topfill
    vim.fn.winrestview(dv)
  end)
end
```

Measured over 200 randomized real keystrokes at `scrolloff=8`:

| configuration | misaligned |
| --- | --- |
| `scrollbind` only | 3/200 |
| `scrollbind` + corrector | 3/200 — **they fight**, scrollbind runs after and re-scrolls |
| **corrector only, `scrollbind` off** | **0/200** |

**`cursorbind` must be off.** It syncs raw line numbers, so with a 2-line hunk above,
`30G` in OLD lands on `C28` while NEW lands on `C27`; enabling it raised the fuzz failure
rate to 25/120.

**`wrap` must be off.** A changed line that is long on one side only takes 3 screen rows
there and 1 on the other — instant, permanent drift. *(doc: `:help view-diffs` lists
`'wrap'` first among the things that break alignment.)*

**`virt_lines_above` at buffer line 1 does not render**, in either substrate:

```
extmark with virt_lines_above on row 0:
  nvim_win_text_height(all) = 10, fill = 2     <- Neovim counts them
  winsaveview() at top      = topline 1, topfill 0
  screen row 1              = "REAL1"          <- never drawn, never scrollable to
```

Native diff mode *does* render top-of-file filler (measured `topfill=3` at `topline=1`).
Extmarks cannot. Measured workaround: **give every diff pane a header line at buffer line
1** (`── a/foo.lua ──`), so a top-of-file hunk's filler attaches as ordinary `virt_lines`
below the header. `virt_lines_above` works fine mid-buffer; only row 0 is dead.

#### 3. Extmark capabilities, limits and performance

Priority range is `0..65535`, default `4096` (measured; `65536` errors).

**`line_hl_group`'s background beats any char-level `hl_group` background, at any
priority.** Measured three ways:

```
line_hl_group pri=1 + token hl_group pri=65535   -> token cell bg #1d2b1d   (the LINE colour)
hl_mode="combine" on the token                   -> token cell bg #1d2b1d   (no help)
range hl_eol pri=150 + token pri=250             -> token cell bg #d75f00   (the TOKEN colour) ✓
range hl_eol pri=250 + token pri=150             -> token cell bg #1d2b1d   (line wins, correctly)
```

**So the changed-line background must be a range extmark, not `line_hl_group`** — or
structural token highlighting is invisible. To fill to the window edge the range must
cover the EOL: `end_row = row + 1, end_col = 0` works (measured: column 60 of a 25-char
line is painted); `end_col = #line` or `#line + 1` with `strict = false` does not.

```lua
-- changed line background
vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
  end_row = row + 1, end_col = 0, hl_group = "NvimDiffChangeLine", hl_eol = true, priority = 150 })
-- structural token inside it
vim.api.nvim_buf_set_extmark(buf, ns, row, scol, {
  end_row = row, end_col = ecol, hl_group = "NvimDiffChangeToken", priority = 250 })
```

**Ephemeral marks cannot render `virt_lines`** (measured: sets without error, draws
nothing; an ephemeral `hl_group` on the same provider draws fine). **Filler therefore
cannot be produced lazily by a decoration provider.**

Marks shift correctly on edits (measured). `invalidate = true` flags a mark `invalid`
rather than dropping it.

**Performance — persistent marks beat a decoration provider, and rendering is not a
bottleneck.** Two panes, 3 marks per changed line per side, plus 3-line filler blocks:

| lines | changed | marks | set_lines | decorate | first redraw | 100×`C-D` | `win_text_height` | clear |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2,000 | 400 | 2,460 | 0.5 ms | 2.5 ms | 0.08 ms | 3.9 ms (0.039/frame) | 0.25 ms | 0.4 ms |
| 10,000 | 2,000 | 12,300 | 2.8 ms | 11.4 ms | 0.07 ms | 4.7 ms (0.047/frame) | 1.16 ms | 1.7 ms |
| 50,000 | 10,000 | 61,500 | 12.3 ms | 56.0 ms | 0.11 ms | 4.9 ms (0.049/frame) | 6.11 ms | 10.0 ms |

Isolated: 150,000 marks in a 50,000-line buffer cost **114 ms** to place and 28 ms to
clear; 10,000 `virt_lines` marks cost 13 ms. Redraw and scroll are viewport-bounded and
**flat** regardless of mark count. A decoration provider measured *slower* at redraw
(0.051 ms/frame vs 0.037 for 40,000 persistent marks) while adding the `virt_lines`
restriction. Caveat: headless Neovim computes the grid but skips terminal output, so
these are grid-update costs, not TUI paint costs.

#### 4. The separator row for folded context

**Recommendation: a real fold with a custom `foldtext`, window-local `fillchars` and a
`Folded` remap.**

```lua
vim.wo[win].foldmethod = "manual"
vim.wo[win].foldtext   = "v:lua.require'nvim-diff.render'.foldtext()"
vim.wo[win].fillchars  = "fold:═"                    -- global-local: settable per window
vim.wo[win].winhighlight = "Folded:NvimDiffContextSeparator"
vim.wo[win].foldcolumn = "0"
```

Measured, the row is genuinely full-width and uniformly coloured:

```
without winhl:  c1:-  c16:2c2e33      <- foldtext chunk uncoloured, only the fill is Folded
with winhl:     c1:d79921             <- ONE colour, column 1 to the window edge
```

The trap: **a `foldtext` chunk's own highlight group does not set the row's background** —
`Folded` does. The loud colour must come from the remap, not the chunk.

Folds + `foldtext` + filler `virt_lines` stay aligned as long as both sides carry
identical fold ranges (measured). Expanding is a rebuild — `zE` then re-issue `:a,bfold`
with the shrunken range — and **rebuilding folds resets the view** (measured: OLD stayed
at topline 11, NEW jumped to 1), so the expand handler must `winsaveview`/`winrestview`
around it on both windows.

**`conceal_lines` is ruled out — measured, it breaks scroll sync outright.** It is
otherwise ideal (60 display rows → 34, instant expansion, `win_text_height` tracks it),
but scrollbind does not account for it:

```
3 C-E from the top, identical conceal ranges on both sides:
  OLD topline 1 -> 30      NEW topline 1 -> 57
```

Also measured: a `virt_lines` separator attached to a concealed line is **not drawn** —
the anchor line isn't rendered, so neither are its virtual lines.

A real inserted separator line is rejected only conditionally: it is the simplest option
and trivially aligned, but it forecloses the pane ever being the real editable file
buffer and forces every line-number mapping through a text offset instead of a fold
range. See the fog question about editable panes.

*(doc + measured)* If a fold is open in one window and closed in the other, alignment
breaks immediately — the plugin must mirror fold state and intercept `zo`/`zc`/`za`/`zR`/`zM`.

#### 5. Highlight group strategy

**Recommendation: a private highlight namespace via `nvim_win_set_hl_ns`, plus global
`default = true` groups as the user's override surface, re-applied on `ColorScheme`.**

Measured survival:

| | after `:colorscheme default` | after `:hi clear` |
| --- | --- | --- |
| `nvim_set_hl(0, "NDB", {bg=…})` | **wiped** | wiped |
| `nvim_set_hl(ns, "NDA", {bg=…})` | **survives** | **survives** |
| `winhighlight` string | survives, but points at a wiped group | same |
| `nvim_win_set_hl_ns(win, ns)` binding | survives | survives |

**A highlight namespace is self-healing; `winhighlight` is not.** diffview's `winhl`
approach needs a `ColorScheme` autocmd to redefine every group; octo's namespace approach
needs nothing. Both compose identically with treesitter.

`default = true` semantics, measured: the **first** definition wins and a later
`default = true` never overwrites — including over a prior non-default definition. Exactly
the "ship a default the colorscheme may already have overridden" behaviour. It does not
survive `:colorscheme`, hence the autocmd.

```lua
local NS = vim.api.nvim_create_namespace("nvim-diff")
local function define()
  local dark = vim.o.background == "dark"
  vim.api.nvim_set_hl(0, "NvimDiffAddLine",  { bg = dark and "#14301a" or "#d7f5dd", default = true })
  vim.api.nvim_set_hl(0, "NvimDiffAddToken", { bg = dark and "#2f6f2f" or "#a6e8b5", default = true })
  vim.api.nvim_set_hl(0, "NvimDiffContextSeparator",
    { fg = "#101010", bg = "#d79921", bold = true, default = true })
  vim.api.nvim_set_hl(NS, "Folded", { link = "NvimDiffContextSeparator" })
end
define()
vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" },
  { pattern = { "*", "background" }, callback = define })
```

**Nesting against treesitter** (which uses priority 100 *(doc)*):

```
token hl has bg only, priority 1    -> bg: token wins; fg: treesitter's String survives  ✓
token hl has bg only, priority 200  -> bg: token wins; fg: treesitter's String survives  ✓
token hl has fg+bg,   priority 1    -> treesitter fg wins  (below 100)
token hl has fg+bg,   priority 200  -> token fg wins       (above 100)
```

**Diff highlight groups therefore set `bg` only, never `fg`**, so syntax colour survives
untouched inside a changed token — which is what makes a structural diff readable. Band:
line background **150**, token **250**, both above treesitter's 100.

On the Destination's "never confused with fold colours" demand: the separator is painted
by remapping `Folded` to a group the plugin owns, so it is by construction a different
group from `NvimDiffChangeLine`. And because the plugin renders with diff mode off, the
built-in `DiffAdd`/`DiffChange`/`DiffText`/`DiffDelete` groups are **never used at all** —
no colorscheme can make the plugin's diff colours collide with its fold colours, because
the plugin inherits neither.

**`cursorlineopt = "number"` is not needed on 0.12.4** — neovim#9800 does not reproduce:

```
diff ON,  cursorlineopt=both: stack [CursorLine,String,CursorLine,DiffText] -> bg #007373
diff OFF, cursorlineopt=both: stack [CursorLine,String,NDLine,NDTok]        -> bg #d75f00
```

CursorLine sits *below* both diff highlights and extmark highlights.

#### 6. Windows, panels and layout mechanics

```lua
local panel = vim.api.nvim_open_win(pbuf, false, { split = "left", win = 0, width = 35 })
vim.wo[panel].winfixwidth = true
vim.wo[panel].winfixbuf   = true    -- exists in 0.12; stops :e replacing the buffer
```

`nvim_open_win` with `split = "left"/"right"` returns a normal window (measured: panel at
`{0,0}` w=30, panes at `{0,31}` and `{0,66}`). **Prefer it over `:vsplit`** — explicit
anchor window, no dependence on the user's `splitright`/`splitbelow`.

Diff-pane buffer options, all measured settable: `buftype=nofile`, `bufhidden=wipe`,
`swapfile=false`, `buflisted=false`, `undolevels=-1`, `modifiable=false` (set last).
Window options: `wrap=false`, `scrollbind=false`, `cursorbind=false`,
`foldmethod=manual`, `foldcolumn=0`, `foldtext`, `fillchars`, `winfixbuf`,
`statuscolumn`, plus the highlight namespace.

**Option scopes** (measured via `nvim_get_option_info2`) — this decides what the plugin
may touch:

| option | scope |
| --- | --- |
| `fillchars`, `scrolloff` | **win (global-local)** — settable per pane without touching globals |
| `foldtext`, `conceallevel`, `winhighlight`, `statuscolumn` | win |
| `diffexpr`, `diffopt`, `scrollopt`, `splitkeep` | **global** — never set persistently |

`statuscolumn` gives file line numbers, blank on filler — measured working:

```lua
vim.wo[win].statuscolumn = '%#LineNr#%{v:virtnum<0?"    ":printf("%4d",v:lnum)}%#Normal# '
```

*(doc: `v:virtnum` is negative on virtual lines, zero on the real line, positive on
wrapped continuations.)* Real rows show numbers, filler rows blank, the fold row shows the
first folded line's number. Note it shows **buffer** line numbers — with the header line
at row 1 the plugin must offset by 1 or consult its own row map.

`WinClosed` fires with the window id in `event.match` (measured), so the plugin tears the
whole view down rather than leaving a half-layout.

**`:tabnew` per review — recommended.** Tabpages are cheap and `:tcd` works, so a review
tab can hold a tab-local cwd pointing at `.git/nvim-diff/pr-<n>`, making `:find`, `:grep`
and terminal jobs resolve against the PR's tree without disturbing the user's main tab.
Cost: an extra tabline entry, and `:tabclose` must be trapped to clean up the worktree.

#### 7. Performance ceilings

**Rendering is not the bottleneck and should not set the size threshold.** 50,000 lines
with 10,000 changed lines and 1,500 filler blocks costs 12 ms to fill the buffers plus
56 ms to decorate — **68 ms total** — with a flat 0.049 ms/frame scroll cost afterwards.
Marks are applied eagerly, in full.

The only super-linear-feeling cost is `nvim_win_text_height` over a whole buffer
(0.25 / 1.16 / 6.11 ms at 2K / 10K / 50K lines). Call it on ranges, or cache the total and
adjust it when folds and filler change — never per frame.

#### ⚠️ Contradictions with the map

**1. The prior-art step's central recommendation is reversed.** "Render with Neovim's
native diff mode" was recorded as an implementation note one step ago; it is now
withdrawn, on the four measured grounds in §1. `implement: side-by-side renderer with
scroll sync` has **no reference implementation in the ecosystem** and is the riskiest step
on the map. Budget it accordingly.

**2. The inline-comment-thread requirement is only satisfiable with a custom renderer.** A
thread on an added line — which has native filler opposite it — cannot be padded correctly
under diff mode (§1, measured). "Expanded inline, never in a floating window" and "keep
native diff mode" are mutually exclusive.

**3. "A pure reformat reads as formatting only" is unreachable under native diff**, even
with colours neutralised, because native diff still inserts filler for the changed line
counts.

**4. The size-threshold requirement is not about rendering.** 50,000 lines render in
68 ms. The threshold is a *parse and diff* threshold — the real costs are the treesitter
parse (1,864 ms at 94,719 lines, measured in the previous step) and the blob fetch plus
line diff. The existing "structural falls back to line diff above ~5,000 lines per side"
note already carries that. The separate "defer the whole file until asked" number needs
its own justification; rendering alone would not justify deferring anything under
~50,000 lines.

**5. `virt_lines_above` on buffer line 1 never renders.** Any design anchoring the first
separator or first filler block at row 0 is wrong. The header-line workaround is measured
working and is now a rendering invariant.

**6. `implement: context folding` depends on `implement: side-by-side renderer` more
tightly than the map's ordering implies** — fold ranges must be mirrored and the view
restored on both panes, which needs the row map to exist first.

**Next step:** `prototype: the visual language` — which now has a settled substrate and
must decide what the thing actually looks like.

### result: prototype: the visual language

A throwaway prototype (~600 lines of Lua, hardcoded fixture, no git and no treesitter)
rendered a real two-pane diff with extmarks, folds and highlight groups, and ran in a
**real TUI** — a child `nvim --clean` inside a terminal buffer, with every screen read
back from that buffer. Eleven variants were captured and compared side by side. The
prototype lived in the scratchpad and is gone; what it decided is below.

#### What the user chose

Four requirement answers, all now under **Requirements**: reformats collapse to one
separator row; the context separator is a steel band; a changed line is red on the left
and green on the right; the old pane stays blank opposite a thread; line numbers in both
panes.

#### The visual language, as the renderer must implement it

```
 1 ── a/lua/server/init.lua ──          │  1 ── b/lua/server/init.lua ── PR #214
 2 ··· 7 unchanged lines ··· local defaults ·········   <- steel band, col 1 to edge
 8   port    = 8080,                    │  8   port    = 9090,      <- red / green line
                                        │  ▌ alice  why 9090? …  · 2 replies · unresolved
 9   backlog = 128,                     │  9   backlog = 128,
13 ··· reformatted into 5 lines — no semantic change ···
14 end                                  │ 18 end
┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈ │ 65   M.metrics = { conns = 0, bytes = 0 }
```

| element | how |
| --- | --- |
| header, buffer line 1 | `── a/<path> ──`, range extmark `hl_eol`, priority 150. Mandatory: `virt_lines_above` never renders at row 0. |
| changed line | range extmark `end_row+1, end_col=0, hl_eol=true`, priority **150**. `NvimDiffDelLine` on the left, `NvimDiffAddLine` on the right. |
| changed token | range extmark, priority **250**, **bg only**. `NvimDiffDelToken` / `NvimDiffAddToken`. |
| wholly added line | `NvimDiffAddLine` with no token mark — "new" reads as uniform colour, "edited" as a brighter token inside. |
| missing line (filler) | `virt_lines` + `virt_lines_leftcol = true`, one chunk of `┈` × 400, `NvimDiffFiller`. Full width, unmistakably empty. |
| context separator | real fold, `foldtext` chunk, window-local `fillchars=fold:·`, `winhighlight=Folded:NvimDiffContextSeparator`. Text: `··· N unchanged lines ··· <enclosing symbol> ···`. |
| reformat separator | the same mechanism over the reflowed range — 1 line on the left, 5 on the right, both collapse to one row, so **no filler is emitted at all**. Text: `··· reformatted into N lines — no semantic change ···`. |
| comment thread | `virt_lines` on the new side, `▌` bar in `NvimDiffThreadBar`, author bold, meta dim, key hints dim. The old side gets the same **count** of empty `virt_lines`. |
| line numbers | `statuscolumn` = `%#NonText#%{v:virtnum<0\|\|v:lnum==1?"    ":printf("%4d",v:lnum-1)}%#Normal# `, per pane, each showing its own file's numbers. |

#### Measured this step

- **`foldminlines` must be 0.** It defaults to 1, and a one-line fold then never closes —
  the left side of a reformat (one long line) stayed open and raw while the right side
  collapsed. Caught on screen, fixed with `vim.wo[win].foldminlines = 0`.
- **Alignment held exactly in every one of the eleven variants** — filler, thread padding
  at 1 and 10 rows, folds of 7 / 30 / 1 lines, and the expand-10 rebuild — read off the
  real screen, not computed. The rule from the rendering step (one extmark per side per
  anchor row, own content then blanks to `max(n_left, n_right)`) is enough.
- **Collapsing a reformat removes filler entirely.** Five new lines against one old line
  normally costs four filler rows; folded, both sides are one row and the panes are
  naturally aligned. The cheapest option is also the prettiest one.
- The per-pane `statuscolumn` shows each side's own numbers and goes blank on virtual
  rows, so after the first hunk the two columns drift apart — which is the information
  the reviewer wants.
- Terminal-buffer capture gives text and layout but **no colour**: `nvim_buf_get_extmarks`
  on a `:terminal` buffer returns nothing. Colour checks need a real UI or
  `nvim__inspect_cell` with one attached.

#### The highest-risk unknown is closed

The prior-art step called native-diff-versus-custom-renderer *"the highest-risk unknown
in the project"* and left it to this step. The rendering step chose the custom renderer
on measured grounds; this step **built one and it held** — two panes, filler, folds,
per-side line numbers, 10-row inline threads and a collapsed reformat, all aligned row
for row on a real screen, with no native diff mode anywhere. `implement: side-by-side
renderer with scroll sync` still has no reference implementation in the ecosystem, but
it is no longer unproven.

#### Decisions I made, not the user

- Filler is `┈` at full width rather than blank, so "a line is missing here" and "nothing
  is here" are different marks. The thread padding is blank precisely to keep that
  distinction.
- The thread bar is `▌`, the panel's viewed marks are `✓` / `▸` / `↺`, and the deferred
  big file shows `⤷ 12,412 lines · <cr> to load`.
- Highlight group names: `NvimDiffAddLine/AddToken`, `NvimDiffDelLine/DelToken`,
  `NvimDiffContextSeparator`, `NvimDiffFiller`, `NvimDiffHeader`, `NvimDiffThread*`,
  `NvimDiffPanel*`.
- There is no `NvimDiffChangeLine` any more. A changed line is del-on-the-left,
  add-on-the-right, so the plugin ships two colour families, not three.

**Next step:** `implement: plugin skeleton, config, health check, test harness`.

### result: implement: plugin skeleton, config, health check, test harness

Branch `feat/plugin-skeleton` (commit `8f9d812`, on top of `3ca6088`). The repo has no remote, so
there is no PR. **Merge this branch into `main` before the next wave** — otherwise the git-layer and
diff-engine steps branch off a tree with no skeleton in it.

Verified here, not just claimed by the agent: `make test` → **57 passed, 0 failed in 1462 ms**,
luacheck 0 warnings, stylua clean, worktree clean.

**What landed**

| file | what it does |
| --- | --- |
| `lua/nvim-diff/init.lua` | `setup()`, `is_supported()`, and an `__index` metatable so `require("nvim-diff").config` lazily resolves submodules |
| `lua/nvim-diff/config.lua` | defaults, deep merge, spec-driven validation |
| `lua/nvim-diff/core/event.lua` | the internal bus — `on` / `once` / `emit` / `emit_in` / `clear` / `count` |
| `lua/nvim-diff/core/log.lua` | level-filtered `vim.notify` wrapper |
| `lua/nvim-diff/ui/hl.lua` | the plugin's own groups, private namespace, `ColorScheme` / `background` autocmds |
| `lua/nvim-diff/health.lua` | `:checkhealth nvim-diff`; `orphan_worktrees()` exported for the git step |
| `plugin/nvim-diff.lua` | load guard only |
| `tests/{runner,harness,minimal_init}.lua`, `tests/spec/*_spec.lua` | harness + 57 tests |
| `Makefile`, `stylua.toml`, `.luacheckrc`, `.luarc.json`, `.gitignore` | tooling |
| `LICENSE`, `LICENSES/README.md`, `README.md`, `doc/nvim-diff.txt` | MIT plus the notices convention, docs |
| `lua/nvim-diff/{git,diff,render,scene,views,github,review}/.gitkeep` | reserved dirs; the layout is documented in README |

`:checkhealth nvim-diff` was run against a real Neovim, not only unit-tested: six sections,
correctly reporting `git 2.54.0`, `gh 2.101.0`, authenticated to github.com, `4 of 19 probed
parsers installed`, no leftover PR worktrees. Laziness checked too — after startup
`vim.g.loaded_nvim_diff == 1` while `package.loaded["nvim-diff"]` is still `nil`.

**Running it**

```
make test            # nvim --clean --headless -l tests/runner.lua
make test T=pattern  # filter on the full test name
make check           # fmt-check + lint + test
```

**Config surface as shipped**

```lua
layout = "side_by_side"                  -- enum: side_by_side | unified
diff.structural = true
diff.algorithm = "histogram"
diff.normalize_comment_whitespace = true
revs.merge_base = true
thresholds.defer_lines = 50000           -- the "parse and fetch, not rendering" threshold
thresholds.structural_lines = 5000       -- the third structural-diff fallback trigger
thresholds.panel_entries = 2000          -- panel shows a summary above this
buffers.lru_size = 64
git = { bin = "git", timeout_ms = 15000 }
github = { bin = "gh", timeout_ms = 20000, host = <no default> }
highlights = {}                          -- table = attrs, string = link
log.level = "warn"
```

**Corrections and sharpenings to the map**

- The rendering-primitives result's `nvim_set_hl` sample shows
  `NvimDiffContextSeparator = { fg = "#101010", bg = "#d79921" }` — amber. It predates the prototype
  and contradicts the steel-band requirement. The code ships dark blue `#1c3a5e` on pale `#c9d8e8`;
  **that sample in the earlier result is stale.**
- The treesitter probe holds on 0.13: `pcall(vim.treesitter.get_string_parser, "", lang)` returns
  false for rust/python when absent, true for lua/c/vimdoc.
- The toolchain is **0.13.0-nightly+873fcad**, not 0.12 as some notes say. `vim.text.diff`,
  `vim.system`, `vim.uv`, `winfixbuf` and the new `vim.validate` signature are all present. The
  *declared* floor stays 0.12, which is what the code actually needs.
- `nvim -l` does not source `plugin/` for a runtimepath prepended inside the script, so nothing
  covers `plugin/nvim-diff.lua` today (it is a guard only). Once it registers commands, its test has
  to source it explicitly or start a child nvim.
- A `--clean` Neovim has only **four** parsers here — c, lua, markdown, vim. No rust, python or
  typescript. The structural-diff step has to choose between those four and the user's runtimepath.

### result: implement: git layer

Merged to `main` in `2e63503` (branch `worktree-agent-a09880161013de23c`, commit `d322d28`). `make check`: stylua clean, luacheck 0 warnings, 120/120 on the branch.

Built `core/job.lua`, `core/path.lua` (rewritten from a dead session's draft whose `normalize` was not absolute), and `git/{cmd,error,repo,rev,revparse,files,blob,worktree}.lua`; `health.lua` gained `parse_orphans(porcelain)` and lock awareness; `setup()` schedules the startup prune. Specs: `path`, `job`, `git_rev`, `git_files`, `git_worktree`, over `tests/gitrepo.lua`.

Found: `--git-common-dir` is relative before git 2.31 and is resolved manually; `--end-of-options`, `--no-relative`, `worktree add --reason` are all above the 2.25 minimum and worked around; `--raw --numstat -z` combine in one call; `git diff --cached` works before the first commit only without `HEAD`. Not done: long-lived `cat-file --batch`, parallel blob fetch, submodule handling; bare repos fail as `not_a_repository`. Decisions are under Implementation notes.

### result: implement: line diff engine and the hunk data model

Merged to `main` in `f91cfcf` (branch `worktree-agent-a480c5922299dd51e`, commit `fb4501d`). `make check`: 111/111 on the branch; 174/174 after both merges (one README conflict in the module layout, resolved by hand).

Built `diff/line.lua` (`diff(old, new, opts)` → model), `diff/hunk.lua` (model, `new`, lookups `kind`, `hunk_at`, `row_of`, `line_at`, `counterpart`, `commentable_ranges`, `is_commentable`), `diff/inline.lua` (intra-line byte ranges; from a dead session's draft, NUL handling fixed). Specs `diff_{line,hunk,inline}_spec.lua`.

With the myers fallback and per-hunk linematch, 50K lines with 5,000 hunks diff in 48 ms end to end (was 4.4 s). Decisions are under Implementation notes.

