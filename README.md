# buddy-companion.nvim

Buddy is a Neovim companion plugin prototype. It only starts observing after an explicit
`:BuddyStart` command, which will be added in a later slice.

## Local Setup

With a plugin manager, load this repository as a local plugin and call:

```lua
require("buddy").setup({
  additional_context = ".local",
})
```

For Slice 1, `setup()` only stores configuration. It does not register background observers or
start a Buddy session.
