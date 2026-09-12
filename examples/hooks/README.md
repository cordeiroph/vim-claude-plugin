# Session-panel status hooks

Optional. The session panel classifies sessions from the bottom rows of their
terminal, which cannot see work that prints nothing: a subagent, or a
background task that outlives the turn that started it. These hooks tell it
directly.

`claude-vim-status.mjs` is a Claude Code hook handler. It writes one small JSON
record per session; `g:claude_panel_hook_state` lets the panel read them. It
needs node and nothing else, and it is never installed for you — the plugin
does not edit your Claude configuration.

The file itself lives at `.claude/hooks/claude-vim-status.mjs`, where this
repository runs it on its own sessions; the copy here is a symlink to it, so
the installed example and the one being dogfooded cannot drift apart.
`settings.example.json` is byte-identical to this project's own
`.claude/settings.local.json` for the same reason.

## Install

```sh
mkdir -p ~/.claude/hooks
cp examples/hooks/claude-vim-status.mjs ~/.claude/hooks/
chmod +x ~/.claude/hooks/claude-vim-status.mjs
```

Merge `settings.example.json` into `~/.claude/settings.json` for every project,
or into a project's `.claude/settings.local.json` for one. Prefer
`settings.local.json` over `settings.json` in a shared repository: a committed
`settings.json` opts every contributor into writing these files.

Then, in your vimrc:

```vim
let g:claude_panel_hook_state = 1
```

Records land in `$XDG_RUNTIME_DIR/claude-vim-status/claude/<session-id>.json`,
or `/tmp/claude-vim-status/...` without `XDG_RUNTIME_DIR`. To move them, set
`CLAUDE_VIM_STATUS_DIR` for the writer and `g:claude_panel_hook_state_root` to
the same path — they must agree or every record goes unread.

To remove it: drop the hooks block, delete the script, and unset
`g:claude_panel_hook_state`. Leftover records expire on their own
(`g:claude_panel_hook_state_ttl_secs`) and `SessionEnd` deletes its own.

## What maps to what

The mapping is level-triggered: every registered event writes the session's
whole current state. An edge-triggered writer — one event, one state — cannot
express background work at all, and cannot hold an attention state for as long
as the prompt it describes is actually up.

| Event | State |
|---|---|
| `SessionStart` | `idle`, and the session's bookkeeping is reset |
| `UserPromptSubmit` | `active`, turn open |
| `PreToolUse`, `PostToolBatch`, `PostToolUse`, `PostToolUseFailure` | `active` |
| `PermissionRequest`, `Elicitation` | `waiting` |
| `PermissionDenied`, `ElicitationResult` | `active` |
| `Notification` `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog` | `waiting` |
| `Notification` `idle_prompt` | settles: `active` if work is outstanding, else `idle` |
| `Stop`, `StopFailure` | turn closed, then settles |
| `SubagentStart`, `TaskCreated` | `active`, one more outstanding |
| `SubagentStop`, `TaskCompleted` | one fewer outstanding, then settles |
| `SessionEnd` | the record is deleted |

Every other notification type says nothing about the session and is ignored:
`auth_success`, `agent_completed`, `elicitation_complete`,
`elicitation_response` and the `quota_auto_resume_*` types are not requests for
attention. Mapping the whole `Notification` event to `waiting`, as the first
draft of this hook did, puts a finished session in **Needs you**.

"Settles" is the difference between Idle and background work. A turn can end
while a subagent or task is still running, so the writer tracks outstanding
work by id (`agent_id`, `task_id`, `tool_use_id`) and reports `active` until
none is left. Ids are tracked rather than counted so a repeated or dropped
event cannot corrupt a count, and an entry nothing closes within 30 minutes is
dropped rather than pinning a session to Working forever.

`settings.example.json` registers `PreToolUse` and `PostToolBatch` but not
`PostToolUse`: two handler processes per tool call rather than three, since
both write the same `active`. Add `PostToolUse` if you would rather have the
extra heartbeat.

## What the records contain

```json
{"version":1,"provider":"claude","session_id":"…","state":"active",
 "updated_at":1789240000,"source":"agent-hook","event_ms":1789240000123,
 "turn":true,"pending":{"agent_1":1789240000123}}
```

A state, an id, timestamps and the outstanding-work bookkeeping. No prompt,
tool argument, transcript text or model output. `version`, `provider`,
`session_id`, `state` and `updated_at` are the contract the panel reads; the
rest is the writer's own.

The writer never fails a hook: bad input, an unwritable directory or an
unreadable record all exit 0 silently, and the panel treats a missing record as
no evidence and falls back to terminal patterns.

## Tests

`make test-hooks` (or `node test/hooks/status_writer.test.mjs`) runs the event
mapping against synthetic payloads. No Claude installation needed.

## Pi

Not implemented. `doc/design/session-panel-agent-hooks.md` has the Pi extension
contract and what is still unverified about it.
