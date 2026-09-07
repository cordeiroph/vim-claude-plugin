# Design: Agent Session Panel

Status: proposed
Target: `claude.vim`
Author: design draft
Last updated: 2026-09-05

---

## 1. Summary and motivation

`claude.vim` currently allows **one Claude session per Vim tab**. The session is
stored as a tab-local buffer number (`t:claude_bufnr`, `autoload/claude.vim:17-29`),
with an optional single-global fallback (`s:g_bufnr`) selected by
`g:claude_tab_sessions`. That model has three consequences:

1. You cannot run two Claude sessions side by side in the same tab.
2. There is no way to see what sessions exist — you have to remember which tab
   holds which conversation.
3. Sessions are anonymous. `:ClaudeResume` identifies past sessions only by
   timestamp plus a 60-character snippet of the first user message
   (`autoload/claude.vim:403-460`), which is a poor handle for work you return to
   over days.

This design replaces the per-tab model with a **global session registry** and adds
an **agent session panel**: a left-hand split, in the spirit of NERDTree, that
lists every Claude session — live ones running in this Vim instance and closed
ones recoverable from this project's transcripts — grouped by
`Project > Worktree > Branch`, each with a user-assigned name and a status icon.
Sessions are opened from the panel into a split or tab; several may run at once.

Two capabilities of the installed CLI (`claude 2.1.261`) make this substantially
simpler than it would otherwise be, and the design depends on both:

- **`claude --session-id <uuid>`** — Vim generates the session id *before*
  launching, so the registry key is known at spawn time. Without this the id
  could only be recovered by polling `~/.claude/projects/` for a new transcript
  after startup, which is racy.
- **`claude --name <name>`** — the name the user types in Vim is pushed into the
  CLI itself, so it also appears in Claude's prompt box, its `/resume` picker and
  the terminal title. The panel and the CLI agree on what a session is called.

---

## 2. Goals / Non-goals

### Goals

- A toggleable left panel listing all Claude sessions, grouped
  `Project > Worktree > Branch`.
- Per-session status icon: **active**, **idle**, **closed**.
- User-assigned session names, prompted at creation, editable later, persisted
  across Vim restarts.
- NERDTree-style open verbs: same window, horizontal split, vertical split, new
  tab.
- Delete a session from the panel.
- Hiding the panel never affects running sessions.
- Multiple concurrent sessions in one tab; removal of the per-tab model.
- A picker popup wherever a command must choose among several sessions.

### Non-goals

- Listing sessions from **other** projects (every directory under
  `~/.claude/projects/`). Deferred — see §12.
- Reading, rendering or searching transcript *content* in the panel. The panel
  lists sessions; it is not a conversation browser.
- Multi-Vim-instance coordination. Two Vim processes each keep their own live
  registry; they share only the on-disk name store, which is written
  last-writer-wins (§5.4).
- Reordering, drag-and-drop, or manual grouping. Grouping is derived, never
  hand-edited.
- Any change to how prompts are sent (`s:send()`, bracketed paste) beyond
  retargeting them at an explicit session.

---

## 3. Panel UX

### 3.1 Layout

The panel is a vertical split pinned to the left edge
(`topleft vertical <width>split`), width `g:claude_panel_width` (default 35),
`winfixwidth`. It is a scratch buffer named `[claude-sessions]`, never listed,
never written.

```
┌─────────────────────────────────┬──────────────────────────────────────────┐
│ Claude Sessions            (5)  │                                          │
│                                 │                                          │
│ ▾ claude-pluing                 │   main editing area                      │
│   ▾ ~/Workspace/vim/claude-plu… │   (sessions open here as splits/tabs)    │
│     ▾ main                      │                                          │
│       ● panel design            │                                          │
│       ○ doc rewrite             │                                          │
│     ▾ feature/session-registry  │                                          │
│       ○ registry spike          │                                          │
│   ▾ ~/Workspace/vim/wt-hotfix   │                                          │
│     ▾ hotfix/e947               │                                          │
│       ✗ E947 repro              │                                          │
│                                 │                                          │
│ ▾ homeserver                    │                                          │
│   ▾ ~/Workspace/devOps/homeser… │                                          │
│     ▾ main                      │                                          │
│       ✗ nginx tuning            │                                          │
│                                 │                                          │
│ ? help                          │                                          │
└─────────────────────────────────┴──────────────────────────────────────────┘
```

Node lines are indented two spaces per level. Long worktree paths are shortened
with `pathshorten()`-style truncation to the panel width, with the full path
shown in the status line when the cursor rests on the node.

The `(5)` in the header is the live session count.

### 3.2 Status icons

| State | Default glyph | ASCII fallback | Meaning |
|-------|---------------|----------------|---------|
| active | `●` | `[A]` | Job running **and** terminal output changed within `g:claude_panel_idle_secs` |
| idle | `○` | `[I]` | Job running, no output change within `g:claude_panel_idle_secs` |
| closed | `✗` | `[C]` | No live job in this Vim instance — either the job died or the session exists only as a transcript on disk |

Glyphs are overridable via `g:claude_panel_icons`; the ASCII set is used
automatically when `g:claude_panel_ascii` is 1 or `&encoding` is not a Unicode
encoding.

Highlight groups (linked to sensible defaults, overridable):
`ClaudeSessionActive` → `String`, `ClaudeSessionIdle` → `Comment`,
`ClaudeSessionClosed` → `NonText`, `ClaudeSessionProject` → `Directory`,
`ClaudeSessionWorktree` → `Identifier`, `ClaudeSessionBranch` → `Type`.

### 3.3 Keymap

All mappings are buffer-local to the panel.

| Key | Action |
|-----|--------|
| `<CR>`, `o` | On a session: open/focus it in the main area using the default placement (`g:claude_split_anchor` / `g:claude_split_size`, matching `s:split_cmd()`). On a group node: toggle fold. |
| `i` | Open the session in a **horizontal** split of the main area |
| `s` | Open the session in a **vertical** split of the main area |
| `t` | Open the session in a **new tab** |
| `n` | New session in the current group's context — prompts for a name |
| `r` | Rename the session under the cursor |
| `d` | End the session under the cursor (stop job, wipe buffer). Transcript is kept, so it reappears as **closed** |
| `D` | Purge: remove the name record **and** delete the transcript `.jsonl`. Double confirmation |
| `R` | Force a full refresh (re-scan transcripts, re-derive groups) |
| `za`, `<Space>` | Toggle fold on the node under the cursor |
| `q` | Hide the panel |
| `?` | Toggle inline help header |

Node collapsing moves to `za`/`<Space>`, which matches Vim's own
fold vocabulary and is therefore no worse to discover.

**Placement of opened sessions.** All four verbs place the window in the area to
the *right* of the panel; the panel itself is never split or replaced. `i` and
`s` split the window that was current before the panel was entered (tracked in
`w:claude_panel_prev_winid`); when no such window exists (panel is the only
window) they fall back to `s:split_cmd()`.

**Reuse rule.** If the chosen session already has a visible window in the current
tab, all four verbs jump to it instead of creating a duplicate window, then enter
terminal-insert mode via the existing `s:terminal_enter_insert()` guard. `t`
always creates a new tab even if the session is visible elsewhere.

### 3.4 Toggle and the picker popup

`<leader>cs` (and `:ClaudeSessions`) toggles the panel. The mapping lives with
the existing `<leader>c*` family in `plugin/claude.vim` and is suppressed by
`g:claude_no_default_mappings`.

Commands that need *one* session but could find several — `:ClaudeToggle`,
`:ClaudeFocus`, `:ClaudeClose`, `:ClaudeModel`, `:ClaudeExplain`, `:ClaudeInput`
— resolve their target with this rule:

1. Cursor is inside a Claude terminal window → that session.
2. Otherwise, exactly one live session → that one, no prompt.
3. Otherwise, more than one live session → **picker popup**. The picker popup must have a option for new session.
4. Otherwise, zero live sessions → create one (prompting for a name, §5.1).

The picker uses `popup_menu()` when `has('popupwin')`, falling back to
`inputlist()` otherwise (the same fallback shape already used by
`claude#select_model()` and `claude#resume()`). Entries are rendered
`<icon> <name> — <branch>` and are ordered most-recently-focused first, so the
default highlighted entry is almost always the one wanted.

---

## 4. Data model

### 4.1 Session record

One dict per session, held in a script-local registry in
`autoload/claude/session.vim` keyed by session id:

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| `id` | String | Vim-generated UUID v4 | Passed to the CLI as `--session-id`; also the transcript filename stem |
| `name` | String | User prompt | Passed to the CLI as `--name`; persisted |
| `bufnr` | Number | `bufnr('%')` after `:terminal` | `-1` for closed / disk-only sessions |
| `cwd` | String | `getcwd()` at spawn; `cwd` field of the transcript for disk sessions | Absolute |
| `project` | String | §6 | Main-repo root path |
| `worktree` | String | §6 | Worktree root path |
| `branch` | String | §6; `gitBranch` field of the transcript for disk sessions | Recorded at spawn, never re-derived |
| `status` | String | Computed, §5 | `'active'` / `'idle'` / `'closed'` |
| `created` | Number | `localtime()` or transcript mtime | Unix epoch |
| `last_active` | Number | Updated by the status poller | Unix epoch |
| `last_focus` | Number | `WinEnter` on the terminal | Drives picker ordering |
| `origin` | String | `'live'` or `'disk'` | Disk sessions are read-only until resumed |

### 4.2 On-disk name store

Path: `<plugin-root>/data/sessions.json`, overridable with
`g:claude_session_store`. The plugin root is resolved once from
`autoload/claude/session.vim` via `expand('<sfile>:p:h:h:h')`, so it works
identically under vim-plug, Vundle, pathogen and a manual install.

```json
{
  "version": 1,
  "sessions": {
    "8945dff0-1429-451a-8a4b-5f8f286b5176": {
      "name": "panel design",
      "cwd": "/Users/me/Workspace/vim/claude-pluing",
      "project": "/Users/me/Workspace/vim/claude-pluing",
      "worktree": "/Users/me/Workspace/vim/claude-pluing",
      "branch": "main",
      "created": 1757088880
    }
  }
}
```

Only *naming and grouping metadata* lives here. Buffer numbers, jobs and status
are runtime state and are never persisted.

The store is read once on first panel use (or first session creation) and written
on every mutation (create / rename / purge), using `writefile()` to a temp file
followed by `rename()` so a crash mid-write cannot truncate it.

> **Caveat — accepted trade-off.** Keeping the store inside the plugin directory
> makes the plugin fully self-contained, but a plugin update or reinstall
> (`:PlugUpdate`, `:PlugClean`, deleting the bundle directory) **will delete
> `data/sessions.json` and with it every session name**. Users who care about
> durable names should set `g:claude_session_store` to a path outside the plugin,
> e.g. `let g:claude_session_store = expand('~/.claude/vim-sessions.json')`.
> This must be stated in both `README.md` and `doc/claude.txt`.

**Read-only or unwritable store.** Write failures are detected by checking
`writefile()`'s return value. On failure the plugin echoes a single warning per
Vim session (`claude.vim: session store not writable (<path>); names are
in-memory only`) and continues with the in-memory registry. Names then survive
until Vim exits. The panel never blocks on store I/O.

### 4.3 Registry lifecycle

- **Create** — `claude#session#new(name)` generates the UUID, derives
  project/worktree/branch, spawns the terminal, inserts the record, writes the
  store, refreshes the panel.
- **Update** — the status poller (§5) mutates `status` / `last_active` only.
  `WinEnter` on a Claude terminal buffer updates `last_focus` and the
  "current session" pointer.
- **Reap** — when a job is found dead, the record is **not** removed; it flips to
  `closed` and its `bufnr` is set to `-1` after the buffer is wiped, so the
  session stays listed and resumable. Records vanish from the registry only on
  `D` (purge).
- **Merge on load** — `claude#session#refresh()` scans
  `~/.claude/projects/<cwd-slug>/*.jsonl`, keeps the newest
  `g:claude_panel_closed_limit` entries (default 10, matching the current
  `claude#resume()` behaviour), and merges them with live records. A live record
  always wins over the disk record with the same id.

---

## 5. Status detection and refresh

Vim provides no `on_exit` callback for a `++curwin` terminal — the existing code
works around this by polling `job_status()` inside `s:is_open()`
(`autoload/claude.vim:202-218`). The panel formalises that into a single poller.

### 5.1 Rules

```
if bufnr == -1 or !bufexists(bufnr)            -> closed
elseif term_getjob(bufnr) is null              -> closed
elseif job_status(job) != 'run'                -> closed
elseif localtime() - last_active < idle_secs   -> active
else                                           -> idle
```

`last_active` is bumped whenever the terminal's visible content changes. Change
detection hashes the last 5 lines of the terminal via `term_getline()` — cheap,
and sufficient because Claude's spinner and streaming output both touch the
bottom of the screen. `g:claude_panel_idle_secs` defaults to 30.

### 5.2 Refresh strategy

The poller runs **only while the panel is visible**, on a `timer_start()` repeat
of `g:claude_panel_refresh_ms` (default 2000). Hiding the panel stops the timer;
there is no background cost when the panel is closed. In addition the panel
redraws on:

- `BufEnter` / `WinEnter` of the panel buffer,
- `TabEnter`,
- any registry mutation (create, rename, delete, resume),
- explicit `R`.

Only the status column is repainted on a poll tick; the tree is rebuilt only on
mutation or `R`. The panel buffer is `nomodifiable` and is updated by
temporarily clearing that flag, calling `setline()`, and restoring it, with the
cursor line preserved.

### 5.3 Transcript rescan

Disk sessions are rescanned on panel open and on `R`, never on the poll tick —
`glob()` over a project directory is far more expensive than a `job_status()`
call and the set of closed sessions changes rarely.

### 5.4 Concurrent Vim instances

Two Vim instances each hold their own live registry. The name store is
last-writer-wins: each mutation re-reads the file, merges its own change into the
loaded dict, and writes the result back. A name set in instance A appears in
instance B on B's next store read (panel open or `R`). Instance A's *live*
sessions appear in instance B as **closed** (B has no job handle for them);
opening one there would resume the same session id in two places, so the panel
refuses to open a session whose transcript has been modified in the last 5
seconds by a process other than this Vim, showing
`session appears active in another editor — use R to refresh`.

---

## 6. Grouping derivation

Three levels: **Project > Worktree > Branch**.

| Level | Live session | Disk session |
|-------|--------------|--------------|
| Project | `git -C <cwd> rev-parse --path-format=absolute --git-common-dir`, then strip a trailing `/.git`; label = `fnamemodify(root, ':t')` | Same, computed from the transcript's `cwd` field |
| Worktree | `git -C <cwd> rev-parse --show-toplevel`; label = shortened absolute path | Same, from the transcript's `cwd` |
| Branch | `git -C <cwd> rev-parse --abbrev-ref HEAD`, captured **once at spawn** | The transcript's `gitBranch` field |

Using `--git-common-dir` is what makes linked worktrees collapse under one
project: for a worktree, `--git-dir` points at `<main>/.git/worktrees/<name>`
while `--git-common-dir` points at `<main>/.git`. `--path-format=absolute`
requires Git 2.31+; on older Git the plugin falls back to resolving the relative
result against `cwd`.

Transcripts already carry both `cwd` and `gitBranch` on every user entry
(verified against `claude 2.1.261` output), so closed sessions need **no** git
invocation at all and their branch is historically accurate even if the worktree
has since moved on. Only live sessions shell out, once each, at spawn.

Git results are memoised per directory for the lifetime of the Vim session; the
panel never runs git on a redraw.

### Fallbacks

| Situation | Project | Worktree | Branch |
|-----------|---------|----------|--------|
| Not a git repo | `(no project)` | the cwd itself | `(no branch)` |
| Detached HEAD | as normal | as normal | `(detached: <7-char sha>)` |
| Bare repo / git missing from `$PATH` | `(no project)` | the cwd | `(no branch)` |
| Transcript lacks `cwd` (malformed) | `(unknown)` | `(unknown)` | `(unknown)` |

Empty groups are never rendered. A group node with exactly one child is still
rendered — collapsing single-child levels would make the tree shape jump around
as sessions are added.

### Folding

Fold state is per group-node path and persists for the Vim session (a
script-local set of collapsed node keys), so a collapsed project stays collapsed
across redraws. Default: all groups expanded.

---

## 7. New and changed public API

### 7.1 New modules

| File | Responsibility |
|------|----------------|
| `autoload/claude/session.vim` | The registry: create, resume, rename, delete, status polling, group derivation. No UI. |
| `autoload/claude/panel.vim` | The panel buffer: render, keymaps, open verbs, folding. No process handling. |
| `autoload/claude/store.vim` | Read/write `sessions.json`, atomic write, error degradation. Pure I/O. |

Splitting `store.vim` out is deliberate: like `claude#split_cmd()`, it is a pure
function of its inputs and can be Vader-tested with no terminal, no job and no
git repo.

### 7.2 New public functions

| Function | Purpose |
|----------|---------|
| `claude#session#new([name])` | Prompt for a name if omitted, spawn `claude --session-id <uuid> --name <name>` |
| `claude#session#resume(id)` | Relaunch a closed session with `--resume <id> --name <name>` |
| `claude#session#list()` | Registry values, merged with disk sessions |
| `claude#session#tree()` | `list()` folded into the Project/Worktree/Branch structure — the panel's only data source |
| `claude#session#current()` | The target-resolution rule of §3.4, without the picker |
| `claude#session#pick(prompt)` | The picker popup; returns an id or empty |
| `claude#session#rename(id, name)` | Rename in registry + store |
| `claude#session#delete(id)` | End the session (stop job, wipe buffer) |
| `claude#session#purge(id)` | `delete()` plus remove the record and the transcript |
| `claude#session#status(id)` | The §5.1 rules for one session |
| `claude#session#group_of(cwd)` | `{project, worktree, branch}` for a directory, memoised |
| `claude#panel#toggle()` / `open()` / `close()` | Panel visibility |
| `claude#panel#refresh()` | Rebuild the tree |
| `claude#panel#open_session(id, mode)` | `mode` ∈ `'here'`, `'split'`, `'vsplit'`, `'tab'` |
| `claude#store#load()` / `save(dict)` / `path()` | Name-store I/O |

### 7.3 New commands and mappings

| Command | Mapping | Action |
|---------|---------|--------|
| `:ClaudeSessions` | `<leader>cs` | Toggle the panel |
| `:ClaudeSessionsOpen` | — | Open the panel |
| `:ClaudeSessionsClose` | — | Hide the panel |
| `:ClaudeNew [name]` | — | New named session |
| `:ClaudeRename [name]` | — | Rename the current session |

### 7.4 Changed existing API

| Location | Change |
|----------|--------|
| `plugin/claude.vim:26-30` | **Delete** the `g:claude_tab_sessions` default block |
| `plugin/claude.vim` | Add the config defaults of §8, the five commands of §7.3, and the `<leader>cs` mapping |
| `autoload/claude.vim:11-13` `s:tab_mode()` | **Delete** |
| `autoload/claude.vim:8` `s:g_bufnr` | **Delete** |
| `autoload/claude.vim:17-29` `s:get_bufnr()` / `s:set_session()` | **Delete**; replaced by `claude#session#current()` returning a record |
| `claude#open()` | Becomes a thin wrapper: `claude#session#new()` when nothing is live, else focus the current session. No longer refuses to create a second session — that is now `:ClaudeNew`'s job, and `claude#open()` keeps its "focus if present" behaviour for backward compatibility of `<leader>co` |
| `claude#toggle()` | Target resolved by §3.4 (picker when several are live). Hide/show logic unchanged, but operates on the resolved record's `bufnr` |
| `claude#focus()` | Same retargeting; unchanged otherwise |
| `claude#close()` | Closes the **resolved** session, not "the tab's session"; delegates to `claude#session#delete()` |
| `claude#close_all()` | Iterates the registry instead of `range(1, tabpagenr('$'))` and `gettabvar()` |
| `claude#_stop_jobs()` | Iterates the registry instead of tab pages; the `s:tab_mode()` early-return disappears. **Must keep** running from `ExitPre` before Vim's E947 check |
| `claude#_quit_pre()` | The "is this the last non-Claude window" count now tests window buffers against the *set* of registry buffer numbers rather than one `l:claude_bufnr`. Behaviour preserved: an ordinary `:q` must not kill a session (regression guarded by `test/session_quit.vader`, commit 819a97d) |
| `s:is_open()` | Replaced by `claude#session#status(id) !=# 'closed'`; the stale-state cleanup it performed moves into the reaper (§4.3), which flips to `closed` instead of discarding |
| `s:cleanup_current()` | Becomes `claude#session#delete(id)` |
| `s:set_buf_options()` | Unchanged, but also sets `b:claude_session_id` so `WinEnter` can identify the session and so the panel can map buffers back to records |
| `s:send()` / `s:send_when_ready()` / `s:terminal_scan()` | Take an explicit `bufnr`/`id` argument instead of calling `s:get_bufnr()` |
| `claude#explain()` | Resolves its target via §3.4 before sending |
| `claude#select_model()` | Same |
| `claude#resume()` | Kept as a command, but reimplemented over `claude#session#resume()` so a resumed session enters the registry with its stored name. The `tabnew`-when-busy behaviour at `autoload/claude.vim:443-445` is **removed** — several sessions may now share a tab |
| `claude#_send_input()` | Same retargeting |
| `autoload/claude/input.vim:36-56` | **Delete** `s:tab_mode()`, `s:g_commands`, `s:g_agents`, and the four `t:`/`s:` accessors. Completion data (slash commands, agents) is per *session*, so it moves onto the session record as `commands` / `agents` fields, populated by `claude#input#collect_data(id)` |
| `autoload/claude/input.vim` input window | `t:claude_input_bufnr` / `t:claude_input_saved` **stay tab-local** — the input window is a per-tab composing surface, not a session. Its submit path resolves the target session via §3.4 |
| `claude#split_cmd()` | Unchanged (still the public test seam) |

---

## 8. Configuration

Following the comment style of `plugin/claude.vim`:

| Variable | Default | Description |
|----------|---------|-------------|
| `g:claude_panel_width` | `35` | Panel width in columns |
| `g:claude_panel_anchor` | `'left'` | `'left'` or `'right'` — which edge the panel is pinned to |
| `g:claude_panel_icons` | `{'active':'●','idle':'○','closed':'✗'}` | Status glyphs |
| `g:claude_panel_ascii` | `0` | `1` forces `[A]` / `[I]` / `[C]` |
| `g:claude_panel_refresh_ms` | `2000` | Status poll interval while the panel is visible |
| `g:claude_panel_idle_secs` | `30` | Seconds without terminal output before a session is idle |
| `g:claude_panel_show_closed` | `1` | `0` lists only live sessions |
| `g:claude_panel_closed_limit` | `10` | Max closed sessions listed per project |
| `g:claude_panel_auto_open` | `0` | `1` opens the panel on `VimEnter` |
| `g:claude_session_store` | `<plugin-root>/data/sessions.json` | Where session names are persisted (§4.2) |
| `g:claude_session_prompt_name` | `1` | `0` skips the name prompt and auto-names sessions |

**Removed:** `g:claude_tab_sessions`.

Unchanged: `g:claude_split_anchor`, `g:claude_split_size`, `g:claude_cmd`,
`g:claude_models`, `g:claude_no_default_mappings`.

---

## 9. Migration / breaking changes

### `g:claude_tab_sessions` is removed

It is deleted outright, with no compatibility shim. Users who set it will find it
silently ineffective. Consequences:

- **`g:claude_tab_sessions = 1` (the old default)** — the closest equivalent is
  the new default: sessions are global, but `<leader>co` still focuses "the"
  session when only one is live, so single-session users notice nothing.
- **`g:claude_tab_sessions = 0`** — this was already "one shared session"; the
  new model is a superset. No action needed beyond deleting the line.

### Other breaking changes

- `:ClaudeResume` no longer opens a new tab when a session is already running; it
  opens a split in the current tab.
- `t:claude_bufnr`, `t:claude_commands`, `t:claude_agents` no longer exist. Any
  user config or statusline referencing them breaks; `b:claude_session_id` plus
  `claude#session#current()` are the replacements.
- `test/session_quit.vader` reads `t:claude_bufnr` directly (its `Before`/`After`
  blocks and every `Execute`) and must be rewritten against the registry.

### Documentation

`doc/claude.txt` section **6. Tab sessions** (`*claude-tab-sessions*`) is
replaced by **6. Session panel** (`*claude-session-panel*`); the contents index
and `README.md`'s mapping table are updated in the same change. The name-store
caveat of §4.2 is documented in both.

---

## 10. Edge cases and failure modes

| Case | Behaviour |
|------|-----------|
| **Vim exits with several live jobs** | `ExitPre` → `claude#_stop_jobs()` iterates *every* registry record and `s:job_stop_wait()`s each (500 ms cap apiece). With many sessions this serialises: cap total wait at 2 s, then let `VimLeavePre` → `close_all()` wipe the rest. Documented as a known limitation. |
| **`:q` on an ordinary split** | Must not touch any session. Guaranteed by keeping the `ExitPre`-not-`QuitPre` registration; the legacy `claude#_quit_pre()` fallback (Vim < 8.1.0446) now counts windows against the registry buffer set. |
| **Job dies while the panel is open** | Next poll tick flips the record to `closed`, repaints the icon, and wipes the terminal buffer. The row stays, resumable. |
| **Session job dies while its window is focused** | Buffer is wiped; Vim closes the window. If that was the last window in the tab, the tab closes — unavoidable and identical to today's behaviour. |
| **Duplicate names** | Allowed. Names are labels, not keys; the id is the key. The panel disambiguates by appending ` (2)`, ` (3)` … to the *displayed* label of same-named sessions within one branch group, leaving the stored name alone. |
| **Empty name at the prompt** | Falls back to `claude <YYYY-MM-DD HH:MM>`. Cancelling the prompt (`<Esc>` / `<C-c>`) **aborts session creation entirely** — no orphan terminal. |
| **Non-git cwd** | Grouped under `(no project)` / cwd / `(no branch)` per §6. |
| **Detached HEAD** | Branch label `(detached: abc1234)`. |
| **Missing `sessions.json`** | Treated as `{"version":1,"sessions":{}}`. Sessions still list from transcripts, named by timestamp + snippet (the current `claude#resume()` labelling) until renamed. |
| **Corrupt `sessions.json`** | `json_decode()` failure is caught; the file is renamed to `sessions.json.bak`, a warning is echoed once, and an empty store is used. Never fatal, never silently overwritten without a backup. |
| **Read-only plugin directory** | Warned once; names in-memory only (§4.2). |
| **Store schema from a future `version`** | Refuse to write, warn once, operate read-only. Prevents a downgrade from destroying newer data. |
| **Panel open when the last session is deleted** | Tree renders the header, a `(no sessions)` line, and the help hint. `n` still works. |
| **Panel is the only window** | Opening a session with `<CR>`/`i`/`x` creates the window to the panel's right via `s:split_cmd()`; the panel is never replaced. Deleting a session never leaves Vim with zero windows. |
| **Spawning with arguments** | The CLI is launched with an argv **List** via `term_start(argv, {'curwin': 1})`, never a command string. `:terminal` and `job_start()` run no shell: a string command is split on whitespace with quote characters kept literally, so a shell-quoted `--session-id '<uuid>'` reaches Claude as `'<uuid>'` (rejected as an invalid session id) and a name containing a space is torn into several arguments. |
| **Session started but never messaged** | Claude writes the transcript lazily, so there is nothing for `--resume <id>` to find and the CLI errors with "No session found with ID". Opening such a session spawns a fresh one with `--session-id <same id> --name <same name>` instead, keeping the panel row, the name and the id. `claude#session#has_transcript()` is the check. |
| **Named session with no transcript, after a Vim restart** | The record exists only in the store. `refresh()` restores store entries whose `cwd` matches the current directory, so a name given yesterday is still listed today. |
| **Transcript directory does not exist** | `glob()` returns empty; no closed sessions listed; no error (matches current `claude#resume()` behaviour). |
| **`claude` CLI lacks `--session-id` / `--name`** | Detected once by grepping `claude --help`; if absent, the plugin falls back to spawning without them and adopting the newest transcript in the project directory within 5 s as the session id, keeping the name Vim-side only. A one-time message names the minimum CLI version. |
| **Two Vim instances resume the same session id** | §5.4 guard; worst case the CLI itself arbitrates. |
| **`popup_menu()` unavailable** | `inputlist()` fallback. |
| **Terminal feature missing** | Same `echoerr` as today (`autoload/claude.vim:51`); the panel opens read-only and every open verb reports the same error. |

---

## 11. Test plan

New Vader suites under `test/`, run by the existing `make test`. Following the
current split between pure-function suites (`split_cmd.vader`) and
terminal-driven suites (`session_quit.vader`, using `let g:claude_cmd = 'sleep 30'`
as a CLI stand-in).

| File | Covers |
|------|--------|
| `test/store.vader` | Round-trip save/load; missing file → empty store; corrupt JSON → `.bak` + empty store; future `version` → read-only; unwritable path → graceful degradation; `claude#store#path()` honours `g:claude_session_store` and otherwise resolves under the plugin root. **No terminal needed.** |
| `test/session_group.vader` | `claude#session#group_of()` for: repo root, linked worktree resolving to the same project, non-git dir, detached HEAD, missing git. Uses a fixture repo created in a temp dir in `Before`, torn down in `After`. **No terminal needed.** |
| `test/session_registry.vader` | Create → record present, id is a valid UUID, status `active`; job killed → status `closed`, record retained; `rename()` updates registry and store; `delete()` stops the job and wipes the buffer; `purge()` removes the record; two concurrent sessions coexist in one tab. |
| `test/session_target.vader` | The §3.4 resolution rule: cursor-in-terminal wins; exactly-one-live needs no prompt; zero-live creates; `last_focus` ordering drives the picker order. Picker itself stubbed. |
| `test/panel_render.vader` | `claude#session#tree()` produces the expected nesting for a fixture registry; icons switch with `g:claude_panel_ascii`; duplicate names get ` (2)` suffixes; empty registry renders `(no sessions)`; `g:claude_panel_show_closed = 0` hides closed rows. Asserts on rendered buffer lines. |
| `test/panel_keys.vader` | Panel buffer options (`buftype`, `nomodifiable`, `winfixwidth`, `nobuflisted`); `q` hides the panel **and leaves jobs running**; `<CR>`/`i`/`x`/`t` each place the window as specified; the reuse rule jumps rather than duplicating; fold toggle persists across a redraw. |
| `test/session_quit.vader` | **Rewritten.** Same three regressions as today — `ExitPre` not `QuitPre`; an unrelated `:q` leaves jobs running; `:q` in a Claude window only hides it — but with **two** live sessions, asserting both survive. Plus: hiding the panel does not stop any job. |

`test/input_complete.vader` and `test/input_state.vader` need updating where they
depend on `t:claude_commands` / `t:claude_agents`, which move onto the session
record.

---

## 12. Future work

- **Cross-project listing.** Scan every directory under `~/.claude/projects/`, not
  just the current cwd slug, so the panel shows work from other repos. Needs: a
  cheap directory-level cache (hundreds of projects × dozens of transcripts each
  is too slow to `glob()` on every open), a decision about what "open" means for a
  session whose cwd is outside the current Vim's working directory (`lcd` into it?
  refuse?), and probably a filter/search line in the panel. Explicitly out of
  scope here.
- **Session search** — fuzzy-filter the tree by name or branch.
- **Transcript preview** — a popup showing the last few turns of the session
  under the cursor.
- **Per-session model** — record the model chosen via `:ClaudeModel` on the
  session record and pass `--model` on resume.
- **Session-aware statusline** — expose `claude#session#current()` for use in
  `statusline`.
- **Bulk operations** — visual-mode selection in the panel for multi-delete.
