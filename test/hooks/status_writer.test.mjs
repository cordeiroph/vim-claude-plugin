// Tests for examples/hooks/claude-vim-status.mjs, the Claude Code writer
// behind |g:claude_panel_hook_state|. Run with `make test-hooks`; needs only
// node, no Claude installation.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const writer = fileURLToPath(new URL("../../examples/hooks/claude-vim-status.mjs", import.meta.url));
const root = await mkdtemp(join(tmpdir(), "claude-vim-status-test-"));
const record = join(root, "claude", "s1.json");

// Every event Claude Code would deliver arrives on stdin as one JSON object.
function fire(event, id = "s1") {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [writer], {
      env: { ...process.env, CLAUDE_VIM_STATUS_DIR: root },
      stdio: ["pipe", "ignore", "inherit"],
    });
    child.on("error", reject);
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
    child.stdin.end(JSON.stringify({ session_id: id, ...event }));
  });
}

const state = async () => JSON.parse(await readFile(record, "utf8")).state;
const read = async () => JSON.parse(await readFile(record, "utf8"));
const gone = async () => {
  try {
    await readFile(record, "utf8");
    return false;
  } catch {
    return true;
  }
};

const tests = {
  "a session nobody has asked anything is idle": async () => {
    await fire({ hook_event_name: "SessionStart" });
    assert.equal(await state(), "idle", "a session nobody has asked anything is idle");
    await fire({ hook_event_name: "UserPromptSubmit" });
    assert.equal(await state(), "active");
  },

  "a turn ending is idle": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({ hook_event_name: "PreToolUse", tool_name: "Bash" });
    assert.equal(await state(), "active");
    await fire({ hook_event_name: "Stop" });
    assert.equal(await state(), "idle");
  },

  "a permission prompt needs attention until it is answered": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({ hook_event_name: "PermissionRequest", tool_name: "Bash" });
    assert.equal(await state(), "waiting");
    await fire({ hook_event_name: "Notification", notification_type: "permission_prompt" });
    assert.equal(await state(), "waiting", "the notification for the same prompt agrees");
    await fire({ hook_event_name: "PostToolBatch" });
    assert.equal(await state(), "active", "answered, and back to work");
  },

  "an MCP elicitation needs attention until it resolves": async () => {
    await fire({ hook_event_name: "Elicitation", server_name: "acme" });
    assert.equal(await state(), "waiting");
    await fire({ hook_event_name: "ElicitationResult", server_name: "acme" });
    assert.equal(await state(), "active");
  },

  "notifications that are not questions do not ask for attention": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({ hook_event_name: "Stop" });
    for (const type of ["auth_success", "agent_completed", "quota_auto_resume_fired",
      "elicitation_complete", "elicitation_response", "quota_auto_resume_stale"]) {
      await fire({ hook_event_name: "Notification", notification_type: type });
      assert.equal(await state(), "idle", `${type} is not a question`);
    }
    await fire({ hook_event_name: "Notification", notification_type: "idle_prompt" });
    assert.equal(await state(), "idle", "an idle prompt is idleness, not a question");
  },

  "background work outlives the turn that started it": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({ hook_event_name: "SubagentStart", agent_id: "a1", agent_type: "Explore" });
    await fire({ hook_event_name: "Stop" });
    assert.equal(await state(), "active", "the turn ended, the subagent did not");
    await fire({ hook_event_name: "Notification", notification_type: "idle_prompt" });
    assert.equal(await state(), "active", "and a quiet prompt does not make it idle");
    await fire({ hook_event_name: "SubagentStop", agent_id: "a1" });
    assert.equal(await state(), "idle");
  },

  "concurrent background work is tracked by id": async () => {
    await fire({ hook_event_name: "TaskCreated", task_id: "t1" });
    await fire({ hook_event_name: "SubagentStart", agent_id: "a1" });
    await fire({ hook_event_name: "Stop" });
    await fire({ hook_event_name: "SubagentStop", agent_id: "a1" });
    assert.equal(await state(), "active", "one task is still outstanding");
    await fire({ hook_event_name: "SubagentStop", agent_id: "a1" });
    assert.equal(await state(), "active", "a repeated close cannot lose a count");
    await fire({ hook_event_name: "TaskCompleted", task_id: "t1" });
    assert.equal(await state(), "idle");
  },

  "background work whose close never came is dropped eventually": async () => {
    await fire({ hook_event_name: "TaskCreated", task_id: "leaked" });
    const stale = await read();
    stale.pending.leaked = Date.now() - 31 * 60 * 1000;
    await writeFile(record, JSON.stringify(stale));
    await fire({ hook_event_name: "Stop" });
    assert.equal(await state(), "idle", "a leaked task cannot pin a session to Working");
  },

  "a running background shell task outlives the turn": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({
      hook_event_name: "Stop",
      background_tasks: [{ id: "b1", type: "shell", status: "running" }],
    });
    assert.equal(await state(), "active", "the turn ended, the shell task did not");
    await fire({ hook_event_name: "Notification", notification_type: "idle_prompt" });
    assert.equal(await state(), "active", "and a quiet prompt does not make it idle");
    await fire({ hook_event_name: "UserPromptSubmit" });
    await fire({ hook_event_name: "Stop", background_tasks: [] });
    assert.equal(await state(), "idle", "the next snapshot reports it finished");
  },

  "a shell snapshot is the whole truth about shell tasks": async () => {
    await fire({
      hook_event_name: "Stop",
      background_tasks: [
        { id: "b1", type: "shell", status: "running" },
        { id: "b2", type: "shell", status: "running" },
      ],
    });
    assert.equal(await state(), "active");
    await fire({
      hook_event_name: "Stop",
      background_tasks: [
        { id: "b2", type: "shell", status: "running" },
        { id: "b3", type: "shell", status: "completed" },
      ],
    });
    assert.deepEqual(Object.keys((await read()).pending), ["shell:b2"],
      "one dropped from the list is done, and a finished one never counted");
    await fire({ hook_event_name: "Stop", background_tasks: [] });
    assert.equal(await state(), "idle");
  },

  "a shell snapshot leaves subagents alone": async () => {
    await fire({ hook_event_name: "SubagentStart", agent_id: "a1" });
    await fire({
      hook_event_name: "Stop",
      background_tasks: [{ id: "b1", type: "shell", status: "running" }],
    });
    assert.deepEqual(Object.keys((await read()).pending).sort(), ["a1", "shell:b1"]);
    await fire({ hook_event_name: "Stop", background_tasks: [] });
    assert.equal(await state(), "active", "the subagent is still outstanding");
    await fire({ hook_event_name: "SubagentStop", agent_id: "a1" });
    assert.equal(await state(), "idle");
  },

  "a session ending takes its record with it": async () => {
    await fire({ hook_event_name: "UserPromptSubmit" });
    assert.equal(await gone(), false);
    await fire({ hook_event_name: "SessionEnd" });
    assert.equal(await gone(), true);
  },

  "an out-of-order event cannot undo a newer state": async () => {
    await fire({ hook_event_name: "PermissionRequest", tool_name: "Bash" });
    const ahead = await read();
    ahead.event_ms = Date.now() + 60_000;
    await writeFile(record, JSON.stringify(ahead));
    await fire({ hook_event_name: "PreToolUse", tool_name: "Bash" });
    assert.equal(await state(), "waiting", "the newer event's state stands");
  },

  "the record carries the schema and nothing else": async () => {
    await fire({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "id" } });
    const rec = await read();
    assert.equal(rec.version, 1);
    assert.equal(rec.provider, "claude");
    assert.equal(rec.session_id, "s1");
    assert.equal(rec.source, "agent-hook");
    assert.equal(typeof rec.updated_at, "number");
    assert.ok(Math.abs(rec.updated_at - Math.floor(Date.now() / 1000)) < 5, "seconds, for Vim");
    assert.ok(!JSON.stringify(rec).includes("command"),
      "no tool arguments, prompts or output reach the record");
    assert.deepEqual(Object.keys(rec).sort(), ["event_ms", "pending", "provider", "session_id",
      "source", "state", "turn", "updated_at", "version"]);
  },

  "junk is ignored without a record": async () => {
    for (const event of [{ hook_event_name: "PreCompact" }, { hook_event_name: "CwdChanged" },
      { hook_event_name: "Notification", notification_type: "unknown_type" },
      { hook_event_name: "Notification" }]) {
      await fire(event);
      assert.equal(await gone(), true, `${JSON.stringify(event)} says nothing about the session`);
    }
    await fire({ hook_event_name: "UserPromptSubmit" }, "../escape");
    assert.equal(await gone(), true, "an id that is a path is not an id");
  },

  "a malformed payload is silent": async () => {
    await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [writer], {
        env: { ...process.env, CLAUDE_VIM_STATUS_DIR: root },
        stdio: ["pipe", "ignore", "inherit"],
      });
      child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
      child.stdin.end("not json at all");
    });
    assert.equal(await gone(), true);
  },
};

let failed = 0;
for (const [name, run] of Object.entries(tests)) {
  await rm(join(root, "claude"), { recursive: true, force: true });
  try {
    await run();
    console.log(`ok    ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}
await rm(root, { recursive: true, force: true });
console.log(`\n${Object.keys(tests).length - failed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
