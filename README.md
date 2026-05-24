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

For now, starting a session only records session state. It does not register background observers
or call a backend yet.
