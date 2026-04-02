# local-review.nvim

Neovim plugin for local code review, built for use with coding agents.

## Features

Add, edit and delete comments on lines of code. Use your existing diff-viewer for diffs.

![Comment UI](./screenshots/comment_ui.png)

Ships with a [skill](./skills/local-review/SKILL.md) that tells agents how to read comments.

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
      keymaps = {
        comment = "<leader>rc",
        delete = "<leader>rd",
        next = "]r",
        prev = "[r",
        export = "<leader>re",
      },
    })
  end,
}
```

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
- `:LocalReviewExport` print all review comments for the current repository in a copy/paste-friendly format.
- `:LocalReviewClearRepo` delete all stored review comments for the current repository.

## Notes

- Comments are scoped to each repo.
  file changes under the hood.
- This was largely vibe-coded. There is likely some poor code and you may find bugs.
- Issues/PRs welcome but please open an issue before making a large change.
