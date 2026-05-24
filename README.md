# buddy-companion.nvim

Buddy is a Neovim companion plugin prototype. It only starts observing after an explicit
`:BuddyStart` command.

## Local Setup

With a plugin manager, load this repository as a local plugin and call:

```lua
require("buddy").setup({
  additional_context = ".local",
})
```

## Commands

- `:BuddyStart` starts a new in-memory Buddy session.
- `:BuddyStop` stops the active session and clears session state.
- `:BuddyChat` opens the rolling chat window for the current session.

For now, starting a session only records session state and enables the rolling chat. It does not
register background observers or call a backend yet.

## Context Collection

Buddy can collect the current buffer, cursor position, diagnostics, `git diff`, and files from
`additional_context`. Files from `additional_context` are read-only inputs; small text files are
included inline, while large or sensitive files are only listed or skipped.
