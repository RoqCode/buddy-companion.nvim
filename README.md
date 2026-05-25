# buddy-companion.nvim

Buddy is a Neovim companion plugin prototype: a lightweight pair-programming buddy that observes
your current editor context, notices useful moments to speak up, and answers direct questions in a
rolling chat. It is meant to catch missed edge cases, new diagnostics, duplicated work, or drift from
local notes such as `.local/` without taking over the task. Buddy only starts observing after an
explicit `:BuddyStart` command and is designed as a read-only companion, not a code-writing agent.

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
  triggers = {
    personality = "normal",
    max_proactive_calls = false,
    debug = false,
  },
  notifications = {
    floating_duration_ms = 15000,
    floating_content = "full",
    floating_preview_chars = 50,
  },
})
```

## Configuration

- `additional_context` (`string | false`, default: `".local"`): workspace-relative folder with extra read-only notes. Set to `false` or `""` to disable it.
- `opencode.base_url` (`string`, default: `"http://127.0.0.1:4096"`): OpenCode daemon base URL.
- `opencode.agent` (`string`, default: `"buddy"`): OpenCode agent name used for Buddy requests.
- `opencode.timeout_ms` (`number`, default: `30000`): HTTP request timeout for OpenCode calls.
- `opencode.auto_start` (`boolean`, default: `true`): start `opencode serve` automatically when `:BuddyStart` cannot reach a daemon.
- `opencode.startup_timeout_ms` (`number`, default: `5000`): how long Buddy waits for an auto-started daemon to become healthy.
- `triggers.personality` (`"chatty" | "normal" | "almost_silent"`, default: `"normal"`): coarse proactive behavior tuning.
- `triggers.max_proactive_calls` (`number | false`, default: `false`): optional per-session cap for proactive backend calls; user questions are not counted.
- `triggers.debug` (`boolean`, default: `false`): show trigger decisions through `vim.notify`.
- `notifications.floating_duration_ms` (`number`, default: `15000`): how long proactive floating notifications stay visible; `0` disables the floating window.
- `notifications.floating_content` (`"full" | "preview" | "hidden"`, default: `"full"`): controls floating notification text. Aliases: `"partial"` = `"preview"`, `"none"` = `"hidden"`.
- `notifications.floating_preview_chars` (`number`, default: `50`): max characters used when `floating_content = "preview"`.

## Commands

- `:BuddyStart` starts a new in-memory Buddy session.
- `:BuddyStop` stops the active session and clears session state.
- `:BuddyChat` opens the rolling chat window for the current session.
- `:BuddyChatClose` closes the chat history and input windows.
- `:BuddyAsk` prompts for a user question and sends it with the current context to OpenCode.
- `:BuddyBackendHealth` checks whether the configured OpenCode daemon is reachable.
- `:BuddyBackendTest` sends the current context to OpenCode and writes the response to the chat.

Starting a session records session state, starts OpenCode if it is not already running, and registers
proactive observers for editor activity. User questions bypass proactive trigger budget and optional
proactive call limits.

The chat UI uses a read-only history window and a separate input field below it. Type into the input
field and press `<CR>` to send the question. While Buddy is working, the input field title shows a
small spinner. Close the chat with insert-mode `<Esc>`, normal-mode `q`, normal-mode `<Esc>`,
`<C-w>q`, or `:BuddyChatClose`.
`:BuddyAsk` remains available as an alternate prompt-based flow.

## Context Collection

Buddy can collect the current buffer, cursor position, diagnostics, `git diff`, and files from
`additional_context`. Files from `additional_context` are read-only inputs; small text files are
included inline, while large or sensitive files are only listed or skipped.

## Proactive Triggers

Buddy uses lane-based trigger heuristics instead of direct event triggers. Text edits, saves,
diagnostics, and TODO/FIXME/HACK markers are cheap signals that feed progress, struggle, or
self-check lanes. A lane can dispatch only after its own timing rules, the shared attention budget,
and the arbiter all agree; user questions stay outside this path.

Set `triggers.personality` to tune the coarse behavior: `"chatty"`, `"normal"`, or
`"almost_silent"`. The personality maps internally to lane thresholds, quiet windows, budget costs,
and budget regeneration; these low-level values are intentionally not public API yet.

`triggers.max_proactive_calls` is optional cost control; set it to a number to enable a per-session
maximum, or `false` for no maximum. Set `triggers.debug = true` to show trigger decisions via
`vim.notify`. `require("buddy")._trigger_state()` exposes the resolved internal trigger profile for
debugging.

## Notifications

Proactive Buddy messages are always written to chat history and can also appear in a transient floating
window. Set `notifications.floating_duration_ms` to `0` to disable the floating window.
`notifications.floating_content` accepts `"full"`, `"preview"`, or `"hidden"`; `"partial"` and
`"none"` are accepted aliases. Use
`require("buddy").status()` in a statusline to show unread proactive messages while the chat is closed.

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
