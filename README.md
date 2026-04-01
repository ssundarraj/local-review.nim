# local-review.nvim

Local review comments for Neovim, exported as plain-text feedback for coding agents.

## Features

- Open an editable review comment float for the current line
- Delete or reopen the current line's comment
- Navigate to the next or previous commented line in the current buffer
- Persist comments per Git repository under Neovim state
- Export all comments for the current repo into a scratch buffer

## Installation

Use your preferred plugin manager. Example with `lazy.nvim`:

```lua
{
  dir = "~/dev/local-review.nvim",
  config = function()
    require("local_review").setup()
  end,
}
```

## Commands

- `:LocalReviewComment`
- `:LocalReviewDelete`
- `:LocalReviewNext`
- `:LocalReviewPrev`
- `:LocalReviewExport`
- `:LocalReviewClearRepo`

## Configuration

```lua
require("local_review").setup({
  sign_name = "LocalReviewComment",
  sign_text = "●",
  storage_dir = vim.fn.stdpath("state") .. "/local-review",
  keymaps = {
    comment = "<leader>rc",
    delete = "<leader>rd",
    next = "]r",
    prev = "[r",
    export = "<leader>re",
  },
})
```
