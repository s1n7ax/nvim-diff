# Third-party notices

nvim-diff is MIT-licensed. Code taken from another project keeps its own notice, and the
notice lives here as `<project>.txt` alongside the copy.

Nothing has been copied yet, so this directory holds only this file.

## The rules this project works under

**diffview.nvim is GPL-3.0-or-later. No code from it may be copied into this repository,
in any amount, in any form.** Copying would relicense nvim-diff as GPL-3.0-or-later, which
cannot be undone without its author's consent. It is read for ideas only — architectures,
algorithms and data models are not copyrightable, and several of this project's design
decisions came from reading it. Verbatim or lightly-edited functions, its type annotations
and its config-table shape are not available to us.

**octo.nvim, gh.nvim, gitlab.nvim and neogit are MIT.** Code may be lifted from them
verbatim, provided:

1. the file that receives it says so at the top, naming the project, the file and the
   commit it came from, and
2. that project's full licence text is added here as `<project>.txt`.

The pieces currently expected to be worth lifting rather than rewriting are octo.nvim's
`gh` subprocess environment allow-list, its `--paginate` slurp shim, and its patch-hunk
parser.
