# Design: workspaces

Status: implemented — superseded by `doc/design/session-workspaces.md`, which
makes the workspace the unit the panel is built from and gives the root folder
a record of its own.
Target: `claude.vim`
Last updated: 2026-09-08

---

## 1. Summary and motivation

A session is spawned in `getcwd()` and merely *records* where it landed:
`s:derive_group()` (`autoload/claude/session.vim:108`) asks git for the
project, worktree and branch so the panel can fold sessions into
Project > Worktree > Branch. Nothing ever *creates* a worktree.

The consequence is that running two sessions on two branches means switching
branches by hand, and both sessions then fight over one checkout — one of them
is always looking at the other's files.

A **workspace** inverts that: the session picks a branch up front and is given
its own `git worktree` to run in. The panel grouping already in place then
means something, because the worktree level is no longer always "the directory
Vim happens to be in".

Three things follow, and this design covers all three:

1. **Creation.** The new-session prompt asks for a branch before it asks for a
   name, and creates a worktree for it.
2. **Hiding.** Leaving both prompts blank is now a real answer — the session
   goes unnamed and Claude names the conversation itself — so the panel needs
   NERDTree's "show the hidden ones" key.
3. **Selection.** `<leader>cw` picks the workspace to work in and re-roots
   NERDTree onto it, so the file tree shows one checkout at a time.

---

## 2. Goals / Non-goals

### Goals

- One session, one checkout, without leaving Vim.
- Reuse the machinery that exists: the JSON store, the branch completion, the
  session picker idiom, the sidebar column.
- Never let a git failure take the session down with it. A workspace that
  cannot be created leaves a session running in the current directory.
- Old stores keep working. A record written before this change has neither a
  `workspace` nor a `named` field and must behave as "no workspace, named".

### Non-goals

- **Removing worktrees.** `git worktree remove` is a destructive operation on
  a directory holding real work; the panel is not the place for it. Stale
  records are pruned when the directory is already gone, nothing more.
- **Managing branches.** No merging, rebasing, pushing or deleting.
- **Per-tab workspaces.** The selected workspace is one per Vim, like the diff
  tree's session-wide base.
- **Persisting the selection.** It is a property of this Vim session.

---

## 3. The prompt flow

`claude#session#new()` asks two questions, branch first:

```
Branch (blank for no workspace): <tab-completes local and remote branches>
Session name:
```

| Branch | Name | Result |
|--------|------|--------|
| given | given | Workspace `<name>` on `<branch>`; session named `<name>` |
| given | blank | Workspace named after the branch, uniquified; session takes that name |
| blank | given | No workspace; runs in the selected workspace, or `getcwd()` |
| blank | blank | The same, and the session is left **unnamed** |

Only CTRL-C cancels, at either prompt; that is the existing contract of
`s:prompt_name()` and the branch prompt matches it. An empty answer is taken
at face value, which is what makes row 4 reachable at all.

Two behaviours are deliberately preserved:

- `claude#session#new('a name')` — what `:ClaudeNew name` and the panel's
  scripted callers use — skips both prompts, as before.
- `g:claude_session_prompt_name = 0` skips both prompts *and* the workspace,
  and still gives the timestamp name it always did. That setting means "do not
  ask me things", not "hide my sessions".

Branch completion is `claude#difftree#complete_branch()`, unchanged, so the
same local and remote branches are offered here as by `:ClaudeDiffBase`. A
name that matches nothing is still accepted, and becomes a new branch.

---

## 4. Data model

### 4.1 The workspace record

| Field | Source |
|-------|--------|
| `id` | Key within the repository — the name, which is unique per project |
| `name` | Display name; the directory's last segment |
| `branch` | The local branch checked out in the worktree |
| `path` | Absolute worktree directory |
| `project` | Main repository root, shared by every worktree of one repo |
| `created` | Unix time |

### 4.2 The store

`data/workspaces.json`, or `g:claude_workspace_store`, through the same
`claude#store#load_at()` / `save_at()` pair as the other two stores — atomic
write, `.bak` on corruption, read-only on a future schema. The payload is
keyed by repository root first, exactly as the diff bases are, so the same
workspace name in two repositories stays separate:

```json
{
  "version": 1,
  "workspaces": {
    "/home/me/src/claude.vim": {
      "sidebar-column": {
        "id": "sidebar-column",
        "name": "sidebar-column",
        "branch": "sidebar-column",
        "path": "/home/me/src/claude.vim-sidebar-column",
        "project": "/home/me/src/claude.vim",
        "created": 1757308800
      }
    }
  }
}
```

### 4.3 Two new session fields

| Field | Meaning |
|-------|---------|
| `workspace` | Workspace id the session runs in, or `''` |
| `named` | 1 when the user typed the name; 0 when they left the prompt blank |

Both are persisted. `named` is a stored flag rather than a test on the name
text, because a name by itself is not evidence: a session Claude named itself
has one too.

`s:was_named()` reads a stored entry in three steps:

1. A name of the form `claude <date> <time>` is never a name. That is what
   `s:default_name()` minted when the prompt was skipped or left blank, so
   nobody chose it — this holds even when the record carries `named = 1`,
   which is how those rows were written.
2. Otherwise the flag decides, when it is there.
3. Otherwise — a record written before the flag existed — having a name at all
   is the answer.

`g:claude_session_prompt_name = 0` no longer invents a name either: it now
skips both prompts and leaves the session nameless, which is the same answer
as leaving the prompts blank. `s:default_name()` is gone with it.

---

## 5. Naming and placement

`claude#workspace#unique_name()` slugs the base — `/`, `\`, spaces and `:`
become `-`, so `feature/deep` is one directory and not a tree — and then
appends `-1`, `-2`, … until nothing in this repository holds the name:

```
feature-branch  ->  feature-branch  ->  feature-branch-1  ->  feature-branch-2
```

The directory follows the name:

| `g:claude_workspace_dir` | Directory |
|--------------------------|-----------|
| `''` (default) | `<repo-parent>/<repo-name>-<workspace name>` |
| set | `<g:claude_workspace_dir>/<workspace name>` |

The default keeps every worktree of one project in one parent directory,
beside the checkout they came from, which is how `git worktree` is usually
used by hand. A directory already in the way is refused rather than adopted:
whatever is in it was not put there by this plugin.

---

## 6. Git plumbing

Everything runs against the main repository root, derived from
`--git-common-dir` the same way `s:derive_group()` derives it, so a session
started *inside* a workspace still creates its next workspace beside the main
checkout rather than beside itself.

```sh
git -C <root> worktree list --porcelain          # is the branch taken?
git -C <root> show-ref --verify refs/heads/<b>   # does it exist locally?
git -C <root> for-each-ref refs/remotes          # does a remote have it?
```

then one of:

```sh
git -C <root> worktree add <dir> <branch>                    # existing local
git -C <root> worktree add --track -b <b> <dir> <remote>/<b> # remote-only
git -C <root> worktree add -b <branch> <dir>                 # new, off HEAD
```

`origin/foo` typed in full resolves to the local `foo` when one exists, rather
than to a second branch: the remote-tracking ref and the branch following it
are the same line of work. The name is resolved before the checked-out test
below, so both forms of the name reach the same answer.

A branch can be checked out in one worktree only, so the porcelain list is
consulted before anything is created. A branch that already has a checkout is
not an error, though: it is a request to work there, and `s:existing()`
answers with

| The checkout | The answer |
|--------------|------------|
| A registered workspace | That record, unchanged — the session joins it |
| A worktree made outside the plugin | A new record adopting it, so it is listed and selectable from now on |
| The main checkout | A record with an empty `id`: somewhere to run, never persisted, and the session belongs to no workspace |

Without this the session silently ran wherever Vim happened to be — asking
for a branch that already had a worktree put the session in the main checkout
and grouped it under the *wrong branch*, which is the opposite of what was
asked for.

`worktree add` is the only command whose stderr is kept: everything else is
run for its exit status, and a failure means "no", not "explain".

---

## 7. Hiding the unnamed

`claude#session#list()` drops records with `named == 0` unless
`claude#session#show_hidden()`. `tree()` is built from `list()`, so a branch
whose sessions are all hidden produces no node at all — no empty groups to
skip over.

`live()` deliberately does **not** filter: an unnamed session is still running
and still counts in the panel header and in the pickers. Hiding is a listing
decision, not a lifecycle one.

`I` in the panel flips the state, as it flips dotfiles in NERDTree; lowercase
`i` keeps splitting. A revealed session has no name to show, so
`claude#session#label()` falls back to `(unnamed <first 8 of id>)`. Renaming
one sets `named = 1` — giving it a name is exactly what un-hides it.

---

### 7.1 Finding them again after a restart

Both halves of `claude#session#refresh()` used to be scoped to `getcwd()`,
which loses every workspace session the moment Vim is opened in the main
checkout — which is the normal way to open it:

- **The store.** An entry was adopted only when `cwd` matched exactly. It now
  matches on the recorded `project` as well, which every worktree of one
  repository shares. An entry with no project recorded — written before the
  field existed, or made outside a repository — still falls back to the
  directory, since that is all it has.
- **The transcripts.** Claude files a conversation under the directory the
  session ran in, so a workspace session's transcripts live under its own
  worktree. `s:project_dirs()` now yields Vim's directory plus every
  workspace's, and the `g:claude_panel_closed_limit` cap applies across the
  project rather than per directory.

`s:known_transcripts()` had the mirror-image bug: it read `getcwd()` while
`s:adopt_id()` later looked in the session's own directory, so on a CLI
without `--session-id` a pre-existing transcript in the worktree could be
mistaken for the new one. It now takes the spawn directory as an argument.

---

## 8. Selecting a workspace

`<leader>cw` / `:ClaudeWorkspaces` lists the main checkout plus every
workspace, through the popup-or-`inputlist()` pair the session picker already
uses (`s:use_popup()`, `g:claude_no_popup`). Choosing one:

1. sets it as the current workspace, and
2. re-roots NERDTree onto its directory with `:NERDTree <dir>`, then calls
   `claude#sidebar#stack()` so the column is put back together and the cursor
   returns where it was.

The current workspace is where a branch-less session is spawned. Without
NERDTree the selection still takes effect — it is the sidebar that is
optional, not the workspace.

---

## 9. Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `g:claude_workspace_dir` | `''` | Parent for worktrees; empty means beside the repo |
| `g:claude_workspace_store` | `''` | Store path; empty means `data/workspaces.json` |

Shared: `g:claude_session_prompt_name` (§3), `g:claude_no_popup` (§8).

---

## 10. API

### New: `autoload/claude/workspace.vim`

| Function | Purpose |
|----------|---------|
| `claude#workspace#project_root()` | Main repository root, memoised per cwd |
| `claude#workspace#list()` | Workspaces of this repository, pruned, newest first |
| `claude#workspace#get(id)` / `for_session(id)` | Lookups |
| `claude#workspace#unique_name(base)` | §5 slug and suffix |
| `claude#workspace#create(branch, name)` | §6; `{}` on every failure |
| `claude#workspace#current()` / `set_current(id)` / `cwd()` | The selection |
| `claude#workspace#pick()` / `select(id)` | §8 |
| `claude#workspace#_reset()` | Test seam |

### Changed

| Function | Change |
|----------|--------|
| `claude#session#new()` | §3 prompts, workspace creation, spawn directory |
| `claude#session#resume()` | Respawns in the workspace, or warns and uses `cwd` |
| `claude#session#list()` | §7 filter |
| `claude#session#refresh()` | Scoped to the project, not to `getcwd()` (§7.1) |
| `s:known_transcripts()` | Takes the directory the session will spawn in |
| `claude#session#rename()` | Sets `named` |
| `claude#store#workspace_path()` | New, beside `path()` and `difftree_path()` |
| `claude#sidebar#nerdtree_available()` | Was script-local; §8 needs it |
| `s:make_record()`, `s:persist()`, `s:term_start()` | Two fields, and a cwd |

### Commands and mappings

| | |
|---|---|
| `:ClaudeWorkspaces` | `claude#workspace#pick()` |
| `<leader>cw` | `:ClaudeWorkspaces` |
| `I` (panel) | Show or hide unnamed sessions |

---

## 11. Edge cases

| Case | Behaviour |
|------|-----------|
| Not in a repository | Branch prompt still appears; creation warns and the session runs in `getcwd()` |
| Bare repository | Same: `--git-common-dir` strips nothing, so there is no project root |
| Branch checked out elsewhere | The session runs in that checkout instead (§6) |
| Directory already exists | Refused; nothing is adopted (§5) |
| Ambiguous remote branch | Not tracked — branched off HEAD instead of guessing a remote |
| Worktree deleted behind our back | Pruned from the list on the next read; a session resuming into it warns once and falls back to `cwd` |
| Vim restarted in the main checkout | Workspace sessions come back: the store is searched by project and the transcripts by worktree (§7.1) |
| Store not writable | The workspace still exists on disk; only the record is lost, as with session names |
| Vim without `term_start()`'s `cwd` | The spawn window is `lcd`-ed instead |

---

## 12. Test plan

Fixture repositories are built in a temp directory, as
`test/session_group.vader` does, so nothing depends on this repository's state.

| File | Covers |
|------|--------|
| `test/workspace_create.vader` | Existing branch, new branch off HEAD, the three §6 answers for a branch that already has a checkout, blank branch, explicit name, `g:claude_workspace_dir`, a directory in the way, slashes in a branch name, remote-only branches (bare clone as the remote) in both spellings, listing, pruning, the selection |
| `test/workspace_name.vader` | Suffixing to `-1`/`-2`, slugging, the branch fallback, names being per repository |
| `test/workspace_store.vader` | Path resolution, round trip, per-root keying, corruption, records missing the new fields, pruning persisted, no repository |
| `test/session_hidden.vader` | The `named` filter, the toggle, `live()` still counting hidden sessions, empty branch groups, labels, rename un-hiding, old store entries, and the three steps of `s:was_named()` — including a name that merely starts like a timestamp |
| `test/session_workspace.vader` | End to end, with the prompts answered by `feedkeys()`: each row of the §3 table; the job's own directory, read back with `/bin/pwd`; the suffixed second workspace; the panel grouping; resume; a branch already checked out; §7.1 — surviving a restart, from the store and from a fabricated transcript, and not adopting another repository's sessions |
| `test/panel_keys.vader` | `I` reveals and re-hides; lowercase `i` still splits; the help block |

---

## 13. Future work

- A `d` verb on a workspace in the picker, running `git worktree remove` with
  the same two-step confirmation `D` uses for a transcript.
- Showing the workspace in the panel row when it differs from the branch name.
- Creating the workspace from a chosen base rather than always from HEAD.
