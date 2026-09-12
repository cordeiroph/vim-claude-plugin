# Design: multi-agent support (Claude, Pi, Codex)

Status: proposed
Target: `claude.vim`
Last updated: 2026-09-12

---

## 1. Summary and motivation

The plugin drives one CLI. `g:claude_cmd` (`plugin/claude.vim:21`) names the
binary, and everything downstream of it — the argument vector, the session id,
the transcript on disk, the strings scraped off the terminal, the slash command
that switches models, the directories the input window completes from — is
Claude's shape, hard-coded in `autoload/claude/session.vim` and
`autoload/claude/input.vim`.

Three coding-agent CLIs are installed on this machine and all three are worth
running from the same panel:

| CLI | version | binary |
| --- | --- | --- |
| Claude Code | 2.x | `~/.local/bin/claude` |
| Pi | 0.84.2 | `/opt/homebrew/bin/pi` → `@earendil-works/pi-coding-agent` |
| Codex | 0.144.6 | `~/.local/bin/codex` (standalone Rust binary) |

The machinery the plugin has built around Claude — a registry that survives the
process, a panel grouped by project/worktree/branch, workspaces as git
worktrees, resume with stale-lock recovery — is not Claude-specific in
substance. Only its *bindings* are. This document works out what those bindings
are, what each of the three CLIs actually offers in their place, and what
abstraction turns one into three without changing what a Claude user sees.

Nothing here is implemented. No code, test or user doc was changed by the work
that produced this file.

---

## 2. What the plugin assumes about Claude today

### 2.1 Launch and flags

`s:build_argv()` (`autoload/claude/session.vim:814`) is the only place an
argument vector is built. It splits `g:claude_cmd` into words and appends,
in Claude's spelling:

- `--resume <id>` when reopening (`session.vim:817`),
- `--session-id <id>` when starting fresh (`session.vim:819`),
- `--name <name>` when the session was named (`session.vim:822`),
- `--resume <old> --fork-session` in the fork fallback (`session.vim:1258-1259`).

Whether the first three are used at all is decided by
`claude#session#supports_flags()` (`session.vim:778`), which runs
`<cmd> --help` once and greps it for `--session-id` and `--name`
(`session.vim:796-797`). The probe refuses to run unless the command's basename
starts with `claude` (`session.vim:790-792`) — a wrapper under another name
falls back to `g:claude_session_flags` (`plugin/claude.vim:148`).

`s:term_start()` (`session.vim:830`) runs the argv as a List (never a string:
the comment at `session.vim:806-813` records why) with `term_start()`'s `cwd`,
falling back to `:lcd` on Vim builds without it.

The deep assumption is not the flag names — it is that **a session id can be
chosen by the plugin before the process starts**. Everything else in the
registry follows from being able to say "this terminal is session `<uuid>`".

### 2.2 Session identity and transcripts

`claude#session#project_dir()` (`session.vim:212`) reproduces Claude's slug for
a working directory — every non-alphanumeric character becomes `-` — to reach
`~/.claude/projects/<slug>/`. The commit history shows how sharp that edge is:
`0a1183d` fixed the slug for a `pedro.cordeiro` home directory, where a wrong
guess silently broke every resume.

On top of that one path rule stand:

- `s:project_dirs()` (`:282`) — the current cwd's directory plus every
  workspace's, because a worktree session files its transcript under its own
  path;
- `s:transcript_paths()` (`:299`) — `glob('*.jsonl')` over those, newest first,
  capped at `g:claude_panel_closed_limit`;
- `s:scan_transcript()` (`:244`) — reads the first 60 lines of one and pulls
  `cwd`, `gitBranch` and the first `type: "user"` entry's text through
  `s:message_text()` (`:223`), which knows Claude's `message.content` block
  shape;
- `claude#session#transcript_path()` (`:1426`) — `<project_dir>/<id>.jsonl`,
  i.e. **the filename is the session id**, which `has_transcript()` (`:1440`),
  `is_foreign_active()` (`:1448`), `s:adopt_snippet()` (`:425`) and
  `claude#session#purge()` (`:1392`, deleting the file) all depend on;
- `claude#session#refresh()` (`:482`) — the whole panel's view of closed
  sessions is "what transcripts exist here", merged with the name store.

### 2.3 Live-process registry and resume recovery

`s:sessions_dir()` (`session.vim:1088`) reads `~/.claude/sessions/<pid>.json`,
the CLI's own registry of which process holds which session open.
`s:holder_pid()` (`:1094`) turns an id into a live pid, and
`s:preflight_resume()` (`:1121`) offers to kill it — the "stale session lock"
flow from commit `48433e2`.

What that cannot see is caught afterwards: `s:check_resumed()` (`:1221`)
watches a resumed terminal for the CLI's own `already in use` refusal
(`s:ALREADY_IN_USE_PAT`, `:1214`) and `s:retry_as_fork()` (`:1246`) re-runs the
spawn as `--resume <id> --fork-session`, then `s:adopt_forked_id()` (`:1288`)
re-keys the record onto whatever new transcript appears.

`s:adopt_id()` (`:1335`) is the same trick for the other direction: when the CLI
cannot be given an id, the plugin watches `s:known_transcripts()` (`:1320`) for
a file that was not there before and adopts its stem as the session id. **This
is the escape hatch that makes a CLI without `--session-id` supportable at
all.**

### 2.4 Terminal-output status detection

`s:term_tail()` (`session.vim:403`) keeps the bottom five rows of each terminal;
`s:classify()` (`:355`) matches them against `g:claude_panel_working_pat`
(default `'esc to interrupt'`, `plugin/claude.vim:73`) then
`g:claude_panel_waiting_pat` (a numbered choice, `Do you want`, `(y/n)`,
`plugin/claude.vim:80`). `claude#session#status()` (`:374`) falls back to the
idle timer when neither matches. The panel's "Needs you" group, its glyphs
(`claude#panel#icon()`, `autoload/claude/panel.vim:49`) and its syntax rules
(`panel.vim:213-226`) are all driven by the four statuses that come out of this.

Both defaults are Claude's chrome, not a protocol.

### 2.5 Sending text and commands

`s:send()` (`autoload/claude.vim:335`) wraps text in bracketed-paste escapes so
a multi-line message is not submitted line by line; `s:send_when_ready()`
(`:306`) waits for the TUI to paint anything first. `claude#explain()` (`:250`)
composes a fenced code block, and `claude#select_model()` (`:348`) sends the
literal text `/model <name>` picked from `g:claude_models`
(`plugin/claude.vim:26`), whose defaults are Claude model ids.

### 2.6 Completion data

`claude#input#collect_data()` (`autoload/claude/input.vim:58`) globs
`./.claude/commands/*.md` and `~/.claude/commands/*.md`, and the same pair for
`agents/`, on top of hard-coded lists of Claude's built-in slash commands
(`input.vim:4`) and built-in agents (`input.vim:28`).

### 2.7 Naming surface

`claude#*` autoload functions, `Claude*` Ex commands, `<leader>c*` mappings,
`g:claude_*` options, `ClaudeSession*` highlight groups, and the record fields
documented at `session.vim:1-43`. The word "Claude" also appears in user-facing
prompts (`s:prompt_branch()`/`s:prompt_name()`, `session.vim:869`/`:886`, the
picker titles in `autoload/claude.vim`, the panel header).

None of that is load-bearing for behaviour, but all of it is load-bearing for
users' vimrcs.

---

## 3. What the three CLIs actually do

Everything in this section was checked on this machine on 2026-09-12 —
`--help` output, session files on disk, and for Pi the shipped JavaScript
(`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/`). Where
a fact could not be established without driving the TUI interactively it is
marked **unverified**.

### 3.1 Capability matrix

| What the plugin needs | claude 2.x | pi 0.84.2 | codex 0.144.6 |
| --- | --- | --- | --- |
| Pre-assign the session id | `--session-id <uuid>` | `--session-id <uuid>` — opens that session if the project already has it, else creates it with that id (verified in `dist/main.js:341-348`) | **none**; the CLI mints its own |
| Resume by id | `--resume <id>` | `--session <id\|path>`, or `--session-id <id>` | `codex resume <id>` (subcommand, id or name) |
| Continue latest | `-c, --continue` | `-c, --continue` | `codex resume --last` |
| Interactive picker | `--resume` with no id | `-r, --resume` | `codex resume` |
| Fork | `--fork-session` (with `--resume`) | `--fork <id\|path>` (+ `--session-id` to choose the new id) | `codex fork` |
| Name at launch | `--name <name>` | `-n, --name <name>` | **none** — names exist (`codex resume/archive/delete <name>`) but are set inside the TUI (`/name` appears in the binary's strings) |
| Working directory | process cwd | process cwd, `--session-dir` for storage | process cwd, or `-C, --cd <dir>` |
| Model at launch | `--model` | `--model`, `--provider`, `--models`, `--thinking` | `-m, --model` |
| Model mid-session | `/model <name>` | Ctrl+P cycling over `--models`; a `/model` command is **unverified** | `/model` **unverified** |
| Transcript path | `~/.claude/projects/<slug(cwd)>/<id>.jsonl`, slug = every non-alnum → `-` | `~/.pi/agent/sessions/--<cwd minus leading slash, [/\:] → ->--/<timestamp>_<id>.jsonl` (verified, `dist/core/session-manager.js:240-246`, `:666-667`) | `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO ts>-<id>.jsonl` — **not keyed by cwd** |
| Filename is the id | yes | no — `<timestamp>_<id>.jsonl` | no — `rollout-<ts>-<id>.jsonl` |
| cwd recorded in the file | yes, on every user entry | yes, in the header line | yes, in the `session_meta` payload |
| git branch recorded | yes (`gitBranch`) | no | no (present in older versions' `git` block; absent in 0.144.6) |
| First user message | first `type:"user"` entry | first `{"type":"message", message.role:"user"}` entry | first `response_item` with `role:"user"` — **after** a `developer` permissions block and an `<environment_context>` user block that must be skipped |
| Name on disk | not stored (passed as `--name`) | `{"type":"session_info","name":…}` entries, latest wins (`session-manager.js:833-858`) | `~/.codex/session_index.jsonl`: `{id, thread_name, updated_at}` — no cwd |
| Live-holder registry | `~/.claude/sessions/<pid>.json` | none found under `~/.pi/agent` | `~/.codex/thread-writer-locks/` (empty here) and an app-server socket `~/.codex/ipc/ipc.sock` — **unverified** |
| "working" footer text | `esc to interrupt` | `<message> (<key> to interrupt)` (`dist/modes/interactive/interactive-mode.js:1741`) | binary contains `… to interrupt`; exact footer **unverified** |
| Alternate screen | inline | inline by default (`--tui-mode fullscreen` opts in) | **alt-screen by default**; `--no-alt-screen` gives inline |
| Custom commands / agents on disk | `.claude/commands/*.md`, `.claude/agents/*.md` (cwd and `~`) | `--skill`, `--prompt-template`, `--extension` paths; discovery roots **unverified** | skills/plugins under `~/.codex`; **unverified** |
| Config home override | — | `--session-dir` | `CODEX_HOME` |

### 3.2 Pi in detail

Pi is the closest of the three to Claude, and in one respect better: a single
flag covers both halves of the plugin's lifecycle. `dist/main.js:341-348` reads
(paraphrased): with `--session-id`, if a session with that exact id exists in
the project's session directory, open it; otherwise warn and create a new
session with that id. So `pi --session-id <uuid> [--name <name>]` is both
"spawn with an id I chose" and "resume that id" — `s:build_argv()`'s
resume/fresh branch collapses for this provider.

Session storage is per-cwd like Claude's, but the encoding differs in a way
that matters: `--${cwd.replace(/^[/\\]/,'').replace(/[/\\:]/g,'-')}--`
(`session-manager.js:245`). Only slashes, backslashes and colons are replaced,
so dots and underscores survive — the exact opposite of the bug fixed in
`0a1183d`. A shared slug helper would be wrong; each provider needs its own.

The session file's first line is the header
(`{"type":"session","version":3,"id":…,"timestamp":…,"cwd":…}`) and the display
name lives in later `session_info` entries, so a label scan must read past the
head of the file or accept that a renamed session shows its first message until
re-read.

No lock or live-process registry exists under `~/.pi/agent`, so
`s:preflight_resume()` has nothing to consult. Opening the same session id in
two Vim windows at once is undefined; treat it as unsupported until tested.

### 3.3 Codex in detail

Codex breaks three assumptions at once.

1. **No pre-assigned id.** Nothing in `codex --help` accepts a session id for a
   fresh run. The plugin must spawn, then adopt the id from whichever rollout
   file appears — exactly what `s:adopt_id()` (`session.vim:1335`) already does
   for a Claude CLI too old for `--session-id`, except the watch has to look
   under `~/.codex/sessions/<Y>/<M>/<D>/` rather than one project directory.
2. **Resume is a subcommand, not a flag.** `codex resume <id>` puts the verb
   before the options, so an argv builder that appends flags to
   `split(g:claude_cmd)` cannot express it. The provider must own the whole
   vector.
3. **Sessions are filed by date, not by project.** There is no directory whose
   contents are "this project's sessions". Listing them means walking date
   directories newest-first and reading each file's first line for `cwd`.
   `~/.codex/session_index.jsonl` gives `{id, thread_name, updated_at}` cheaply
   but carries no cwd, so it can label a session, not locate one.

Two smaller notes with real consequences. The rollout's first user-role entry is
not the user's first message — a `developer` permissions block and an
`<environment_context>` block come first, so the snippet scan has to skip
anything that starts with `<`. And the TUI takes the alternate screen unless
`--no-alt-screen` is passed; the panel reads status by scraping
`term_getline()`, so the provider should spawn Codex inline.

---

## 4. The provider model

### 4.1 Two shapes, and which one to take

**A — one registry file.** `autoload/claude/provider.vim` holds a dict per
provider, each field a script-local Funcref. One file, everything visible at
once; but it grows to hold three CLIs' path rules and parsers, and every
provider is sourced whether or not it is used.

**B — one autoload module per provider.** `autoload/claude/provider/claude.vim`,
`…/pi.vim`, `…/codex.vim`, each exporting the same function names, dispatched by
building the name: `claude#provider#claude#argv()`. A thin
`autoload/claude/provider.vim` resolves a provider name to its module, merges
user overrides over the module's `spec()` dict, and answers capability questions
with `exists('*claude#provider#<name>#<fn>')`.

**Take B.** Vim's autoload loads only the module actually used, so a
Claude-only user pays nothing for the other two. Optional hooks need no
placeholder implementations — a missing function *is* the capability answer,
which is the same idiom the plugin already uses for NERDTree and for `ExitPre`
(`plugin/claude.vim:275-281`). And each CLI's ugliest detail — its path slug,
its JSONL dialect — lives in one file that can be tested on its own, the way
`store.vim` is.

### 4.2 The provider interface

`spec()` is the only required function; it returns the static description:

```vim
" autoload/claude/provider/codex.vim
function! claude#provider#codex#spec() abort
  return {
        \ 'name':        'codex',
        \ 'label':       'Codex',
        \ 'cmd':         'codex',
        \ 'models':      ['gpt-5.6-codex', 'gpt-5.6'],
        \ 'working_pat': 'to interrupt',
        \ 'waiting_pat': '\%(^\|\n\)\s*❯\=\s*1\.\s\|Allow\|(y/n)',
        \ 'caps':        {'preassign_id': 0, 'name_flag': 0, 'fork': 1},
        \ }
endfunction
```

The rest are optional hooks, each with a defined fallback:

| Hook | Replaces | Fallback when absent |
| --- | --- | --- |
| `argv({spec})` — `{id, name, resume, model, cwd}` → List | `s:build_argv()` (`session.vim:814`) | `split(cmd)` alone |
| `sessions({cwds})` → list of `{id, path, cwd, branch, snippet, name, created}` | `s:project_dirs()`/`s:transcript_paths()`/`s:scan_transcript()` (`:282`,`:299`,`:244`) | no closed sessions listed; live ones still work |
| `transcript_path({id}, {cwd})` → path | `claude#session#transcript_path()` (`:1426`) | `has_transcript()` is 0, so a reopen always starts fresh under a new id |
| `holder_pid({id})` → pid | `s:holder_pid()` (`:1094`) | 0 — `s:preflight_resume()` becomes a no-op |
| `refusal_pat()` → pattern | `s:ALREADY_IN_USE_PAT` (`:1214`) | no fork retry |
| `model_text({model})` → String | the literal `/model ` in `claude#select_model()` (`autoload/claude.vim:371`) | `:ClaudeModel` reports "not supported by <provider>" |
| `completion({cwd})` → `{commands, agents}` | `claude#input#collect_data()` (`input.vim:58`) | file (`@`) completion only |
| `send({bufnr}, {text})` | `s:send()` (`autoload/claude.vim:335`) | bracketed paste, as today |

Two capability flags carry real branching and belong in `caps` rather than in a
hook: `preassign_id` decides whether `spawn()` hands the CLI a uuid or arms
`s:adopt_id()`, and `name_flag` decides whether a typed name reaches the CLI or
only the plugin's store.

`claude#session#supports_flags()` (`session.vim:778`) becomes the Claude
module's private business: it is a probe for *one* CLI's version skew, and its
`g:claude_session_flags` override keeps working for that provider alone.

### 4.3 The session record and the store

`s:make_record()` (`session.vim:550`) gains one field, `provider`, defaulting to
`'claude'`; `s:persist()` (`:933`) writes it; `claude#session#refresh()`
(`:482`) reads it back with `get(l:saved, 'provider', 'claude')`.

That `get()` default *is* the migration. A store written by today's plugin has
no `provider` key and every entry in it is a Claude session, which is exactly
what the default says. No schema bump: `s:VERSION` stays 1
(`store.vim:25`), since an older plugin reading a newer store simply ignores the
extra key and keeps working.

**Keys stay raw ids, not `provider:id`.** All three CLIs mint UUIDs, so a
collision is not a practical risk, and namespacing the key would ripple into the
store, `b:claude_session_id` (`autoload/claude.vim:202`), the panel's node keys
and every `_inject()` in the tests for no behavioural gain. The rule instead is:
**never resolve a path from an id without the record's provider.** A record is
always the unit passed around; `claude#session#transcript_path()` already takes
an id and looks the record up (`:1426-1436`), so it can read the provider from
the same record.

Discovery cost needs watching. `refresh()` runs on panel open and on `R`, and
today it globs one or two directories. With three providers it does three scans,
one of which (Codex) is not partitioned by project. The rule for the Codex
module: walk date directories newest-first, read only the first line of each
rollout, and stop at `g:claude_panel_closed_limit` matches or after a bounded
number of files (say 200), whichever comes first — then cache by file mtime the
way `s:adopt_snippet()` already does (`:433-438`).

### 4.4 Configuration

One new option decides the default, one dict carries per-provider overrides:

```vim
let g:claude_provider  = 'claude'          " provider for a new session
let g:claude_providers = {
      \ 'pi':    {'cmd': 'pi', 'models': ['sonnet:high', 'gpt-5.6-terra']},
      \ 'codex': {'cmd': 'codex --no-alt-screen'},
      \ }
```

`claude#provider#get(name)` returns `extend(copy(module_spec), get(g:claude_providers, name, {}))`,
so a user overrides one key without restating the rest.

Backward compatibility is a hard constraint, and it is cheap here because every
Claude-specific global keeps its meaning as *the Claude provider's* setting:

| Existing option | After |
| --- | --- |
| `g:claude_cmd` (`plugin/claude.vim:21`) | the Claude provider's `cmd`; wins over its spec default |
| `g:claude_models` (`:26`) | the Claude provider's `models` |
| `g:claude_panel_working_pat` / `_waiting_pat` (`:71`,`:77`) | the Claude provider's patterns, **and** the fallback for any provider whose spec omits one |
| `g:claude_session_flags` (`:148`) | the Claude provider's `--session-id`/`--name` probe override |
| `g:claude_sessions_dir` (`session.vim:1089`) | the Claude provider's live-holder directory |
| everything else (`panel_*`, `workspace_*`, `difftree_*`, stores) | unchanged, provider-agnostic |

A user who sets none of the new options gets today's plugin, byte for byte, in
behaviour.

### 4.5 Choosing a provider

- **New session, default path.** `:ClaudeNew [name]` and `<leader>cn` use
  `g:claude_provider`. Unchanged for anyone who never sets it.
- **New session, deliberate path.** The panel's `N` (`panel.vim:825`) already
  asks two questions — branch, then name. It gains a first question, *which
  agent*, asked only when more than one provider is configured, via the same
  `inputlist()`/popup idiom as `claude#session#pick()` (`session.vim:1513`).
  Command form: `:ClaudeNew` gains `-complete=customlist` on an optional
  `provider=<name>` leading word, or — simpler and more discoverable — a new
  `:ClaudeAgent [provider]` that starts a session with the named provider.
- **New session, panel `n`.** `s:new()` (`panel.vim:810`) reads the workspace
  off the row under the cursor; it should read the provider the same way —
  inherit it from the row's session when there is one, else `g:claude_provider`.
  Starting a second Codex session next to a Codex session should not ask.
- **`spawn()` opts** gain `provider`, defaulting to `g:claude_provider`
  (`session.vim:994`, whose docblock at `:973-993` lists the opts).
- **Display.** The panel row already supports a right-aligned suffix
  (`s:row()`, `panel.vim:273`). Show the provider name there, but **only
  when the listed sessions do not all share one provider** — a single-provider
  user's panel must look exactly as it does today. The state and place views
  stay as they are; provider is an attribute of a row, not a fourth grouping
  level.
- **Diff tree** needs no change: it reads branches off records
  (`difftree.vim:272-275`) and never touches the CLI.

### 4.6 Keep the `claude` namespace

Do not rename `claude#*`, `Claude*`, `g:claude_*` or `<leader>c*`.

The cost of renaming is every user's vimrc, 35 test files, seven modules and the
help file, plus a permanent alias layer to keep the old names alive. The gain is
that the word matches. Take the mismatch: the plugin is called claude.vim, and
its help file should open by saying it drives Claude Code, Pi and Codex. If the
name becomes untenable later, the migration is mechanical and can be done in one
commit with `Claude*` aliases retained — nothing in this design makes it harder.

The user-facing *prompts* are a different matter and should lose the hard-coded
vendor: "Open Claude session" → "Open session", `s:prompt_branch()`'s wording,
and the panel header. Those are strings, not API.

### 4.7 Two agents at once

The registry is already keyed by id with no per-CLI state, so a Claude session
and a Codex session can run side by side in one Vim; `poll()` (`session.vim:443`)
classifies each with its own provider's patterns. Workspaces are provider-
agnostic — two agents can share one worktree, which is a *choice* the user
makes, not something the plugin should prevent, but the panel's place view will
show them under the same branch node and that reads correctly.

The one asymmetry to document: only Claude has a live-holder registry, so only
Claude gets the "still held by process N — kill it?" recovery
(`s:preflight_resume()`, `:1121`). For Pi and Codex, resuming a session that is
already open elsewhere fails in whatever way the CLI chooses, and the plugin
shows it on the terminal.

---

## 5. What each provider gives up

| Feature | claude | pi | codex |
| --- | --- | --- | --- |
| Spawn with a plugin-chosen id | yes | yes | no — id adopted after spawn (`s:adopt_id()` path) |
| Resume a conversation | `--resume` | `--session-id` (same flag as spawn) | `codex resume <id>` |
| Fork when a resume is refused | yes | yes (`--fork`) | `codex fork` — **unverified** whether it takes an id |
| Name reaches the CLI | yes | yes | no — name lives in the plugin store only, unless `/name` is sent into the TUI (opt-in, unverified) |
| Panel lists closed sessions | yes | yes | yes, at a higher scan cost |
| Label from first message | yes | yes | yes, after skipping the `<environment_context>` preamble |
| Branch shown without git | from `gitBranch` | derived from cwd via `group_of()` | derived from cwd via `group_of()` |
| Stale-lock recovery | yes | no registry to consult | `thread-writer-locks/` — unverified |
| `:ClaudeModel` mid-session | `/model` | Ctrl+P; `/model` unverified | `/model` unverified |
| Slash-command completion | full | needs pi's discovery roots | needs codex's prompt/skill roots |
| Explain / input window | yes | yes (bracketed paste assumed) | yes (bracketed paste assumed) |

Nothing above is a blocker for a first Codex or Pi session; the losses are
concentrated in naming and recovery, and each degrades to "the plugin still
knows about the session, the CLI just isn't told".

---

## 6. Sequencing

Each stage ships on its own and leaves the plugin working.

1. **Seam, no behaviour change.** Add `autoload/claude/provider.vim` and
   `autoload/claude/provider/claude.vim`; move `s:build_argv()`,
   `supports_flags()`, `project_dir()`, `scan_transcript()`, `sessions_dir()`,
   `holder_pid()` and the two patterns behind it. Every existing test must pass
   unchanged — that is the stage's acceptance criterion.
2. **Provider on the record.** Add the field, persist it, default it on read,
   and show the suffix in the panel when the list is mixed. Still Claude only.
3. **Pi.** `autoload/claude/provider/pi.vim`: `--session-id` for both spawn and
   resume, `--name`, the `--…--` cwd encoding, `<ts>_<id>.jsonl` globbing,
   `session_info` names, `to interrupt`.
4. **Codex.** `autoload/claude/provider/codex.vim`: spawn plain with
   `--no-alt-screen`, adopt the id from a new rollout, `codex resume <id>`,
   date-dir scan with the bounded walk from §4.3, `session_index.jsonl` for
   names, `<environment_context>` skip in the snippet scan.
5. **Choice UX.** `g:claude_provider`, `g:claude_providers`, the panel's `N`
   question, `n` inheritance, `spawn()` opts, `:ClaudeAgent`, per-provider model
   lists.
6. **Docs.** `README.md` (a section after "Session names") and
   `doc/claude.txt` (a new section before WORKSPACES, plus the new options in
   CONFIGURATION and the new command in COMMANDS).

---

## 7. Test plan

The harness is Vader: `make test` runs `vim -u test/vimrc -c 'Vader! test/*.vader'`.
The seams that make this testable already exist —
`claude#session#_argv()` (`session.vim:1571`), `_classify()` (`:1576`),
`_holder_pid()` (`:1582`), `_inject()` (`:1588`), `_reset()` (`:1562`),
`g:claude_cmd = 'sleep 30'` stubs (e.g. `test/session_registry.vader:10`) and
`g:claude_sessions_dir`.

**Extend**

- `test/session_registry.vader` — the argv assertions at `:212`, `:218-223`,
  `:251` become per-provider: Claude unchanged, Pi asserting `--session-id` on
  both spawn and resume, Codex asserting `['codex', 'resume', '<id>']` word
  order and no `--session-id` on a fresh spawn.
- `test/session_project_dir.vader` — keep the Claude slug cases; add the Pi
  encoding (`--Users-me-repo--`, dots and underscores *preserved*) and assert
  Codex has no per-cwd directory at all.
- `test/session_label.vader` — add a Pi session file (header line + `message`
  entry + `session_info`) and a Codex rollout (`session_meta` +
  `<environment_context>` block + a real user message) and assert the snippet
  skips the preamble.
- `test/store.vader` — a store entry without `provider` loads as `'claude'`; one
  with it round-trips.
- `test/panel_render.vader` / `test/panel_groups.vader` — the provider suffix
  appears only when the listed sessions are mixed.

**New**

- `test/provider_registry.vader` — `get()` merges `g:claude_providers` over the
  module spec; an unknown name falls back to Claude with one warning; a missing
  optional hook is reported as absent rather than erroring.
- `test/provider_argv.vader` — `argv()` for all three providers across
  spawn/resume/named/model, driven through `claude#session#_argv()`.
- `test/provider_sessions.vader` — each module's `sessions()` against a fixture
  tree written into a temp dir, including the Codex bounded walk (assert it
  stops early with many date directories).
- `test/provider_classify.vader` — `_classify()` picks the record's provider's
  patterns, and `g:claude_panel_working_pat` still overrides for Claude.

**Done looks like**: `make test` green; a Claude-only vimrc produces identical
argv, identical panel rows and identical store contents to the pre-change build;
a Pi session and a Codex session can be started, listed, labelled, closed and
resumed from the panel in one Vim instance.

---

## 8. Risks and open questions

**Risks**

- *Scan cost.* Codex's date-partitioned store is the one real performance
  hazard; the bounded walk in §4.3 must be in place from the first Codex commit,
  not added after someone with 2,000 rollouts opens the panel.
- *Silent format drift.* Three JSONL dialects now sit in the plugin, each read
  by position and key name. A CLI upgrade that renames a field degrades to
  "no label, no cwd" rather than an error; `s:scan_transcript()`'s
  try/catch-and-continue (`session.vim:256-260`) is the right shape to copy, and
  each provider should warn once via `s:warn_once()` (`:73`) when a scan yields
  nothing from files that exist.
- *Status patterns are chrome.* `to interrupt` is a footer string in all three
  TUIs today and in none of their contracts. The idle-timer fallback
  (`:397`) keeps the panel sane when a pattern stops matching, but "Needs you"
  quietly stops working — worth a note in the help file.
- *Scope creep into a rename.* §4.6 is a decision, not a deferral; reopening it
  mid-implementation would double the diff.

**Open questions** — each needs an answer before the stage that depends on it:

1. Does `pi --session-id <uuid>` reliably reopen a session started by a
   *previous* Vim run, in the same cwd? (Source says yes; needs one manual run.)
   — blocks stage 3.
2. Does Pi accept bracketed paste for multi-line input, and does Codex?
   — blocks the input window for those providers.
3. Does Codex have a `/name` command, and can the plugin send it right after
   spawn without racing the TUI? If not, Codex names stay plugin-local.
   — blocks the naming half of stage 4.
4. Does `codex fork` accept a session id non-interactively, and is there any
   equivalent of the `already in use` refusal to detect?
   — decides whether stage 4 gets a fork fallback at all.
5. What are `~/.codex/thread-writer-locks/` entries, and do they name a live
   holder? — decides whether Codex gets stale-lock recovery.
6. Where do Pi's skills/prompt-templates and Codex's prompts/skills live by
   default? — blocks completion for those providers (§4.2 `completion()`).
7. Does Codex's alternate screen actually break `term_getline()` scraping, or
   is `--no-alt-screen` merely nicer? — decides whether that flag is forced or
   merely the default in `g:claude_providers`.
