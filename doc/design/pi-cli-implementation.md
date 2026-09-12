# Design: Pi CLI support

Status: proposed
Target: `claude.vim`
Last updated: 2026-09-12

---

## 1. Summary and scope

`doc/design/multi-agent-support.md` worked out how the plugin could drive more
than one coding-agent CLI. This document is the build plan for the first half of
it: **the provider seam, with Pi as its first non-Claude tenant.**

What ships:

- `autoload/claude/provider.vim` — a registry — plus one module per CLI,
  `autoload/claude/provider/claude.vim` and `autoload/claude/provider/pi.vim`.
- A `provider` field on every session record, defaulting to `'claude'`.
- `:PiNew [name]`, mapped to `<leader>pn`, starting a Pi session.
- The panel's `N` asks which agent first; `n` never asks and uses the default.
- `g:claude_provider` (the default CLI) and `g:claude_providers` (per-provider
  overrides).

What does not ship, and must not be started here: Codex. The seam is shaped so
`autoload/claude/provider/codex.vim` drops in later (design doc §4.2, §6 stage
4) without reopening anything specified below.

What must not change: every existing command
(`plugin/claude.vim:228-264`), every existing `<leader>c*` mapping
(`:310-353`), every existing option, and the behaviour of a vimrc that never
sets `g:claude_provider` — same argv, same panel rows, same store contents.

### 1.1 What Pi gives us

Verified on this machine (pi 0.84.2, `/opt/homebrew/bin/pi` →
`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/`). Facts
carried from the design doc §3.2 are cited there; facts established while
writing *this* document are cited to the shipped JavaScript.

| | Pi |
| --- | --- |
| Spawn with our id | `--session-id <uuid>` |
| Resume | the same flag — it opens the session if the project has that id, else creates it (`dist/main.js:341-348`) |
| Id format accepted | `^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$` (`core/session-manager.js:15-19`) — a v4 UUID from `claude#session#uuid()` (`session.vim:100`) passes |
| Flags that conflict with `--session-id` | `--session`, `--continue`, `--resume` (`main.js:241-252`); `--name` and `--fork` do not |
| Name at launch | `-n, --name <name>`; also `/name <text>` in the TUI (`modes/interactive/interactive-mode.js:2369`) |
| Sessions on disk | `~/.pi/agent/sessions/--<cwd minus leading slash, [/\:] → ->--/<timestamp>_<id>.jsonl` (`core/session-manager.js:245`, `:666-667`) |
| Storage override | `--session-dir <dir>` |
| Header line | `{"type":"session","version":3,"id":…,"timestamp":…,"cwd":…}` |
| First user message | `{"type":"message","message":{"role":"user","content":[{"type":"text","text":…}]}}` |
| Display name | latest `{"type":"session_info","name":…}` entry (`core/session-manager.js:833-858`) |
| Working footer | `<message> (<key> to interrupt)` (`interactive-mode.js:1741`) |
| Bracketed paste | supported (`interactive-mode.js:1892`, `:2293`, `:3166`) — the input window and `:ClaudeExplain` work unchanged |
| Model switch | `/model <exact id>` switches directly; anything else opens Pi's selector filtered by the term (`interactive-mode.js:2343-2347`, `:3863-3884`) |
| Slash commands | 25 built-ins, enumerable from `interactive-mode.js` (`/model`, `/name`, `/new`, `/resume`, `/fork`, `/compact`, `/export`, `/session`, `/tree`, `/settings`, `/trust`, `/login`, `/logout`, `/quit`, …) |
| Custom commands | `.md` files in `~/.pi/agent/prompts/` and `<cwd>/.pi/prompts/` (`core/prompt-templates.js:149-160`, `:134`); skills in `…/skills/` (`core/resource-loader.js:622-632`); `CONFIG_DIR_NAME` is `.pi` (`config.js:394`) |
| Agents (`@name`) | no such concept — `@` stays file completion |
| Live-holder registry | none under `~/.pi/agent` |
| git branch in the session file | not recorded |

Two consequences shape the module. First, **one flag covers spawn and resume**,
so Pi never needs the `--resume` / `--session-id` fork in `s:build_argv()`
(`session.vim:814-828`). Second, **the filename is not the id**
(`<timestamp>_<id>.jsonl`), so every place that builds `<dir>/<id>.jsonl` by
hand has to go through the provider.

---

## 2. What the change touches

Every call site, with what it assumes today.

| Site | Today | Why it changes |
| --- | --- | --- |
| `s:build_argv()` `session.vim:814` | `--resume` / `--session-id` / `--name` | provider owns the argv |
| `claude#session#supports_flags()` `:778` | probes `claude --help`, gated on a basename starting with `claude` (`:790-792`) | becomes the Claude module's private probe |
| `claude#session#project_dir()` `:212` | `~/.claude/projects/<slug>` | Claude's path rule; Pi's is different (§3.3) |
| `s:scan_transcript()` `:244`, `s:message_text()` `:223` | Claude's JSONL dialect | Pi's dialect differs |
| `s:project_dirs()` `:282`, `s:transcript_paths()` `:299` | glob `<project_dir>/*.jsonl` | per provider, and both must be unioned |
| `claude#session#refresh()` `:482` | one transcript sweep | sweeps every registered provider |
| `s:make_record()` `:550`, `s:persist()` `:933` | no provider field | gains one |
| `claude#session#transcript_path()` `:1426` | `<project_dir>/<id>.jsonl` | Pi's filename carries a timestamp |
| `claude#session#has_transcript()` `:1440` | `filereadable()` of the above | same, via the provider |
| `claude#session#is_foreign_active()` `:1448` | rebuilds that path inline | must reuse `transcript_path()` |
| `claude#session#purge()` `:1392` | `delete(project_dir . '/' . id . '.jsonl')` | same |
| `s:sessions_dir()` `:1088`, `s:holder_pid()` `:1094`, `s:preflight_resume()` `:1121` | `~/.claude/sessions/<pid>.json` | Claude-only; Pi has no registry |
| `s:classify()` `:355` + `s:working_pat()`/`s:waiting_pat()` `:64`,`:68` | two globals | per-provider patterns |
| `claude#session#spawn()` `:994` | `supports_flags()` decides id pre-assignment | provider capability decides |
| `claude#session#resume()` `:1147` | `has_transcript()` decides `--resume` | provider decides |
| `claude#select_model()` `autoload/claude.vim:348` | literal `/model ` at `:371`, `g:claude_models` | per-provider model list and text |
| `claude#input#collect_data()` `input.vim:58` | `.claude/commands`, `.claude/agents` | per-provider sources |
| `s:new()` `panel.vim:811`, `s:new_asking()` `:825` | no provider | §5 |
| `s:suffix()` `panel.vim:321`, `s:matches()` `:334` | where + age | §6 |
| `plugin/claude.vim` | commands `:228-264`, mappings `:309-353` | `:PiNew`, `<leader>pn`, two new options |

---

## 3. The provider seam

### 3.1 `autoload/claude/provider.vim`

A thin registry. It holds no CLI knowledge; it resolves names to modules, merges
user overrides over a module's `spec()`, and answers "does this provider
implement that hook?".

```vim
" Providers shipped with the plugin, in the order pickers offer them.
let s:BUILTIN = ['claude', 'pi']

" Every registered provider's name.
function! claude#provider#names() abort

" The configured default, validated: an unknown g:claude_provider warns once
" via s:warn_once() and falls back to 'claude'.
function! claude#provider#default() abort

" The merged spec for {name}: the module's spec() with
" get(g:claude_providers, name, {}) extended over it. Cached per name.
function! claude#provider#get(name) abort

" A record's provider name, defaulting to 'claude' for records and store
" entries written before this change.
function! claude#provider#of(rec) abort

" Whether {name} implements hook {fn}.
function! claude#provider#has(name, fn) abort
  return exists('*claude#provider#' . a:name . '#' . a:fn)
endfunction

" Call {fn} on {name} with {args}, returning {default} when it is not
" implemented. This is the only way call sites reach a provider.
function! claude#provider#call(name, fn, args, default) abort
```

`claude#provider#get()` must not source a module it is not asked about: Vim
autoload loads `autoload/claude/provider/pi.vim` the first time
`claude#provider#pi#spec()` is referenced, so a Claude-only user never pays for
Pi. `claude#provider#has()` uses `exists('*…')`, which does *not* trigger
autoload; the registry therefore calls `spec()` first (forcing the load) and
only then asks about hooks — do this once, in `get()`, and cache.

### 3.2 The spec

```vim
function! claude#provider#pi#spec() abort
  return {
        \ 'name':        'pi',
        \ 'label':       'Pi',
        \ 'cmd':         'pi',
        \ 'models':      ['gpt-5.6-terra', 'anthropic/claude-sonnet-4-6'],
        \ 'working_pat': 'to interrupt',
        \ 'waiting_pat': '\%(^\|\n\)\s*❯\=\s*1\.\s\|(y/n)',
        \ 'caps':        {'preassign_id': 1, 'name_flag': 1},
        \ }
endfunction
```

`caps.preassign_id` replaces `supports_flags()` at the two sites that branch on
it (`session.vim:1072`, `:1194`); `caps.name_flag` says whether a typed name
reaches the CLI or only the store. Everything else is a hook.

The Claude module's spec carries today's defaults, and reads the existing
globals so they keep working: `cmd` from `g:claude_cmd` (`plugin/claude.vim:21`),
`models` from `g:claude_models` (`:26`), the two patterns from
`g:claude_panel_working_pat`/`_waiting_pat` (`:71`,`:77`), `caps.preassign_id`
from the `claude --help` probe it now owns.

### 3.3 Hooks

| Hook | Claude | Pi |
| --- | --- | --- |
| `argv({spec})` | as `s:build_argv()` today | §3.4 |
| `sessions({cwds})` | today's sweep | §3.5 |
| `transcript_path({id}, {cwd})` | `<project_dir(cwd)>/<id>.jsonl` | glob `*_<id>.jsonl` |
| `holder_pid({id})` | `~/.claude/sessions/<pid>.json` | **not implemented** → 0 |
| `refusal_pat()` | `'already in use'` | **not implemented** → no fork retry |
| `model_text({model})` | `'/model ' . model` | `'/model ' . model` |
| `completion({cwd})` | `.claude/commands`, `.claude/agents` | §3.6 |
| `send({bufnr}, {text})` | **not implemented** → bracketed paste | **not implemented** → bracketed paste |

### 3.4 `claude#provider#pi#argv()`

```vim
" {spec} is {'id', 'name', 'resume', 'model', 'cwd'}; 'resume' is ignored —
" --session-id opens an existing project session and creates a missing one
" (dist/main.js:341-348), so spawn and resume are the same vector. It must not
" be combined with --session/--continue/--resume (main.js:241-252).
function! claude#provider#pi#argv(spec) abort
  let l:argv = split(claude#provider#get('pi').cmd)
  call extend(l:argv, ['--session-id', a:spec.id])
  if !empty(get(a:spec, 'name', ''))
    call extend(l:argv, ['--name', a:spec.name])
  endif
  if !empty(get(a:spec, 'model', ''))
    call extend(l:argv, ['--model', a:spec.model])
  endif
  let l:dir = get(claude#provider#get('pi'), 'session_dir', '')
  if !empty(l:dir)
    call extend(l:argv, ['--session-dir', expand(l:dir)])
  endif
  return l:argv
endfunction
```

The List form is not optional; the reasoning at `session.vim:806-813` applies
unchanged — a name with a space in it must survive as one argument.

### 3.5 Paths and the transcript sweep

```vim
" ~/.pi/agent/sessions/--Users-me-project--/, per core/session-manager.js:245:
"   `--${cwd.replace(/^[/\\]/,'').replace(/[/\\:]/g,'-')}--`
" Only slashes, backslashes and colons are replaced. Dots and underscores
" survive — the opposite of Claude's rule (session.vim:203-213, commit
" 0a1183d), so this must never be folded into claude#session#project_dir().
function! claude#provider#pi#session_dir(cwd) abort
  let l:base = substitute(a:cwd, '^[/\\]', '', '')
  let l:slug = substitute(l:base, '[/\\:]', '-', 'g')
  let l:root = get(claude#provider#get('pi'), 'sessions_root',
        \ '~/.pi/agent/sessions')
  return expand(l:root) . '/--' . l:slug . '--'
endfunction

" The filename carries a timestamp, so an id maps to a file by glob, not by
" concatenation. '' when nothing matches.
function! claude#provider#pi#transcript_path(id, cwd) abort
  let l:hits = glob(claude#provider#pi#session_dir(a:cwd)
        \ . '/*_' . a:id . '.jsonl', 0, 1)
  return empty(l:hits) ? '' : l:hits[0]
endfunction
```

`sessions({cwds})` mirrors `s:project_dirs()`/`s:transcript_paths()`
(`session.vim:282`,`:299`): take the cwds it is handed (Vim's, plus every
workspace path — the caller still assembles that list), glob `*.jsonl` in each
session directory, sort newest-first by `getftime()`, cap at
`g:claude_panel_closed_limit`, and return one dict per file:

```vim
{'id':      <header id, not the filename stem>,
 'path':    <file>,
 'cwd':     <header cwd>,
 'branch':  '',              " Pi records none; group_of(cwd) fills it in
 'snippet': <first user message text>,
 'name':    <latest session_info name seen in the scanned window>,
 'created': getftime(path)}
```

Scan with the same shape as `s:scan_transcript()` (`:244-280`): `readfile(path,
'', 200)`, `json_decode()` each line inside a `try`/`continue`
(`session.vim:256-260`), stop early once cwd and snippet are both known **and**
no `session_info` can still be the latest one — in practice, read the window,
keep the last `session_info` in it. 200 lines rather than Claude's 60 because
the name is appended over time; `--name` puts one near the head, which is the
common case.

A Pi record's `name` competes with the store's. Rule: **the store wins when the
user typed the name here** (`s:was_named()`, `session.vim:906`), otherwise the
`session_info` name is adopted as the label — a rename done inside Pi's TUI then
shows up in the panel on the next `R`.

### 3.6 Completion

`claude#provider#pi#completion(cwd)` returns
`{'commands': [...], 'agents': []}`:

- `commands`: Pi's 25 built-ins as a literal list in the module (same shape as
  `s:slash_commands_base`, `input.vim:4`), plus `/` + the stem of every `.md`
  file in `~/.pi/agent/prompts/` and `<cwd>/.pi/prompts/`
  (`core/prompt-templates.js:149-160`; the scan is non-recursive, `:134`).
- `agents`: empty. Pi has no `@agent` concept, so `@` completes files only —
  which `claude#input#complete()` already does when the agent list is empty
  (`input.vim:118-156`).

---

## 4. The edit plan, file by file

### 4.1 `autoload/claude/session.vim`

**`s:build_argv(id, name, resume)` → `s:build_argv(id, name, resume, provider)`**
(`:814`). The body becomes one dispatch:

```vim
function! s:build_argv(id, name, resume, provider) abort
  return claude#provider#call(a:provider, 'argv',
        \ [{'id': a:id, 'name': a:name, 'resume': a:resume}],
        \ split(claude#provider#get(a:provider).cmd))
endfunction
```

The test seam `claude#session#_argv(id, name, resume)` (`:1571`) gains an
optional fourth argument defaulting to `'claude'`, so every assertion in
`test/session_registry.vader` keeps compiling and keeps passing.

**`claude#session#supports_flags()`** (`:778`) moves wholesale into
`autoload/claude/provider/claude.vim` as the private probe behind that module's
`caps.preassign_id`, keeping `g:claude_session_flags` (`plugin/claude.vim:148`)
and the basename guard (`:790-792`). The public function stays as a deprecated
one-line wrapper returning the Claude provider's capability, because
`test/session_registry.vader` calls it.

**`claude#session#project_dir(cwd)`** (`:212`) stays public and keeps its exact
behaviour, delegating to `claude#provider#claude#project_dir()`. That is not
tidiness: `test/session_project_dir.vader` asserts against it directly, and
those assertions must not be rewritten by this change.

**`claude#session#refresh()`** (`:482`) sweeps every provider instead of one:

```vim
let l:cwds = s:sweep_cwds()          " getcwd() + every workspace path
for l:name in claude#provider#names()
  for l:scan in claude#provider#call(l:name, 'sessions', [l:cwds], [])
    " … the existing per-transcript body, with l:rec.provider = l:name
  endfor
endfor
```

`s:sweep_cwds()` is `s:project_dirs()` (`:282`) with the provider-specific path
construction lifted out: it returns *directories the user works in*, and each
provider maps those to its own storage. A session already in `s:sessions` is
still skipped (`:487-489`), so the sweep order does not matter.

**`s:make_record()`** (`:550`) takes a `provider` argument and stores it;
**`s:persist()`** (`:933`) writes `'provider': a:rec.provider`; the two
`s:make_record()` calls in `refresh()` (`:507`, `:524`) pass
`get(l:saved, 'provider', 'claude')`. That `get()` default is the whole
migration — a store written before this change contains only Claude sessions,
which is exactly what it says. `s:VERSION` stays 1 (`store.vim:25`): an older
plugin reading a newer store ignores the extra key.

**`claude#session#transcript_path(id)`** (`:1426`) keeps its signature and
dispatches on the record's provider:

```vim
return claude#provider#call(claude#provider#of(l:rec), 'transcript_path',
      \ [a:id, l:rec.cwd], '')
```

**`claude#session#is_foreign_active()`** (`:1448`) and
**`claude#session#purge()`** (`:1392`) stop building
`project_dir(cwd) . '/' . id . '.jsonl'` inline and call
`claude#session#transcript_path()` instead. This is a real bug fix for Pi, whose
filenames carry a timestamp, and a no-op for Claude.

**`s:classify(tail)`** (`:355`) becomes `s:classify(tail, provider)` and reads
the patterns from the provider spec; `s:working_pat()`/`s:waiting_pat()`
(`:64`,`:68`) become provider lookups that still honour the two globals for
Claude. The seam `claude#session#_classify(tail)` (`:1576`) gains an optional
provider argument defaulting to `'claude'`.
`claude#session#status()` (`:374`) passes `claude#provider#of(l:rec)`.

**`claude#session#spawn(opts)`** (`:994`): the docblock at `:973-993` gains

```
"   provider   which CLI to run: 'claude' (default), 'pi'. Defaults to
"              g:claude_provider
```

the record is created with it, the argv call passes it, and the id
pre-assignment branch at `:1072` tests
`claude#provider#get(l:provider).caps.preassign_id` instead of
`supports_flags()`. When `caps.name_flag` is 0 the name is still stored and
still labels the row — it simply never reaches the CLI.

**`claude#session#resume(id, ...)`** (`:1147`) reads the provider off the
record. Two branches become provider questions: `s:preflight_resume()` (`:1121`)
returns 1 immediately when the provider implements no `holder_pid` hook, and
`s:check_resumed()`/`s:retry_as_fork()` (`:1221`,`:1246`) are armed only when
the provider implements `refusal_pat()`. For Pi both are skipped, which is
correct — there is no lock to clear and no refusal to route around.

**`claude#session#new(...)`** (`:956`) gains an optional third argument,
`provider`, defaulting to `claude#provider#default()`. a:1 (name) and a:2
(placement) keep their meaning; no caller passes a:2 today
(`autoload/claude.vim:21`, `session.vim:1505`, `:1550`, `panel.vim:827`), so
nothing else moves.

### 4.2 `autoload/claude.vim`

**`claude#new(...)`** (`:20`) gains a:2 provider and forwards it:

```vim
function! claude#new(...) abort
  call claude#session#new(a:0 > 0 ? a:1 : '', '',
        \ a:0 > 1 ? a:2 : claude#provider#default())
endfunction
```

(with `''` for placement meaning "as before" — keep the existing default by
passing the current sentinel rather than a literal, i.e. omit a:2 in the call
when only a name is given).

**`claude#select_model()`** (`:348`) resolves the target session first, then
reads that session's provider: the menu is built from that provider's `models`
and the text sent is `claude#provider#call(p, 'model_text', [l:model], '')`.
When the hook is absent, echo
`'claude.vim: <label> has no in-session model switch'` and send nothing. The
literal `/model ` at `:371` disappears. `g:claude_models` keeps working because
it feeds the Claude provider's spec.

### 4.3 `autoload/claude/input.vim`

`claude#input#collect_data(...)` (`:58`) asks the session's provider:

```vim
let l:data = claude#provider#call(l:provider, 'completion', [getcwd()],
      \ {'commands': [], 'agents': []})
```

The Claude built-ins (`:4`, `:28`) and the `.claude/commands`/`.claude/agents`
globs (`:61-75`) move into `autoload/claude/provider/claude.vim` unchanged. The
fallback caches `s:last_commands`/`s:last_agents` (`:77-78`) stay as they are —
they are only consulted when no session can be resolved.

---

## 5. Commands and keys

### 5.1 `:PiNew` and `<leader>pn`

In `plugin/claude.vim`, next to `:ClaudeNew` (`:240`):

```vim
" A session on another CLI. One command per provider, spelled after the CLI
" rather than the plugin: :PiNew, and :CodexNew when Codex lands.
command! -nargs=? PiNew call claude#new(<q-args>, 'pi')
```

and in the mapping block, after `<leader>cn` (`:317`, inside the
`g:claude_no_default_mappings` guard at `:309`):

```vim
  " Start a Pi session, whatever the default CLI is.
  nnoremap <silent> <leader>pn :PiNew<CR>
```

Two decisions to record. First, `:PiNew` breaks the `Claude*` prefix every other
command carries. That is deliberate and is the user's call: the command is named
after the CLI it starts, and the pattern extends to `:CodexNew`. The plugin's
own commands stay `Claude*`, so nothing existing moves. Second, the commands are
**hard-coded, not generated** from `claude#provider#names()`: generating them
would force `autoload/claude/provider.vim` to be sourced at startup, which is
exactly what the autoload layout exists to avoid.

`<leader>pn` sits outside the `<leader>c*` family, so it cannot collide with it;
it is disabled by `g:claude_no_default_mappings` like everything else.

### 5.2 The panel's `N` — pick the agent first

`s:new_asking()` (`panel.vim:825`) currently goes straight to
`claude#session#new()`, which asks for a branch (`s:prompt_branch()`,
`session.vim:869`) and then a name (`s:prompt_name()`, `:886`). It gains a
question before those two:

```vim
" N — the deliberate one: which agent, which branch, what to call it.
function! s:new_asking() abort
  let [l:ok, l:provider] = s:ask_provider()
  if !l:ok
    return
  endif
  call s:enter_main()
  let l:id = claude#session#spawn({'prompt': 1, 'provider': l:provider})
  if !empty(l:id)
    call claude#session#touch_focus(l:id)
  endif
endfunction
```

`s:ask_provider()` returns `[1, name]`, or `[0, '']` when cancelled — the same
contract as `s:prompt_branch()` (`session.vim:869-878`), so CTRL-C at the new
prompt abandons the whole spawn and creates nothing. It must:

- **ask nothing when only one provider is registered**, returning
  `[1, claude#provider#default()]`. A Claude-only user sees exactly today's two
  questions;
- use `popup_menu()` when `s:use_popup()` says so (`session.vim:1555`) and
  `inputlist()` otherwise, matching `claude#session#pick()` (`:1513-1553`) —
  including its asynchronous callback shape, which is why `s:new_asking()`
  should be restructured as a callback rather than a straight-line function if
  the popup path is taken;
- offer providers in `claude#provider#names()` order with the default first,
  labelled by `spec().label`, so the muscle-memory answer is `1`;
- **not** filter by `executable()`. `cmd` may be a wrapper, a shell function or
  `env FOO=1 pi`, exactly as `g:claude_cmd` may be today.

The inline help block (`panel.vim:517-527`) keeps `N new…`; the ellipsis already
says "this one asks". The help file is where the new question is documented.

### 5.3 The panel's `n` — never asks

`s:new()` (`panel.vim:811`) keeps its single name question and gains no prompt.
It takes the provider from **the row under the cursor**, falling back to
`claude#provider#default()` when the cursor is not on a session row:

```vim
let [l:ws, l:dir] = s:place_under_cursor()
let l:provider    = s:provider_under_cursor()
```

This is the same reasoning the workspace already follows (`s:place_under_cursor()`,
`panel.vim:766`, and the comment at `:796-798`): `n` means *another session like
this one, here*. Pressing `n` on a Pi row and getting a Claude session would be
a surprise; pressing it on a project header, where no session is named, falls
back to the configured default. `s:provider_under_cursor()` reads
`s:nodes[line('.') - 1]`, walks up to the nearest `session` node the way the
directory walk at `:785-791` does, and returns
`claude#provider#of(claude#session#get(node.id))`.

---

## 6. What the panel shows

A session's agent is an attribute of a row, not a grouping level: neither view
changes shape.

`s:suffix()` (`panel.vim:321`) already composes the right-hand column —
`<where> · <age>` in the state view, `<age>` in the place view. When **more than
one provider appears among the listed sessions**, prepend the provider's name to
it (`pi · ws · 3m`); when they all share one, change nothing. `s:row()`
(`:273`) drops the whole suffix rather than squeezing the label, so the worst
case in a narrow panel is the suffix disappearing, not a truncated name.

`s:matches()` (`:334`) gains the provider name in its haystack, so `/pi` in the
panel filters to Pi sessions — free, and the obvious thing to reach for once two
agents are listed together.

Nothing else in the panel changes: the glyphs stay status-only
(`claude#panel#icon()`, `:49`), and the syntax rules that key off them
(`:213-226`) are untouched.

---

## 7. Configuration

Two new options, defined in `plugin/claude.vim` in the house style, in a new
`" ── provider configuration ──"` block before the session-panel block:

```vim
" g:claude_provider — which CLI a new session runs by default: 'claude'
" (default) or 'pi'. :PiNew and the panel's N start a session on a named
" provider whatever this says.
if !exists('g:claude_provider')
  let g:claude_provider = 'claude'
endif

" g:claude_providers — per-provider overrides, merged over the built-in
" defaults. Keys: cmd, models, working_pat, waiting_pat, and for pi
" sessions_root / session_dir.
"   let g:claude_providers = {'pi': {'cmd': 'pi --thinking high'}}
if !exists('g:claude_providers')
  let g:claude_providers = {}
endif
```

Backward compatibility is a hard requirement, and it costs nothing because every
existing global becomes *the Claude provider's* setting:

| Existing option | After this change |
| --- | --- |
| `g:claude_cmd` (`plugin/claude.vim:21`) | the Claude provider's `cmd` |
| `g:claude_models` (`:26`) | the Claude provider's `models` |
| `g:claude_panel_working_pat` (`:71`) | the Claude provider's `working_pat` |
| `g:claude_panel_waiting_pat` (`:77`) | the Claude provider's `waiting_pat` |
| `g:claude_session_flags` (`:148`) | the Claude provider's id/name probe override |
| `g:claude_sessions_dir` (`session.vim:1089`) | the Claude provider's holder registry |
| `g:claude_session_prompt_name` (`:144`), all `claude_panel_*`, `claude_workspace_*`, `claude_difftree_*`, both stores | unchanged, provider-agnostic |

An unknown `g:claude_provider` warns once through `s:warn_once()`
(`session.vim:73`) and falls back to `'claude'` rather than failing a spawn.

Documentation, written in the same commit as the behaviour:

- `README.md` — a "Choosing an agent" section after "Session names" (`:294`),
  covering `g:claude_provider`, `:PiNew`, `<leader>pn`, and what `N` now asks.
- `doc/claude.txt` — the two options in CONFIGURATION (`:37`), `:PiNew` in
  COMMANDS (`:335`), `<leader>pn` in MAPPINGS (`:458`), and the provider
  question in the session-panel section (`:495`), with a `*claude-providers*`
  tag and a CONTENTS entry.

---

## 8. Test plan

`make test` runs `vim -u test/vimrc -c 'Vader! test/*.vader'`. The seams this
plan relies on already exist: `claude#session#_argv()` (`session.vim:1571`),
`_classify()` (`:1576`), `_holder_pid()` (`:1582`), `_inject()` (`:1588`),
`_reset()` (`:1562`), the `g:claude_cmd = 'sleep 30'` stub
(`test/session_registry.vader:10`) and `g:claude_sessions_dir`.

**Extend**

- `test/mappings.vader` — add `['\pn', ':PiNew<CR>']` to the loop at `:17-24`
  and `'PiNew'` to the command-existence loop at `:27-33`.
- `test/session_registry.vader` — keep the Claude argv assertions at `:212`,
  `:218-223`, `:251` exactly as they are (they are the stage-1 regression
  test); add Pi cases asserting `['pi', '--session-id', <id>]` for a *fresh*
  session, the identical vector for a *resumed* one, `--name` appended when the
  session is named, and that `--resume` never appears.
- `test/session_project_dir.vader` — unchanged for Claude; add a sibling block
  for `claude#provider#pi#session_dir()` asserting
  `/Users/me/e2e_extraction.v2` → `--Users-me-e2e_extraction.v2--` (dots and
  underscores **preserved**, the opposite of the Claude rule at `:8-19`).
- `test/session_label.vader` — add a Pi fixture: a `session` header line, a
  `message` entry with a user role, and a later `session_info`; assert the
  snippet comes from the message, the name from the `session_info`, and that a
  name typed in Vim (`named` = 1) still wins.
- `test/store.vader` — an entry without `provider` loads as `'claude'`; one with
  `provider: 'pi'` round-trips; the store version stays 1.
- `test/panel_keys.vader` — `n` and `N` stay bound to `<SID>new()` /
  `<SID>new_asking()`; `n` on a Pi row spawns with provider `'pi'` (via an
  injected record and a `sleep 30` stub).

**New**

- `test/provider_registry.vader` — `names()` is ordered with the default first;
  `get()` merges `g:claude_providers` over the module spec; an unknown
  `g:claude_provider` falls back to `'claude'` and warns once; `has()` reports a
  missing hook as absent rather than erroring.
- `test/provider_pi_paths.vader` — `session_dir()` for several awkward cwds
  (spaces, dots, a trailing slash, a Windows-style colon), and
  `transcript_path()` against a fixture tree containing
  `2026-09-05T13-15-20-249Z_<id>.jsonl`, including the "no match → ''" case.
- `test/provider_pi_sessions.vader` — `sessions([cwd])` over a fixture directory
  of three files: assert newest-first order, the
  `g:claude_panel_closed_limit` cap, a corrupt line being skipped rather than
  aborting the scan, and a file with no header yielding no record.
- `test/provider_classify.vader` — `_classify()` picks the record's provider's
  patterns; `to interrupt` marks a Pi session active; `g:claude_panel_working_pat`
  still overrides for Claude and does **not** leak into Pi.

**Done looks like**: `make test` green; with no new options set, `_argv()`,
the panel rows and the store contents are identical to the pre-change build;
`<leader>pn` starts a Pi session that the panel lists, labels, ends and resumes.

---

## 9. Commit sequence

1. **Extract the seam, Claude only.** Add `autoload/claude/provider.vim` and
   `autoload/claude/provider/claude.vim`; move argv, the flags probe, the path
   rule, the transcript scan, the holder registry, the refusal pattern and the
   two status patterns behind them. **Acceptance: every existing test passes
   with no edits to any test file.**
2. **`provider` on the record.** Field, persistence, `'claude'` default on read,
   `claude#provider#of()`. Extends `test/store.vader`.
3. **The Pi module.** `autoload/claude/provider/pi.vim` — spec, argv,
   `session_dir()`, `transcript_path()`, `sessions()`, `model_text()`,
   `completion()`. Adds `test/provider_pi_paths.vader`,
   `test/provider_pi_sessions.vader`; extends `test/session_label.vader`.
4. **`:PiNew` and `<leader>pn`.** Command, mapping, `claude#new()` a:2,
   `claude#session#new()` a:3. Extends `test/mappings.vader`,
   `test/session_registry.vader`.
5. **The panel.** `s:ask_provider()` on `N`, provider inheritance on `n`, the
   suffix and the filter. Extends `test/panel_keys.vader`.
6. **Configuration and docs.** `g:claude_provider`, `g:claude_providers`,
   README and `doc/claude.txt`. Adds `test/provider_registry.vader`.

Each commit leaves the plugin working, and commits 1-3 are invisible to a user.

---

## 10. Risks and open questions

**Risks**

- *The seam leaks.* The failure mode is a call site that still builds a Claude
  path by hand — `is_foreign_active()` and `purge()` are the two that do so
  today (`session.vim:1453`, `:1401`), and for Pi they would silently target a
  file that does not exist: no "foreign active" detection, and `D` deleting
  nothing. Commit 1 must move both, and `grep -n "\.jsonl" autoload/` should
  return only provider modules afterwards.
- *The scan window.* Pi's name lives in `session_info` entries appended over
  time; a 200-line head window catches `--name` and early renames but not a
  rename made deep into a long conversation. The row then shows the first
  message instead of the new name — degraded, not wrong. Revisit only if it
  bites.
- *Two live sessions on one id.* Pi has no holder registry, so
  `s:preflight_resume()` cannot warn before a second Vim resumes a session that
  is already open. What happens is whatever Pi does, on the terminal, in front
  of the user. Document it; do not paper over it.
- *Status patterns are chrome.* `to interrupt` is a footer string
  (`interactive-mode.js:1741`), not a contract. The idle-timer fallback
  (`session.vim:397`) keeps the panel sane if it changes; "Needs you" quietly
  stops working. The waiting pattern for Pi is the weakest guess in this
  document — see below.

**Open questions**

1. **Pi's waiting prompt.** The `waiting_pat` in §3.2 is Claude's numbered-choice
   pattern plus `(y/n)`; Pi's approval UI was not confirmed. Resolve by running
   a Pi session that triggers a tool approval and reading the bottom five rows
   (`s:term_tail()`, `session.vim:403`) — then set the pattern from what is
   actually on screen. Until then Pi sessions fall back to the idle timer and
   never join "Needs you". *Blocks commit 3's spec, not its code.*
2. **Does `--session-id` reopen across Vim runs?** `dist/main.js:341-348` says
   it matches by exact id within the project's session directory, which is what
   the plugin needs; confirm with one manual run (start a Pi session, quit Vim,
   resume it from the panel). *Blocks commit 3.*
3. **Does a fresh `pi --session-id <uuid>` write its file immediately?** If the
   header line is written at creation, `has_transcript()` (`:1440`) is true from
   the start and the resume path never differs; if it is written lazily, the
   behaviour still works (the same flag either way) but
   `claude#session#label()` has nothing to read until the first message —
   exactly as with Claude. Check the session directory right after spawn.
   *Affects nothing structurally; worth knowing.*
4. **Model list defaults.** `models` in §3.2 is a placeholder. Pi resolves
   patterns (`--model sonnet:high`, `provider/id`), and `/model <exact id>`
   switches directly while anything else opens its selector
   (`interactive-mode.js:3863-3884`). Decide whether the plugin ships a short
   default list, reads `defaultModel` from `~/.pi/agent/settings.json`, or ships
   none and requires `g:claude_providers.pi.models`. *Blocks commit 6's docs.*
5. **Should `:ClaudeResume` and `:ClaudeModel` stay Claude-named?** They now act
   on whichever session the picker resolves, Pi included. This document keeps
   the names (renaming is out of scope, `doc/design/multi-agent-support.md`
   §4.6) but their help text needs to stop saying "Claude". *Blocks commit 6's
   docs only.*
