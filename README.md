# nvim-diff

A diff, file-history, merge-conflict and GitHub PR review UI for Neovim.

**Status: skeleton.** The scaffolding, configuration, health check and test harness are in
place; the diff engine, renderer and review layer are not. Nothing user-facing works yet.

## Requirements

- Neovim 0.12 or newer (`vim.text.diff`, `vim.system`, `winfixbuf`)
- `git` 2.25 or newer
- `gh`, authenticated, for PR review only
- treesitter parsers for the languages you want structural diffs in

`:checkhealth nvim-diff` reports on all of it.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "s1n7ax/nvim-diff", opts = {} }
```

`setup()` is optional — every module falls back to the defaults when it has not been
called.

## Configuration

```lua
require("nvim-diff").setup({
  layout = "side_by_side",              -- "side_by_side" | "unified"

  diff = {
    structural = true,                  -- treesitter structural diff is the default view
    algorithm = "histogram",            -- passed to vim.text.diff
    normalize_comment_whitespace = true,
  },

  revs = {
    merge_base = true,                  -- a branch diff means `main...feature`
  },

  thresholds = {
    defer_lines = 50000,                -- above this a file is listed but not loaded
    structural_lines = 5000,            -- above this per side, structural falls back to line diff
    panel_entries = 2000,               -- above this the file panel shows a summary
  },

  buffers = {
    lru_size = 64,                      -- non-local diff buffers kept before eviction
  },

  git = { bin = "git", timeout_ms = 15000 },
  github = { bin = "gh", timeout_ms = 20000 },  -- `host` for GitHub Enterprise

  highlights = {},                      -- group name -> attributes, or -> group to link to
  log = { level = "warn" },
})
```

An option that is misspelled or of the wrong type is reported by `setup()` itself, with
the full path of the offending key.

## Highlight groups

The plugin never uses `DiffAdd`, `DiffChange`, `DiffText` or `DiffDelete`. It renders with
diff mode off and owns every colour it draws, so no colorscheme can make its diff colours
collide with its fold colours. Every group it defines is `default`, so a colorscheme that
already defines one keeps it; `highlights` in the config overrides any of them.

See `lua/nvim-diff/ui/hl.lua` for the full list.

## Module layout

Dependencies point downward only: nothing in `git/`, `diff/` or `github/` knows about
windows. The empty directories are the homes reserved for the steps that fill them.

```
lua/nvim-diff/
  init.lua    setup(), public API, lazy submodule access
  config.lua  defaults, deep merge, validation
  health.lua  :checkhealth nvim-diff
  core/       event (the internal bus), log, job (vim.system + cancellable tasks), path
  ui/         hl (highlight groups and the private namespace); render, panel, tree
  git/        cmd, error, repo, rev, revparse, files, blob, worktree; log, conflict to come
  diff/       hunk, line, inline, structural, entry
  scene/      window, buffer, layout, entry, view
  render/     sidebyside, unified, fold
  views/      diff, history, conflict, review
  github/     gh, query, read, write
  review/     session, thread, threadview, sidelist, viewed
```

## Development

```
make check       # format check, lint, tests
make test        # nvim --clean --headless -l tests/runner.lua
make test T=config   # only tests whose name matches
make health      # :checkhealth nvim-diff with nothing else loaded
```

Tests need nothing but `nvim` on `$PATH`; `make lint` and `make fmt` need `luacheck` and
`stylua`.

## Licence

MIT — see [LICENSE](LICENSE). No code is copied from diffview.nvim, which is
GPL-3.0-or-later; see [LICENSES/README.md](LICENSES/README.md).
