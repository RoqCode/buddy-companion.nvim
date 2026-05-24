# buddy-companion.nvim

Buddy is a Neovim companion plugin prototype. It only starts observing after an explicit
`:BuddyStart` command.

## Local Setup

With a plugin manager, load this repository as a local plugin and call:

```lua
require("buddy").setup({
  additional_context = ".local",
  opencode = {
    base_url = "http://127.0.0.1:4096",
    agent = "buddy",
    timeout_ms = 30000,
    auto_start = true,
    startup_timeout_ms = 5000,
  },
})
```

## Commands

- `:BuddyStart` starts a new in-memory Buddy session.
- `:BuddyStop` stops the active session and clears session state.
- `:BuddyChat` opens the rolling chat window for the current session.
- `:BuddyChatClose` closes the chat history and input windows.
- `:BuddyAsk` prompts for a user question and sends it with the current context to OpenCode.
- `:BuddyBackendHealth` checks whether the configured OpenCode daemon is reachable.
- `:BuddyBackendTest` sends the current context to OpenCode and writes the response to the chat.

For now, starting a session records session state and starts OpenCode if it is not already running.
User questions and backend test calls are manual commands; background observers are not registered yet.

The chat UI uses a read-only history window and a separate input field below it. Type into the input
field and press `<CR>` to send the question. While Buddy is working, the input field title shows a
small spinner. Close the chat with insert-mode `<Esc>`, normal-mode `q`, normal-mode `<Esc>`,
`<C-w>q`, or `:BuddyChatClose`.
`:BuddyAsk` remains available as an alternate prompt-based flow.

## Context Collection

Buddy can collect the current buffer, cursor position, diagnostics, `git diff`, and files from
`additional_context`. Files from `additional_context` are read-only inputs; small text files are
included inline, while large or sensitive files are only listed or skipped.

## OpenCode Backend

`:BuddyStart` checks the configured OpenCode health endpoint. If no daemon is reachable and
`opencode.auto_start` is enabled, Buddy starts:

```sh
opencode serve --port 4096 --hostname 127.0.0.1
```

`:BuddyStop` only stops a daemon that Buddy started itself. It does not stop an already-running
OpenCode daemon.

This plugin uses OpenCode `1.15.10` routes discovered from `GET /doc`:

- `GET /global/health`
- `POST /session`
- `POST /session/{sessionID}/message`

Backend calls such as `:BuddyAsk` and `:BuddyBackendTest` may invoke the configured model and
therefore can incur provider cost or count against subscription usage limits. Starting the daemon
alone should not call a model.
