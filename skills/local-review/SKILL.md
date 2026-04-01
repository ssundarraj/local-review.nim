---
name: local-review
description: Use this skill when you need to read or clear local-review.nvim comments.
---

# Local Review

Use this skill when the user asks to read, export, inspect, or clear `local-review.nvim` comments.

Run commands from the target repository root.

Assume the plugin is already installed in the user's normal Neovim setup.

## Read comments

```sh
nvim --headless '+LocalReviewExport' \
  +qa
```

## Clear comments

```sh
nvim --headless '+LocalReviewClearRepo' \
  +qa
```

Don't clear without the user asking. 

Once you export, you can ask the user if we can clear the comments.

Export before clearing unless the user explicitly asks to delete first.

