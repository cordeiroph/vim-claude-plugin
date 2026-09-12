# Evaluation: agent-native hooks for session state

Status: **Design A built for Claude Code; Pi still proposed**

Claude Code's hook contract is now verified against the published reference and
implemented in `examples/hooks/claude-vim-status.mjs`, read by the opt-in
`g:claude_panel_hook_state` path in `autoload/claude/session.vim`. §4 records
what was built and §8 what a first draft got wrong. Pi ships nothing: its
extension contract below is unchanged, and the project-local prototype now
sitting at `.pi/extensions/claude-vim-status.ts` is phase-1 shaped but
unverified and untracked (§8, phase 1).

## 1. Decision to make

The panel currently infers `active` and `waiting` from the terminal tail in
`autoload/claude/session.vim`. That is necessarily heuristic: a background
agent can be quiet, and a prompt's text can be missed or remain on screen after
work resumed.

This document evaluates an opt-in, hook-driven signal that can supplement that
classifier for Claude Code and Pi. It does **not** replace the current behavior
for users who install no external configuration.

The desired contract is deliberately small:

```json
{
  "version": 1,
  "provider": "pi|claude",
  "session_id": "agent session id",
  "state": "active|waiting|idle|closed",
  "updated_at": 1730000000,
  "source": "agent-hook"
}
```

A hook must report only facts it can know. In particular, an agent becoming
idle or settled is not automatically `waiting`: it is `waiting` only when the
agent has explicitly requested input or approval from its user.

## 2. Existing integration points

| Concern | Existing seam |
|---|---|
| Classify terminal evidence | `s:classify(tail, provider)` in `autoload/claude/session.vim` |
| Resolve final live status | `claude#session#status(id)` |
| Record provider | `claude#provider#of(rec)` |
| Per-provider settings | `claude#provider#get(name)` in `autoload/claude/provider.vim` |
| Pi provider defaults | `claude#provider#pi#spec()` in `autoload/claude/provider/pi.vim` |
| UI state groups | `autoload/claude/panel.vim` |

The existing fallback must remain authoritative when no valid fresh hook event
is available: working terminal pattern, then waiting terminal pattern, then
recent output (`active`) and finally elapsed idle timeout (`idle`). Process
liveness must remain in `claude#session#status(id)`; hook data must never turn
a dead job into a live one.

## 3. Agent capability assessment

### Pi — verified extension events

Pi supports TypeScript extensions in `~/.pi/agent/extensions/`,
`.pi/extensions/`, or paths listed in `.pi/settings.json` / global settings.
Project-local extensions require project trust. The documented extension API
provides:

- `session_start` and `session_shutdown` for lifecycle;
- `agent_start` for active agent work;
- `agent_settled` when no retry, compaction retry, or queued follow-up remains;
- `tool_execution_start` / `tool_execution_end` and `tool_call` for
  extension-owned approval gates;
- `ctx.sessionManager` for session data and `ctx.isIdle()` for runtime state.

Therefore Pi can reliably emit `active` at `agent_start`, `closed` during a
normal `session_shutdown`, and an advisory idle/settled state at
`agent_settled`. It cannot generically prove a built-in-agent request needs the
user unless a Pi extension owns that interaction. A Pi extension that presents
an approval dialog or a custom input tool can emit `waiting` immediately before
asking and `active`/`idle` when the interaction resolves.

The repository's `.pi/settings.json` currently configures only prompt paths;
it has no extension entry. Any proposal must be opt-in and must not alter that
file automatically.

### Claude Code — verified

The four questions this section used to pose are answered, from the hook
events reference at `code.claude.com/docs/en/hooks`.

**1. Which events are emitted.** Far more than lifecycle: `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
`PostToolBatch`, `PermissionRequest`, `PermissionDenied`, `Elicitation`,
`ElicitationResult`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `TaskCreated`, `TaskCompleted`, `SessionEnd`, and others this
plugin has no use for (`PreCompact`, `CwdChanged`, `TeammateIdle`, …).

**2. Stable session id.** Yes. `session_id` is a common input field on every
event above. It is the id the plugin passes as `--session-id`, so a record
matches a plugin session exactly whenever `preassign_id` is available; a CLI
too old for that flag simply never matches, which is the intended silent
fallback rather than a cwd/name guess.

**3. Background work, an explicit question, ordinary completion.** All three,
separately:

- *question* — `PermissionRequest` fires when a tool call needs a permission
  decision, `Elicitation` when an MCP server asks for input. `Notification`
  carries `notification_type`, a documented enum, whose `permission_prompt`,
  `agent_needs_input`, `elicitation_dialog` and `elicitation_url_dialog`
  members are attention requests and whose others are not;
- *completion* — `Stop` when the turn ends, `StopFailure` when it ends on an
  API error, `SessionEnd` when the session terminates;
- *background work* — `SubagentStart`/`SubagentStop` (carrying `agent_id`) and
  `TaskCreated`/`TaskCompleted`; and, for background shell tasks, a
  `background_tasks` array on `Stop` rather than any event of their own (§
  "Settling"). This is the part no terminal tail can supply, and the reason the
  transport is worth having at all.

**4. Settings and execution environment.** Project and user settings both
apply, plus `.claude/settings.local.json` for a project-local, uncommitted
entry. Handlers run in the *current* directory, which moves with `cd` and
worktrees, so a path-bearing hook must use `${CLAUDE_PROJECT_DIR}` and the exec
form (`command` plus `args`, no shell tokenization). `Notification` and most
tool events accept a `matcher`, which for `Notification` filters on
`notification_type` — so uninteresting notifications need not spawn a process
at all. A handler's failure is its own: exit 0 always, and the plugin treats a
missing record as no evidence.

## 4. Design A — per-session atomic state files

Each opt-in agent integration writes one JSON record per session to a
plugin-owned runtime directory. Vim reads only the record whose provider and
session id match the live session.

### Event flow

```
agent hook/extension → write temp file → atomic rename → Vim poll reads record
                                              ↓
                   session id + provider + timestamp + state
```

Suggested default runtime root: `${XDG_RUNTIME_DIR:-/tmp}/claude-vim-status/`.
The final path is `<root>/<provider>/<session-id>.json`. The directory must be
created with owner-only permissions; writers must reject ids containing path
separators; writes must use a temp file in the destination directory followed
by rename so Vim never parses a partial JSON file.

### Pi installation

Install an extension globally at
`~/.pi/agent/extensions/claude-vim-status.ts`, or explicitly list an extension
path in global `~/.pi/agent/settings.json`. A project-local
`.pi/extensions/claude-vim-status.ts` is possible only after the project is
trusted. The extension obtains the Pi session id from the documented session
manager API (the exact accessor must be confirmed in a prototype), writes
`active` on `agent_start`, and writes `idle` on `agent_settled`.

For `waiting`, the extension must be paired with an extension-owned approval or
question mechanism. It writes `waiting` immediately before opening the dialog,
then writes the appropriate next state in a `finally` block. It must not infer
waiting merely from `agent_settled`.

### Claude installation — as built

`.claude/hooks/claude-vim-status.mjs` is the writer, which is also where this
repository runs it on its own sessions. `examples/hooks/claude-vim-status.mjs`
symlinks to it so the shipped example cannot drift from the dogfooded one, and
`examples/hooks/settings.example.json` — byte-identical to this project's
gitignored `.claude/settings.local.json` — is the registration, documented for
installation in `examples/hooks/README.md`. The user installs it; nothing in
the plugin writes to a Claude settings file. It needs node and no other dependency, exits 0 on
every path, and writes nothing at all for events and notification types it has
no interpretation for.

The registration uses `${CLAUDE_PROJECT_DIR}` with the exec form, because
handlers run in the current directory and a relative path breaks as soon as
Claude enters a worktree. `Notification` is registered with a `matcher` so the
notification types that say nothing about a session do not even spawn a
process.

#### The mapping is level-triggered

Each registered event writes the session's **whole** current state, not a
transition. This is the central design decision and the one the first draft of
this hook got wrong (§8, phase 4).

| Event | State written |
|---|---|
| `SessionStart` | `idle`, bookkeeping reset |
| `UserPromptSubmit` | `active`, turn open |
| `PreToolUse`, `PostToolBatch`, `PostToolUse`, `PostToolUseFailure` | `active` |
| `PermissionRequest`, `Elicitation` | `waiting` |
| `PermissionDenied`, `ElicitationResult` | `active` |
| `Notification` `permission_prompt` \| `agent_needs_input` \| `elicitation_dialog` \| `elicitation_url_dialog` | `waiting` |
| `Notification` `idle_prompt` | settles |
| `Stop`, `StopFailure` | turn closed, `background_tasks` taken as the shell snapshot, then settles |
| `SubagentStart`, `TaskCreated` | `active`, one more outstanding |
| `SubagentStop`, `TaskCompleted` | one fewer outstanding, then settles |
| `SessionEnd` | record deleted |

Every other `notification_type` — `auth_success`, `agent_completed`,
`elicitation_complete`, `elicitation_response`, `quota_auto_resume_*` — is
ignored. None of them is a request for attention, and `agent_completed` in
particular reads as the opposite of one.

**Settling** is how background work stays out of Idle. The writer keeps two
pieces of derived state in the record it already owns: `turn`, true between
`UserPromptSubmit` and `Stop`, and `pending`, the outstanding subagents and
tasks. An event that ends something resolves to `active` while either is
non-empty and `idle` only when both are — so a turn that ends while a subagent
runs stays in Working, and the subagent's `SubagentStop` is what finally
settles it.

`pending` is keyed by id (`agent_id`, `task_id`, `tool_use_id`) rather than
counted, so a repeated close cannot corrupt a count and a dropped one costs one
entry rather than pinning the session to Working forever. Entries older than 30
minutes are pruned on the next event, which bounds the one payload detail the
reference does not spell out: whether `TaskCompleted` names its task with the
same field `TaskCreated` did.

Background *shell* tasks — a `Bash` call run in the background — get none of
those events. A live capture (§ "Still open") shows they are reported only as a
`background_tasks` array on `Stop`, each entry carrying `id`, `type`, `status`,
`description` and `command`. That is a snapshot rather than an edge, so the
writer treats it as the whole truth about shell work: every `shell:`-prefixed
entry is replaced by the ids currently `running`, and a task absent from the
list has finished whatever an earlier snapshot said. The prefix keeps the
replacement clear of the subagents tracked by id. No leak guard is needed —
each snapshot corrects the last — and a task that finishes wakes the session as
a fresh `UserPromptSubmit`, so the next `Stop` is what settles it to Idle.

Each event is a separate process, so two can land out of order. The record
carries `event_ms` alongside the seconds-resolution `updated_at` the panel
reads; an event that finds a newer stamp applies its bookkeeping but leaves the
newer state standing.

#### Records and the reader

The session id is the join. `session_id` is on every hook payload and is the
same id the plugin passes as `--session-id`, so a record either matches a
plugin session exactly or is ignored. A CLI without that flag never matches,
which is the intended outcome: cwd/name matching is ambiguous with concurrent
sessions and is not attempted.

### Plugin changes

| File | Change | State |
|---|---|---|
| `autoload/claude/session.vim` | `s:hook_state(rec)` validates provider/id/version/state/timestamp and treats missing, malformed, foreign, future-stamped and stale records as absent. `claude#session#status(id)` consults it after job liveness. | Built |
| `plugin/claude.vim`, `doc/claude.txt`, `README.md` | `g:claude_panel_hook_state` (off), `_root` (empty follows the writer), `_ttl_secs` (900). Installation and removal in `examples/hooks/README.md` and `claude-panel-hooks`. | Built |
| `examples/hooks/` | The Claude writer, its settings entry, and installation notes. | Built |
| `test/session_state.vader` | Reader fixtures: disabled, valid states, bad JSON, foreign provider, unknown state, stale, future-stamped, hook `closed`, root resolution, background work past the idle timer, working-beats-waiting, and liveness precedence over a fresh record. | Built |
| `test/hooks/status_writer.test.mjs`, `make test-hooks` | The event mapping against synthetic payloads; needs node, no Claude installation. | Built |
| `autoload/claude/provider.vim` | Optionally add a provider capability/config field for hook-state support and root resolution; do not add agent-specific knowledge to the registry. | Not needed yet — one writer, one provider |
| `autoload/claude/provider/pi.vim` | Declare Pi hook-state support only once the extension contract is shipped and tested. | Blocked on the Pi prototype |

### Failure and lifecycle rules

- The record is valid only when its provider and id equal the session record.
- Treat timestamps older than a configurable TTL as absent — but as a backstop
  against a writer that died mid-state, not as a freshness window. A *short*
  TTL is wrong here: hook events are edges, a permission prompt can stand for
  an hour without emitting another event, and a record therefore has to outlive
  the event that wrote it. Job liveness is established before any record is
  read and covers the ordinary crash, so the TTL can be generous (900s).
- A timestamp in the future is a broken clock, not evidence, and is ignored.
- `closed` hook data can only refine display before the next job check; job
  liveness still wins. The reader drops it outright, so the writer deletes its
  record at `SessionEnd` instead of writing `closed`.
- A record that asks for attention while the terminal says the session is
  working loses to the terminal. That contradiction means a writer missed the
  event resolving its prompt, and working-beats-waiting is already the rule
  between two terminal patterns.
- Reader errors, JSON errors, permissions errors, and unknown states are silent
  fallback to existing classification, optionally logged once for debugging.
- On normal shutdown, the writer removes its record or writes `closed`; stale
  expiry is still mandatory for abnormal termination.
- The plugin never edits agent settings, installs an extension, or deletes a
  user-managed extension. Cleanup guidance is documentation only.

### Assessment

This design has the best polling fit: the existing panel timer reads a tiny
local file, no long-lived Vim server or external process is needed, and each
provider can opt in independently. Its costs, now that it is built for Claude,
are installation burden and the handler processes themselves — two per tool
call with the registration as shipped. Stale-file handling turned out to be
less about expiry than about which events close which state; Claude
compatibility is no longer in doubt.

## 5. Design B — local status relay over a Unix-domain socket

Run a user-managed relay that accepts authenticated local messages from Claude
hooks and Pi extensions, retains the newest state per provider/session, and
serves the Vim plugin on demand.

### Event flow

```
Claude hook / Pi extension → Unix socket relay → in-memory state → Vim poll
```

Messages use the schema in §1 plus a per-user secret. The relay owns expiry and
may expose a read-only request such as `get provider session_id`.

### Installation and integration

Pi's extension location and project-trust requirements are the same as Design
A. Claude requires the same unverified hook validation. Users must additionally
start, supervise, and secure the relay (for example through their own login
manager). Vim needs a timeout-bounded socket client in
`autoload/claude/session.vim` or a helper command invoked from its polling
path.

### Failure behavior

A missing relay, connection refusal, timeout, malformed reply, or bad secret
is exactly equivalent to no hook signal: terminal patterns and idle timing
continue. The plugin must never block redraw waiting for a socket; a connection
budget shorter than the panel polling interval is mandatory.

### Assessment

The relay can provide instant updates and central cleanup, but adds a daemon,
a secret, portability issues on Windows/Vim environments, and a much larger
operational/security surface. It is unjustified for the current two-provider
plugin unless file polling demonstrably fails to meet responsiveness needs.

## 6. Design C — provider-native state only, no shared hook transport

Use Pi extensions only to improve Pi's own terminal state (for example a
stable status line), then extend Pi terminal patterns in
`claude#provider#pi#spec()`. For Claude, continue using the existing terminal
patterns. No state leaves either TUI.

This avoids external files and settings wiring in the Vim plugin, but does not
solve the core reliability problem: Vim still has to parse a terminal tail. It
also cannot deliver an unambiguous Pi `waiting` state unless the extension's UI
emits text designed solely for the parser. It is a useful short-term debugging
technique, not the preferred semantic interface.

## 7. Comparison

| Criterion | A: atomic files | B: socket relay | C: terminal-only |
|---|---:|---:|---:|
| Works with existing Vim polling | High | Medium | High |
| No long-lived extra process | **Yes** | No | Yes |
| Semantic Pi active state | High | High | Low |
| Semantic Pi waiting state | Only extension-owned prompts | Only extension-owned prompts | Low |
| Claude viability today | **Built** | Unverified | Existing fallback |
| Setup burden | Medium | High | Low |
| Failure containment | High | Medium | High |
| Security/portability cost | Low–medium | High | Low |

## 8. Recommendation and phased plan

The original recommendation was a Pi-first prototype of Design A, with Claude
gated behind verification. That gate opened first: Claude Code's hook reference
answers every question in §3, so phase 4 ran ahead of phases 1–3 and Design A
is built for Claude. Hook state is still not the default, and Pi is still
unimplemented.

### Phase 1 — contract prototype

Create a throwaway global Pi extension that writes atomic records for
`session_start`, `agent_start`, `agent_settled`, and `session_shutdown`.
Capture the exact session-id accessor and confirm it equals the id that
`claude#provider#pi#transcript_path(id, cwd)` resolves.

**Acceptance:** a Pi session changing from active to settled changes one valid
owner-only record; restart/crash leaves no state trusted beyond the chosen TTL.

An untracked prototype of exactly this shape exists at
`.pi/extensions/claude-vim-status.ts`, writing `idle`/`active`/`idle`/`closed`
for `session_start`/`agent_start`/`agent_settled`/`session_shutdown`. It has
not been run against a real Pi session, so the acceptance above is unmet — and
three things about it are known to need work before it can be:
`ctx.sessionManager.getSessionId()` is still the unconfirmed accessor of §10;
its runtime root ignores `XDG_RUNTIME_DIR`, which the Claude writer and the Vim
reader now both honour, so the two disagree wherever that variable is set; and
`session_shutdown` publishes `closed`, which the reader drops by design —
deleting the record, as the Claude writer does at `SessionEnd`, is what that
event should do.

### Phase 2 — waiting semantics

Build one extension-owned Pi approval/question interaction and emit `waiting`
only while its dialog is unresolved.

**Acceptance:** ordinary settled Pi sessions are not in Needs you; the owned
prompt enters Needs you and exits it after answer/cancel; no stale record
survives TTL.

### Phase 3 — Vim reader and tests — **done**

The disabled-by-default reader and its fixtures are in place (§4). It is
provider-agnostic, so a Pi writer needs no further Vim work: phases 1 and 2 are
the whole remaining Pi cost.

**Acceptance met:** `make test` passes with neither Pi nor Claude installed
(568 Vader assertions, 13 writer cases); enabling hook state changes only a
matching live record with valid data.

### Phase 4 — Claude feasibility gate — **done, and it passed**

The four questions in §3 are answered from the hook events reference, and the
writer is built against those answers.

**Acceptance met:** `session_id` maps one-to-one to a plugin session because it
*is* the id the plugin assigns; a missing, unreadable or unmatched record falls
back to terminal classification, which `test/session_state.vader` asserts
directly.

**Still open:** a capture from a live session (2026-09-12, a background `Bash`
call under Claude Code, logged by the writer's own `.debug-events` switch)
settled part of this. `PostToolBatch` does fire for a lone tool call. Background
shell tasks fire no `TaskCreated`/`TaskCompleted` at all — they appear only in
`background_tasks` on `Stop`, which is what the shell snapshot above now reads;
before that the session went Idle the moment the turn ended, with the task still
running. The same capture shows `prompt_id` on every event but neither
`agent_id` nor `task_id` on any, so whether `TaskCompleted` names its task with
the same field `TaskCreated` used is still unproven — it needs a session that
actually raises those two events, and until then the 30-minute prune is what
bounds a mismatch.

#### What the first draft got wrong

The first draft registered one event, `Notification`, and could emit one state,
`waiting`. It is worth recording why, because each fault points at a property
the mapping now needs:

- **nothing wrote `active`.** Background work — the one thing a terminal tail
  cannot see, and the reason for the whole transport — was structurally
  uncapturable. No event set can be trusted to cover a state machine it cannot
  express.
- **every notification meant `waiting`.** `notification_type` was never read,
  so `agent_completed` and `auth_success` put sessions in Needs you, and
  `idle_prompt` promoted a merely-idle session — a direct breach of §1's rule
  that `waiting` requires an explicit request for input.
- **`waiting` survived 15 seconds.** One edge-triggered event against a
  freshness-window TTL: a prompt that stands for an hour showed as Needs you
  for seven panel refreshes. Edge-triggered writes and a short TTL cannot both
  be right, which is what pushed the mapping to level-triggered and the TTL to
  a crash backstop.
- **a stale `waiting` outranked a working terminal**, because the reader
  consulted the record before the tail with no contradiction rule.
- **the registration was committed to `.claude/settings.json`** with a relative
  `node .claude/hooks/...` command: it opted every contributor into the writer,
  and broke as soon as Claude's cwd moved.
- **nothing removed a record**, so `/tmp` accumulated one file per session that
  ever ran.
- **the writer had no test at all.** `make test` was Vader-only and never
  executed it; the first five faults above are all visible from a synthetic
  payload.

## 9. Security, privacy, and portability

Hook extensions execute with the user's permissions. Runtime records must
contain no prompts, tool arguments, transcript text, credentials, or model
output—only the minimal status schema; the Claude writer's record holds a
state, an id, timestamps and its outstanding-work ids, and the writer test
asserts the record's exact key set so a future field cannot leak tool arguments
in unnoticed. Project-local Pi extensions require
trust and should be avoided for teams that do not want executable project
configuration; a user-global installation is safer operationally but affects
all projects. Atomic files should honor `XDG_RUNTIME_DIR` where available and
fall back conservatively; the socket design needs separate Windows support.

## 10. Open questions

Answered:

- *Does the Claude Code hook API expose both a stable session id and an
  explicit input/approval event?* Yes to both — §3, and it exposes background
  work as well.
- *Should a settled agent map to `idle` immediately or defer to the output-age
  timer?* Immediately, but only once "settled" accounts for outstanding
  background work (§4). Deferring to the timer would have kept the bug the
  transport exists to fix.

Still open:

- What exact Pi `SessionManager` method exposes the session id in the installed
  Pi version, and does it match the filename id used by this plugin?
- Is a plugin option enough for opt-in, or should each provider expose a
  separate `hook_state` capability in `g:claude_providers`? One writer and one
  provider do not justify the capability yet; a Pi writer would.
- Two handler processes per tool call is the cost of the heartbeat. Is that
  visible in practice on a slow machine, and is `PreToolUse` alone enough?
- Should the writer's 30-minute prune of unclosed background work be
  configurable, or is a constant the right answer for a leak guard?
