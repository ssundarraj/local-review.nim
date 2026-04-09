---
name: local-review
description: Use this skill when you need to read or clear local-review.nvim comments.
---

# Local Review

`local-review.nvim` is a Neovim plugin that is used to add comments to code similar to a
code review. You can read and clear comments. These are comments from the user talking to
you.

Run commands from the target repository root when working with a repo. For non-repo
files, run commands from a relevant parent directory. Assume the plugin is already
installed in the user's normal Neovim setup.

## Read comments

```sh
nvim --headless '+LocalReviewExport [path]' +qa
```

Omit path unless the user asks for a specific path.

## Clear comments

```sh
nvim --headless '+LocalReviewClear [path]' +qa
```

Omit path unless the user asks for a specific path.

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

Once you address all comments, ask the user if they want to clear the comments.
