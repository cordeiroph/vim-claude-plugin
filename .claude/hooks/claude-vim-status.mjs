#!/usr/bin/env node
// Writes one state record per Claude Code session for claude.vim's session
// panel (see |g:claude_panel_hook_state|). Install it yourself; the plugin
// never edits your Claude configuration. doc/design/session-panel-agent-hooks.md
// carries the contract and the event mapping this file implements.
//
// The mapping is level-triggered: every registered event writes the session's
// whole current state, so a record is only stale while Claude sits between two
// events -- never because one edge was missed. An edge-triggered writer (one
// event, one state) cannot express background work at all, and cannot hold an
// attention state for as long as the prompt it describes is actually up.
import { appendFile, chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";

const root = process.env.CLAUDE_VIM_STATUS_DIR
  || join(process.env.XDG_RUNTIME_DIR || "/tmp", "claude-vim-status");
const validId = /^[A-Za-z0-9._-]+$/;
const states = new Set(["active", "waiting", "idle"]);

// Outstanding background work not closed within this window is treated as
// leaked rather than keeping a session in Working forever. It bounds the one
// mapping whose id fields are not documented (TaskCreated/TaskCompleted).
const PENDING_TTL_MS = 30 * 60 * 1000;

// Events that state outright what the session is doing. "settled" is internal:
// the turn or a background task ended, and which state that means depends on
// what else is still outstanding (see resolve()).
const EVENT_STATE = {
  SessionStart:       "idle",
  UserPromptSubmit:   "active",
  PreToolUse:         "active",
  PostToolUse:        "active",
  PostToolUseFailure: "active",
  PostToolBatch:      "active",
  PermissionRequest:  "waiting",
  PermissionDenied:   "active",
  Elicitation:        "waiting",
  ElicitationResult:  "active",
  Stop:               "settled",
  StopFailure:        "settled",
  SubagentStart:      "active",
  SubagentStop:       "settled",
  TaskCreated:        "active",
  TaskCompleted:      "settled",
};

// Notification is many different notifications behind one event name, so the
// documented notification_type decides. Anything absent here says nothing
// about the session: auth_success, agent_completed and the quota_auto_resume_*
// types are not attention requests, and idle_prompt is idleness, not a
// question. Mapping the whole event to "waiting" puts a finished session in
// "Needs you".
const NOTIFICATION_STATE = {
  permission_prompt:     "waiting",
  agent_needs_input:     "waiting",
  elicitation_dialog:    "waiting",
  elicitation_url_dialog: "waiting",
  idle_prompt:           "settled",
};

// Background work claude.vim cannot see: a subagent or task runs with no
// terminal output and no further events, so the turn can end while work
// continues. Tracked by id so a repeated or dropped event cannot corrupt a
// count.
const PENDING_OPEN = new Set(["SubagentStart", "TaskCreated"]);
const PENDING_CLOSE = new Set(["SubagentStop", "TaskCompleted"]);

const pendingKey = (event) => String(
  event.agent_id ?? event.task_id ?? event.tool_use_id ?? event.prompt_id ?? "anonymous",
);

// A turn that is still running, or background work still outstanding, is
// Working. Only a session with neither is Idle.
function resolve(state, turn, pending) {
  if (state !== "settled") return state;
  return turn || Object.keys(pending).length > 0 ? "active" : "idle";
}

async function readRecord(path, sessionId) {
  try {
    const prev = JSON.parse(await readFile(path, "utf8"));
    if (prev?.version === 1 && prev.session_id === sessionId) return prev;
  } catch {
    // No usable record: start from a clean one.
  }
  return null;
}

let input = "";
for await (const chunk of process.stdin) input += chunk;

// Raw-event log, for working out what an event actually carries when the
// mapping above does not fire as expected. Off unless <root>/claude/.debug-events
// exists, so a stray flag file is the only thing that can turn it on -- and it
// can never change what the hook writes.
try {
  await readFile(join(root, "claude", ".debug-events"), "utf8");
  await appendFile(
    join(root, "claude", "events.log"),
    `${new Date().toISOString()} ${input.trim()}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
} catch {
  // Logging off, or the log is unwritable: neither is the hook's problem.
}

try {
  const event = JSON.parse(input);
  const sessionId = event.session_id ?? event.sessionId;
  if (typeof sessionId !== "string" || !validId.test(sessionId)) process.exit(0);

  const name = event.hook_event_name;
  const dir = join(root, "claude");
  const path = join(dir, `${sessionId}.json`);

  // A session that has ended has no state worth keeping, and a record nobody
  // removes outlives every session that ever ran.
  if (name === "SessionEnd") {
    await unlink(path).catch(() => {});
    process.exit(0);
  }

  const wanted = name === "Notification"
    ? NOTIFICATION_STATE[event.notification_type]
    : EVENT_STATE[name];
  if (!wanted) process.exit(0);

  const eventMs = Date.now();
  const prev = name === "SessionStart" ? null : await readRecord(path, sessionId);

  // Drop background work whose closing event never arrived.
  const pending = {};
  for (const [key, at] of Object.entries(prev?.pending ?? {})) {
    if (typeof at === "number" && eventMs - at < PENDING_TTL_MS) pending[key] = at;
  }
  if (PENDING_OPEN.has(name)) pending[pendingKey(event)] = eventMs;
  if (PENDING_CLOSE.has(name)) delete pending[pendingKey(event)];

  const turn = name === "UserPromptSubmit" ? true
    : (name === "Stop" || name === "StopFailure") ? false
    : prev?.turn === true;

  // One process per event, so two near-simultaneous events can arrive out of
  // order. The newer event's state wins; this one's bookkeeping still lands.
  const stale = typeof prev?.event_ms === "number" && prev.event_ms > eventMs;
  const state = stale && states.has(prev.state)
    ? prev.state
    : resolve(wanted, turn, pending);
  const stamp = stale ? prev.event_ms : eventMs;

  const temp = join(dir, `.${sessionId}.${process.pid}.${eventMs}.tmp`);
  const record = JSON.stringify({
    version: 1,
    provider: "claude",
    session_id: sessionId,
    state,
    updated_at: Math.floor(stamp / 1000),
    source: "agent-hook",
    event_ms: stamp,
    turn,
    pending,
  });
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700);
  await writeFile(temp, `${record}\n`, { encoding: "utf8", mode: 0o600 });
  await rename(temp, path);
  await chmod(path, 0o600);
} catch {
  // Hooks must never affect Claude's own operation.
}
