# local-review.nvim

## Bring your own review workflow

**local-review.nvim doesn't try to reinvent code review.**

There are already great Neovim tools for exploring diffs and reviewing changes — use Diffview, Neogit, CodeReview, or simply your normal buffers. `local-review.nvim` is designed to complement them by doing one small thing well: **adding inline review comments to your existing workflow.**

Leave comments directly on your code while you review it. Keep them local, export them as structured feedback for a coding agent, or submit them directly as a GitHub PR review.

It works the other way too: pull existing GitHub PR review comments into Neovim and see them alongside your own local feedback.

The idea is simple:

**Bring your own review workflow. `local-review.nvim` just adds the comments.**

```text
Diffview / Neogit / CodeReview / normal buffers
                         │
                         ▼
                 inspect your code
                         │
                         ▼
                 local-review.nvim
                      comments
                    ╱    │    ╲
                   ╱     │     ╲
              local   AI agent   GitHub
                              review
```

Use the tools you already like for navigating and understanding changes. `local-review.nvim` provides the small, composable layer between **reviewing the code** and **doing something with your feedback**.

Neovim plugin for local code review, built for use with coding agents.

## Features

<details>
  <summary>Demo video</summary>

  [Video Demo](https://github.com/user-attachments/assets/7c2d1fa2-9d4d-4660-bd1d-c044b9a86279)

</details>


Add, edit and delete comments on lines of code. Use your existing diff-viewer for diffs.

![Comment UI](./screenshots/comment_ui.png)

Use the included [skill](./skills/local-review/SKILL.md) that tells agents how to read comments.

![Review Skill](./screenshots/skill_claude.png)

## Installation

Use your preferred plugin manager. Example with `lazy.nvim`:

```lua
{
  "ssundarraj/local-review.nvim",
  config = function()
    require("local_review").setup({
      marker_text = "●",
      marker_hl = "DiagnosticHint",
      comment_box_width = 80,
      keymaps = {
        comment = "<leader>rc",
        delete = "<leader>rd",
        next = "]r",
        prev = "[r",
        export = "<leader>re",
      },
      comment_close_keys = {
        { modes = { "n" }, key = "q" },
        { modes = { "n", "i" }, key = "<C-c>" },
      },
    })
  end,
}
```

### Skill

Copy or symlink the skill into your preferred harness's skills directory.

### Telescope

If you use Telescope, you can open a picker for all review comments in the current repo:

```lua
vim.keymap.set("n", "<leader>lr", function()
  require("local_review.telescope").comments()
end, { desc = "Local Review Picker" })
```

## Commands

- `:LocalReviewComment` open the comment editor for the current line
- `:LocalReviewDelete` delete the comment on the current line
- `:LocalReviewNext` jump to the next review comment in the current file
- `:LocalReviewPrev` jump to the previous review comment in the current file
- `:LocalReviewExport [path]` print review comments for a path in a copy/paste-friendly format, then delete the exported comments. If path is omitted, it uses the current repo root when available, otherwise `cwd`.
- `:LocalReviewExportPreserve [path]` print review comments without deleting them. If path is omitted, it uses the current repo root when available, otherwise `cwd`.
- `:LocalReviewClear [path]` delete stored review comments for a path. If path is omitted, it uses the current repo root when available, otherwise `cwd`.

## Skills

- [`local-review`](./skills/local-review/SKILL.md) reads comments with `:LocalReviewExport`, which deletes exported comments by default.
- [`local-review-preserve`](./skills/local-review-preserve/SKILL.md) reads comments with `:LocalReviewExportPreserve`, which leaves comments in place.

## Notes

- The inline comment editor closes with `q` in normal mode and `<C-c>` in normal or insert mode by default. Configure those bindings through `comment_close_keys`, or remove entries to disable them.
- Comments are stored by scope root: repo root when inside git, otherwise the file's parent directory.
- Export and clear can target either a file or a directory.
- This was largely vibe-coded. There is likely some poor code and you may find bugs.
- Issues/PRs welcome but please open an issue before making a large change.
