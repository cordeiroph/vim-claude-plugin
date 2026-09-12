# Proposal: distinguish background work from idle sessions

Status: **proposed**

## Problem

The session panel must answer two different questions accurately:

1. Is a live Claude process still doing work in the background?
2. Is that process blocked waiting for the user?

A quiet terminal alone cannot answer either question. The fallback in
`claude#session#status()` (`autoload/claude/session.vim`) uses
`last_active` and `g:claude_panel_idle_secs`; consequently, a process that is
still running but emits no terminal output long enough is displayed as `idle`.
That makes background work look indistinguishable from a genuinely inactive
session. Likewise, a question or permission prompt can be hidden in `Idle`
instead of being surfaced as an actionable item.

This is particularly harmful when multiple sessions run concurrently: the panel
is meant to show which sessions need intervention and which are progressing,
not merely which terminals printed recently.

## Goals

- Give sessions waiting for an answer a distinct, top-level **Needs you**
  group.
- Keep a background-running session out of **Idle** whenever available session
  state says it is working.
- Preserve the existing terminal polling model; do not add a separate external
  process or require changes to the user's Claude configuration.
- Retain a conservative fallback for terminals whose output cannot be
  classified.

## Non-goals

- Provide a guaranteed semantic process-state API for every Claude version.
- Add notifications, popups, or automatic focus changes.
- Change session creation, persistence, or the place-oriented tree exposed by
  `claude#session#tree()`.

## Recommended status model

Use four displayed states, in this fixed group order:

| Status | Panel group | Meaning |
|---|---|---|
| `waiting` | Needs you | The terminal currently presents a prompt, choice, confirmation, or other user-input request. |
| `active` | Working | The job is running and the terminal indicates active work, including work continuing in the background. |
| `idle` | Idle | The job is running, but neither a waiting nor working signal is visible and no output has arrived within the idle interval. |
| `closed` | Done | No usable terminal/job remains, or the job is no longer running. |

`Needs you` should appear before `Working`, `Idle`, and `Done`. Empty groups
may be omitted, except that `Done` may remain visible but folded when closed
records exist. The panel header should report the number of `waiting` sessions
so attention-required work is visible in either panel view.

### Classification precedence

`claude#session#status(id)` should continue to reject missing records, missing
terminal buffers, and non-running jobs as `closed`. For a running job, classify
in this order:

1. A current working signal means `active`.
2. A current input-request signal means `waiting`.
3. If neither is recognized, recent terminal output means `active`.
4. Otherwise return `idle`.

Working must outrank waiting if stale prompt text and a current spinner coexist
in the sampled terminal tail. This avoids retaining a session in `Needs you`
after the user has answered and Claude has resumed.

The terminal tail is intentionally the primary signal. `s:term_tail()` already
reads the bottom rows during polling, and `s:classify(tail)` is the natural
single place to interpret that output. A running job should never be inferred
as `closed` merely because its terminal is quiet.

## Signals and fallback behavior

Extend the existing configurable matching approach rather than hard-coding a
specific Claude terminal layout:

- Use `g:claude_panel_working_pat` to recognize Claude's active-work footer
  (for example, its spinner/interruption hint). A match keeps a quiet but
  background-running job in `Working`.
- Use `g:claude_panel_waiting_pat` to recognize numbered choices, yes/no
  questions, permission confirmations, and visible input prompts. A match
  places the session in `Needs you`.
- Keep `g:claude_panel_idle_secs` only as the fallback when the job is running
  and neither pattern identifies its current terminal tail.

The defaults should be documented as heuristics, not a protocol guarantee.
Patterns must remain user-overridable because Claude's output can change and
custom terminal themes or prompts can affect matching. If no pattern matches,
the existing time-based fallback remains predictable: recent output is
`active`; sustained silence is `idle`.

## Panel behavior

`autoload/claude/panel.vim` should treat `waiting` as a first-class display
status alongside `active`, `idle`, and `closed`:

- `claude#panel#icon(status)` needs a `waiting` icon in both Unicode and ASCII
  defaults, while preserving `g:claude_panel_icons` overrides.
- The syntax/highlight setup should add `ClaudeSessionWaiting`, linked to a
  noticeable warning-style group without imposing a background colour.
- State grouping should map `waiting` to **Needs you** and render it first.
- A status change that moves a row between state groups must trigger a full
  render in the state view; an in-place glyph replacement is insufficient.
- The existing place tree should retain its structure, but show the waiting
  glyph and the same header attention count.

Fold keys for state groups should use a distinct namespace (for example,
`st:waiting`) so fold state does not collide with project/worktree folds.

## Compatibility and migration

Adding `waiting` is additive: persisted session records need no schema change.
Existing callers that only distinguish live records from `closed` should
continue to work, but every explicit status switch, icon map, syntax list, and
grouping helper must be audited for the fourth value.

A partial `g:claude_panel_icons` dictionary must retain fallback icons for any
new key. Existing users who do not configure either pattern should receive the
default heuristics and, if those heuristics do not match their terminal output,
fall back safely to the current idle-timer behavior.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| A prompt-like string in old scrollback produces a false `waiting` state. | Match only the terminal tail and prioritize a current working indicator. |
| A changed Claude footer fails to match the working pattern. | Preserve the output-time fallback and expose the pattern as configuration. |
| A quiet background task has no recognizable footer. | It degrades to `idle`; document this limitation rather than claiming certainty. |
| Re-grouping makes rendered rows stale. | Re-render the state view whenever status changes can move a session. |

False `waiting` classifications are more damaging than missed ones because they
train users to ignore the attention group. Defaults should therefore be narrow,
and test fixtures should use captured terminal-tail examples.

## Test plan

Add or extend Vader coverage following the existing session and panel tests:

- In `test/session_state.vader`, test `s:classify()` through its public test
  seam for working tails, numbered choices, yes/no prompts, empty tails, and
  unmatched tails.
- Verify a running job with a working tail remains `active` after
  `g:claude_panel_idle_secs` has elapsed.
- Verify a waiting tail produces `waiting`, while a simultaneously matching
  working tail produces `active` according to the precedence rule.
- Verify overridden waiting and working patterns, including no-match fallback
  to recent-output `active` and then `idle`.
- In `test/panel_groups.vader` and `test/panel_render.vader`, verify group
  order, **Needs you** counts, Unicode and ASCII waiting icons, and waiting
  highlighting.
- Verify a status transition between groups causes a complete state-view
  redraw, while place-view rendering preserves its existing tree behavior.
- Re-run the full Vader suite to ensure legacy `active`, `idle`, and `closed`
  behavior remains compatible.

## Open questions

- Is there a stable Claude-provided process or agent API that can supplement
  terminal-tail heuristics without polling a new external command?
- Which default patterns are broad enough to recognize normal prompts but
  narrow enough to avoid stale-text false positives?
- Should `Needs you` sort by the time a session began waiting once that time
  can be recorded reliably?
