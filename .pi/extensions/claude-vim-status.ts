// Optional project-local Pi integration for claude.vim's session panel.
// Pi loads .pi/extensions/*.ts only after this project is trusted. It writes
// small, atomic state records; the Vim plugin ignores them unless explicitly
// enabled with g:claude_panel_hook_state. The contract, and what Pi's
// extension API does and does not expose, are in
// doc/design/session-panel-agent-hooks.md.
//
// Like the Claude Code writer, this is level-triggered: every registered event
// publishes the session's whole current state rather than the one transition
// it saw. A missed edge then costs nothing beyond the gap until the next
// event, and an attention state holds for as long as the prompt it describes.
// Unlike that writer, this runs inside Pi's own process, so the state it
// derives lives in memory instead of being read back from the record.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { chmod, mkdir, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Must agree with the reader's s:hook_state_root(), which prefers
// $XDG_RUNTIME_DIR; disagreeing sends every record somewhere nothing reads.
const root = process.env.CLAUDE_VIM_STATUS_DIR
  || join(process.env.XDG_RUNTIME_DIR || "/tmp", "claude-vim-status");
const validId = /^[A-Za-z0-9._-]+$/;

type State = "active" | "waiting" | "idle";

// Whether an agent run is in flight, and how many blocking extension prompts
// are stacked on top of it. Pi has no background work -- no subagent or task
// tool, and a bash tool that takes a timeout rather than a detach flag -- so
// there is nothing here answering to the Claude writer's `pending`: a run that
// ends has genuinely left nothing behind.
let running = false;
let prompts = 0;

// A prompt outranks the run that raised it: Pi keeps streaming underneath an
// extension dialog, and the question is the thing the user has to act on.
function resolve(): State {
  if (prompts > 0) return "waiting";
  return running ? "active" : "idle";
}

async function publish(ctx: ExtensionContext): Promise<void> {
  // getSessionId() is Pi's session id; claude.vim starts Pi with --session-id,
  // so it is the same id the panel looks the record up by.
  const sessionId = ctx.sessionManager.getSessionId();
  if (!validId.test(sessionId)) return;

  const dir = join(root, "pi");
  const path = join(dir, `${sessionId}.json`);
  const temp = join(dir, `.${sessionId}.${process.pid}.${Date.now()}.tmp`);
  const data = JSON.stringify({
    version: 1,
    provider: "pi",
    session_id: sessionId,
    state: resolve(),
    updated_at: Math.floor(Date.now() / 1000),
    source: "agent-hook",
    turn: running,
  });

  try {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    await chmod(dir, 0o700);
    await writeFile(temp, `${data}\n`, { encoding: "utf8", mode: 0o600 });
    await rename(temp, path);
    await chmod(path, 0o600);
  } catch {
    // Status reporting must never interrupt Pi's agent lifecycle. A temp file
    // left behind by a failed rename is the one thing worth cleaning up.
    await unlink(temp).catch(() => {});
  }
}

// The record describes a session that exists. Publishing "closed" instead
// says nothing the reader will act on -- it drops that state by design, since
// a hook is not allowed to declare a live Vim job dead.
async function withdraw(ctx: ExtensionContext): Promise<void> {
  const sessionId = ctx.sessionManager.getSessionId();
  if (!validId.test(sessionId)) return;
  await unlink(join(root, "pi", `${sessionId}.json`)).catch(() => {});
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    // A loaded session is not necessarily asking a question, and whatever a
    // previous process left in memory is not this session's state.
    running = false;
    prompts = 0;
    await publish(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    running = true;
    await publish(ctx);
  });

  // agent_end is the end of one agent loop, which a retry, a compaction or a
  // queued continuation can follow; agent_settled is the one that promises
  // none of them will. So only agent_settled clears the run.
  pi.on("agent_end", async (_event, ctx) => {
    await publish(ctx);
  });
  pi.on("agent_settled", async (_event, ctx) => {
    running = false;
    await publish(ctx);
  });

  // Turn and tool boundaries change nothing; they republish so that a long run
  // keeps refreshing its record. The reader drops anything older than its TTL
  // (15 minutes by default) as a dead writer, and a single slow tool call can
  // otherwise outlast that with no event in between.
  // (Registered one by one: pi.on is a set of overloads, so a loop variable
  // matches none of them.)
  pi.on("turn_start", async (_event, ctx) => {
    await publish(ctx);
  });
  pi.on("turn_end", async (_event, ctx) => {
    await publish(ctx);
  });
  pi.on("tool_execution_start", async (_event, ctx) => {
    await publish(ctx);
  });
  pi.on("tool_execution_end", async (_event, ctx) => {
    await publish(ctx);
  });

  // Pi raises these only for dialogs an extension itself opens, through
  // ctx.ui.*. Its own tool-approval prompt goes nowhere near them and the
  // extension API exposes no approval event at all, so "Needs you" for native
  // approvals stays with the terminal-tail heuristic -- see the design doc.
  pi.on("ui_prompt_start", async (_event, ctx) => {
    prompts += 1;
    await publish(ctx);
  });
  pi.on("ui_prompt_end", async (_event, ctx) => {
    prompts = Math.max(0, prompts - 1);
    await publish(ctx);
  });

  // Every shutdown reason ends this record's usefulness: "quit" ends the
  // session, and "reload", "new", "resume" and "fork" all replace it with a
  // session that will publish its own on session_start. A record nobody
  // removes outlives every session that ever ran.
  pi.on("session_shutdown", async (_event, ctx) => {
    await withdraw(ctx);
  });
}
