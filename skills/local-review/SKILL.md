---
name: local-review
description: Use this skill when you need to read or clear local-review.nvim comments.
---

# Local Review

`local-review.nvim` is a Neovim plugin that is used to add comments to code similar to a code review. You can read and clear comments.

Run commands from the target repository root. Assume the plugin is already installed in the user's normal Neovim setup.

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

## Usage

If the user invokes the skill without any additional instructions, read the comments
and proceed as this were a code review.  Some comments may be questions, some may ask
you to make concrete changes.

While responding to comments, ensure that you tell the user which comment you are
responding to. This can be by listing all comments in a numbered list or by collating
the comments with your response. Prefer listing all the comments if there are only a few 
comments.

Comments can be stale. If they are marked stale, confirm with the user before addressing
them.

