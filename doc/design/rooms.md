# Design: rooms

Status: superseded by doc/design/projects.md (implemented; §14 lists where the build departed from this text)
Target: `claude.vim`
Last updated: 2026-11-05

Supersedes `doc/design/session-workspaces.md` and, through it,
`doc/design/workspaces.md`. A room *is* a workspace — a git worktree a session
belongs to — reshaped into a two-level hierarchy, moved inside the project, and
given a base to diff against. The word "workspace" is retired.

---

## 1. Summary and motivation

A workspace today is a flat, optional git worktree. Three things are missing.

**Nothing says how two lines of work relate.** A workspace is cut from `HEAD`
(`s:add_args()`, `autoload/claude/workspace.vim:299`), whatever `HEAD` happened
to be, and records only the branch it holds. When an agent's experiment is
split off a feature that is itself in progress, the plugin has no idea the one
came from the other, so the diff tree shows both against `main`
(`claude#difftree#base_for()`, `difftree.vim:96`) and the experiment's diff is
buried under the feature's.

**Workspaces live outside the project.** `s:dir_for()` (`workspace.vim:258`)
puts each one beside the repository as `<repo>-<name>`. A project with five
agents in flight is six sibling directories, and nothing ties them to the
project except a naming convention.

**Belonging is optional.** A blank branch answer (`s:prompt_branch()`,
`session.vim:832`) runs the session wherever Vim is, so "which line of work is
this session part of" has no answer for most sessions.

Rooms fix all three:

- A **room** is a worktree on its own branch, cut from the *latest* default
  branch (fetched), or from a branch the user names.
- A **sub-room** is a worktree on its own branch, cut from its room's branch.
  It is how a room's work is split up between agents.
- Both live under `<project>/.vim-workspace/`.
- Every session is in a room, a sub-room, or the project's root checkout.
- A room diffs against what it was cut from; a sub-room diffs against its room.

---

## 2. Goals / Non-goals

### Goals

- One question decides where a session lives, and it always has an answer.
- The panel, the status view and the diff tree all show the same hierarchy:
  project > room > sub-room.
- A sub-room's diff is the sub-room's work only.
- Existing workspaces and the sessions that ran in them keep working, with no
  directory moved.

### Non-goals

- **Merging or pushing.** Work flows sub-room → room → main, but every step is
  the user's `git merge`. The plugin never moves a branch it did not create and
  never pushes. A "finish room" verb is future work (§12).
- **Deeper nesting.** Sub-rooms have no sub-rooms. Two levels already cost four
  columns of a 35-column sidebar (§3); a third would cost six more.
- **Multi-user collaboration.** "Collaborative" here means several agent
  sessions working side by side on one machine. Nothing is shared over a
  network.
- **Detached rooms.** Each room is on a branch of its own, for the reasons in
  `session-workspaces.md` §4.3: commits on no ref are one `rm -rf` from lost.
- **Removing branches.** Removing a room removes its worktree, not its branch.

---

## 3. Concepts

| Kind | Branch | Cut from | Diffs against | Directory |
|------|--------|----------|---------------|-----------|
| Root | Whatever the main checkout is on | — | The default base, as today | The project root |
| Room | `room/<room>` | `<remote>/<default>` after a fetch, or a named branch | What it was cut from | `.vim-workspace/<room>/<project>/` |
| Sub-room | `room/<room>--<sub>` | The room's branch tip | The room's branch | `.vim-workspace/<room>/<sub>/<project>/` |

### 3.1 Branch names

`room/<room>/<sub>` is the obvious scheme and git rejects it. A ref cannot also
be a directory of refs:

```
$ git branch room/a
$ git branch room/a/b
fatal: cannot lock ref 'refs/heads/room/a/b': 'refs/heads/room/a' exists;
cannot create 'refs/heads/room/a/b'
$ git branch room/a--b          # fine
```

So a sub-room's branch is `room/<room>--<sub>`. To keep that unambiguous,
`--` is not allowed in room or sub-room names: the slug function collapses any
run of dashes to one. Otherwise a room named `a--b` and the sub-room `b` of room
`a` would both want `room/a--b`.

The branch is stored on the record (§7) and never re-derived from the name, so
renaming the scheme later, or a branch renamed by hand, does not orphan a room.

### 3.2 "Latest main"

Creating a room runs `git fetch <remote> <default>` and cuts from
`<remote>/<default>`, not from the local branch. `<default>` comes from
`s:detect_base()` (`difftree.vim:78`), so a repository whose trunk is `master`
or `trunk` works unchanged. `<remote>` is `origin`, or the only remote when
there is exactly one.

Two findings, both verified in a scratch repository:

**The branch must be created `--no-track`.** `git worktree add -b room/x <dir>
origin/main` sets `room/x`'s upstream to `main`
(`branch.room/x.merge = refs/heads/main`), because `branch.autoSetupMerge`
defaults to tracking when the start point is a remote branch. A later
`git pull` in the room would then pull `main` into it. `--no-track` leaves the
room with no upstream until the user pushes it.

**The base must be the remote ref, not the local branch.** After the fetch,
local `main` is often behind `origin/main`. A room cut from `origin/main` and
diffed against local `main` shows every commit that landed upstream since the
user last pulled:

```
$ git diff --name-only main...HEAD          # u is someone else's commit
u
w
$ git diff --name-only origin/main...HEAD
w
```

So the room's `base` is recorded as `origin/main`, the ref it was actually cut
from.

When the fetch fails (no remote, offline, authentication) the room is cut from
`<remote>/<default>` if that ref exists, else from local `<default>`, with one
warning saying which. The fetch runs with `GIT_TERMINAL_PROMPT=0`, so a missing
credential fails rather than hanging Vim on a prompt nobody can see. Fetching
can be turned off with `g:claude_room_fetch = 0`.

When the user names a branch, nothing is fetched. The room is cut from that
branch as it is, and `base` is that branch's name.

### 3.3 Sub-rooms

A sub-room is cut from its room's branch **tip**: what is committed. Uncommitted
work in the room is not carried over, because a worktree is a checkout of a
commit. The prompt says so when the room is dirty (§5.3).

A sub-room's `base` is its room's branch. When the room moves on, the sub-room's
diff (`room/r...room/r--s`, three dots, against the merge-base) still shows the
sub-room's own work and nothing of the room's newer commits. That is the point
of a three-dot diff, and the existing diff tree already uses one.

### 3.4 The root checkout

Kept exactly as `session-workspaces.md` §6 defines it: the reserved id `root`,
materialised and never persisted, its branch read live. It has no sub-rooms.
A "sub-room of root" would be cut from whatever branch the main checkout
happens to be on, and its base would move every time the user switches
branches. A room covers the same need with a stable base.

---

## 4. On disk

### 4.1 Layout

```
project-root/
└── .vim-workspace/
    ├── room1/
    │   ├── project-root/              ← room1's worktree (room/room1)
    │   ├── subroom1/
    │   │   └── project-root/          ← room/room1--subroom1
    │   └── subroom2/
    │       └── project-root/
    └── room2/
        └── project-root/
```

The worktree is a `<project-basename>/` directory *inside* the room's directory,
not the room directory itself. That keeps a room's worktree and its sub-rooms
side by side, so no worktree is nested inside another worktree's checkout. If the
room directory were the worktree, `subroom1/` would be an untracked directory
inside room1's checkout, and room1's `git status` would list it.

Naming the inner directory after the project keeps Claude Code's per-directory
transcript folders and the terminal title readable: a session in a room shows
`project-root`, not `room1`.

The location is `g:claude_room_dir`, default `.vim-workspace`. A relative value
is relative to the project root. An absolute value puts every room in that
directory, under `<abs>/<project-basename>/<room>/…`, for the tooling problems
in §9.

### 4.2 Keeping it out of the project

`/.vim-workspace/` is appended to `.git/info/exclude` the first time a room is
created in a repository. That file is local and never committed, so the
project's `.gitignore` is not touched. The directory is not appended when it is
already present, or when `g:claude_room_dir` is absolute.

Verified in a scratch repository with two nested worktrees:

| Tool | Without the exclude | With it |
|------|---------------------|---------|
| `git status` in the main checkout | `?? .vim-workspace/` | Clean |
| `git status` in the room | Clean | Clean |
| `rg --files` in the main checkout | — | `.vim-workspace` not listed (ripgrep reads `info/exclude`) |
| `git clean -fdx` | — | `Would skip repository .vim-workspace/…` |
| `git clean -ffdx` | — | **`Would remove .vim-workspace/`** |
| `git -C .vim-workspace/r1/s1/proj rev-parse --show-toplevel` | — | The sub-room's worktree |
| `git -C .vim-workspace/r1 rev-parse --show-toplevel` | — | The main checkout |

The `-ffdx` row is the cost of putting worktrees inside the project. §9 says how
the plugin handles it.

### 4.3 The room store

`data/rooms.json` (`g:claude_room_store`), through the existing
`claude#store#load_at()` / `save_at()`. It is keyed by project root, then by
room id, exactly like `workspaces.json`:

```json
{
  "version": 1,
  "rooms": {
    "/home/me/src/claude.vim": {
      "panel": {
        "id": "panel", "name": "panel", "parent": "",
        "branch": "room/panel", "base": "origin/main",
        "path": "/home/me/src/claude.vim/.vim-workspace/panel/claude.vim",
        "project": "/home/me/src/claude.vim",
        "created": 1793000000, "legacy": 0
      },
      "panel/icons": {
        "id": "panel/icons", "name": "icons", "parent": "panel",
        "branch": "room/panel--icons", "base": "room/panel",
        "path": "/home/me/src/claude.vim/.vim-workspace/panel/icons/claude.vim",
        "project": "/home/me/src/claude.vim",
        "created": 1793000500, "legacy": 0
      }
    }
  }
}
```

The room store is the only state. Nothing is written inside `.vim-workspace/`
besides the worktrees, so deleting a room directory by hand is the same event as
deleting a workspace directory by hand today (§9).

---

## 5. Starting a session

### 5.1 The questions

| # | Question | Shape | When |
|---|----------|-------|-------|
| 1 | Room | Picker | Always, unless the caller already knows the room |
| 1a | Room name | `input()` | New room |
| 1b | Base branch | `input()`, branch completion, blank = latest default | New room |
| 1c | Parent room | Picker of rooms | New sub-room, when there is no room under the cursor or selected |
| 1d | Sub-room name | `input()` | New sub-room |
| 2 | Session name | `input()`, unchanged (`s:prompt_name()`, `session.vim:849`) | Always |

The picker replaces `s:prompt_branch()`. It uses the same popup-or-`inputlist()`
split as `claude#workspace#pick()` (`workspace.vim:505`):

```
 Room for the new session
 * claude.vim (root) — sidebar-column
   panel — room/panel
     icons
     layout
   difftree — feature/git-diff-tree      (legacy)
   + New room…
   + New sub-room…
```

- The current room (`<leader>cw`) is marked `*` and is the popup's initial
  selection, so <CR> alone repeats the last answer. That is the cheap path the
  blank-branch answer used to be.
- Sub-rooms are indented under their room, labelled by name only, because their
  branch is always `room/<room>--<name>`.
- A room's branch is elided when it is `room/<name>`, for the same reason.

### 5.2 Who skips which question

| Entry point | Asks |
|-------------|------|
| `:ClaudeNew`, `<leader>cc` | 1, then 2 |
| Panel `n` on a room, sub-room or session row | 2 only; the room is taken from the row |
| Panel `n` on a project row or the header | 1, then 2 |
| Panel `N` (ask provider) | The provider, then as `n` |
| `:ClaudeNew <name>` | Nothing; the current room |
| `g:claude_session_prompt_name = 0` | Nothing; the current room, unnamed |

"The current room" is the `<leader>cw` selection, else `root`. A session
therefore always has a room, even when no question was asked.

### 5.3 Ordering and cancelling

Nothing is created until every answer is in. The worktree is added after the
session-name prompt, as `session-workspaces.md` §5 already requires, so CTRL-C at
any prompt leaves nothing behind. The fetch runs at the same point: after the
last answer, before `git worktree add`.

A new sub-room of a room with uncommitted changes gets one extra line before the
sub-room name prompt:
`room/panel has uncommitted changes; the sub-room starts from its last commit`.
It is a warning, not a question.

### 5.4 Session names

As today. An unnamed session in a *new* room is named after the room
(`spawn()`, `session.vim:1003`), because typing a room name is the same signal
that typing a branch name was. An unnamed session in an *existing* room stays
unnamed and is labelled from its first message.

---

## 6. The session panel

### 6.1 Place view (`s:build_tree()`, `panel.vim:475`)

```
Claude Sessions               (6)

▾ claude.vim
  ▾ claude.vim (root) — sidebar-column
    ● panel design
  ▾ panel
    ● prototype
    ▾ icons
      ● icon set
    ▾ layout
      ○ layout pass
  ▸ difftree — feature/git-diff-tree
▾ dotfiles
  ▾ dotfiles (root) — main
    ○ zsh cleanup
```

| Indent | Row |
|--------|-----|
| 0 | Project |
| 2 | Root, or a room |
| 4 | A room's session, or a sub-room |
| 6 | A sub-room's session |

A room's own sessions come before its sub-rooms, so a room's direct work is
never pushed below the fold of a long sub-room list.

Every room and sub-room row is drawn, whether or not it has sessions, so the
panel doubles as the room list, as `session-workspaces.md` §3.1 intended for
workspaces.

| Row | Label |
|-----|-------|
| Root | `<basename> (root) — <branch>`, branch read live |
| Room | `<name>`, plus ` — <branch>` when the branch is not `room/<name>` |
| Sub-room | `<name>`; the branch is never shown |
| Gone | `<name> — (missing)`, dimmed |

Fold keys are ids, not paths, so they survive a restart and a moved
`g:claude_room_dir`:

| Level | Key |
|-------|-----|
| Project | `p:<project root>` |
| Room or root | `r:<project root>\|<room id>` |
| Sub-room | `r:<project root>\|<room>/<sub>` |

### 6.2 Status view (`s:build_states()`, `panel.vim:421`)

The status groups and everything about them stay: their order, the `Done` cap,
buried rows, `I`, the filter. Inside each group, sessions are grouped by room,
and a sub-room's sessions sit with its room, tagged:

```
Claude Sessions               (5)

▾ Needs you (2)
  ▾ panel
    ● prototype
    ● icon set [icons]
▾ Working (2)
  ▾ panel
    ● layout pass [layout]
  ▾ claude.vim (root)
    ● panel design
▾ Done (1)
  ▾ dotfiles (root)
    ○ zsh cleanup
```

- No sub-room level here. The status view answers "what needs me", and a third
  indent spent on that answer is a column of session name lost.
- Room rows inside a group are ordered by their most urgent session. Sessions
  keep the group's existing order (`s:cmp_records()`, `session.vim:636`), and a
  room appears where its first session would have been.
- When sessions from more than one project are listed, the room row is prefixed
  with the project: `claude.vim › panel`. This is the same "only when mixed" rule
  as `s:mixed_providers()` (`panel.vim:326`).
- Room rows fold, with key `<group key>|r:<project>|<room id>`, so folding
  `panel` under `Needs you` does not fold it under `Working`.
- The `[icons]` tag is never what truncation eats. `s:fit()` shortens the label
  before the tag, as it already does before the age suffix.
- A session whose room is `''`, outside any repository, groups under
  `(no project)`, as today.

### 6.3 Highlights

The public groups (`doc/claude.txt`, `README.md`) are kept and re-pointed, as
`session-workspaces.md` §3.3 did:

| Group | Becomes |
|-------|---------|
| `ClaudeSessionProject` | Unchanged |
| `ClaudeSessionWorktree` | Room and sub-room names |
| `ClaudeSessionBranch` | The ` — <branch>` suffix |
| `ClaudeSessionRoomTag` *(new)* | The `[sub-room]` tag in the status view; links to `ClaudeSessionBranch` |

`s:setup_syntax()` (`panel.vim:201`) matches by indent. The room patterns are
`^  ` and `^    ` with a fold marker, which tells them apart from session rows at
the same indent, because session rows start with a status icon instead.

---

## 7. Data model

### 7.1 The room record

| Field | Meaning |
|-------|---------|
| `id` | `<room>` or `<room>/<sub>`; unique per project. `root` is reserved |
| `name` | Display name: the last segment of the id |
| `parent` | `''` for a room, the room's id for a sub-room |
| `branch` | Branch checked out in the worktree |
| `base` | What the diff tree compares against (§8) |
| `path` | Absolute worktree directory |
| `project` | Main repository root |
| `created` | Unix time |
| `legacy` | 1 for a migrated workspace whose directory is outside `.vim-workspace` |

### 7.2 The session record

`workspace` is renamed to `room`, holding a room id, `root`, or `''` outside a
repository. On load, `get(e, 'room', get(e, 'workspace', ''))`, so an old record
needs no rewrite. On save, only `room` is written. Everything else is unchanged:
`project`, `worktree` and `branch` stay, for the same reasons given in
`session-workspaces.md` §7.2.

---

## 8. The diff tree

### 8.1 Shape

```
Git Changes

▾ claude.vim
  ▾ sidebar-column                        ← root checkout, as today
    ▸ autoload/
  ▾ panel/
    ▾ claude.vim/                         ← room/panel vs origin/main
      ▸ autoload/
    ▾ icons/
      ▾ claude.vim/                       ← room/panel--icons vs room/panel
        ▸ autoload/
    ▸ layout/
  ▸ feature/old-thing (no worktree)       ← session branches, as today
```

| Indent | Row |
|--------|-----|
| 0 | Project |
| 2 | Root branch, room, or a non-room branch |
| 4 | A room's worktree folder, or a sub-room |
| 6 | A room's directories, or a sub-room's worktree folder |
| 8+ | A sub-room's directories |

The worktree folder row is the `<project-basename>/` directory from §4.1. It is
shown because it is where the files actually are, and it is the level the
user's mental model of the layout has. It costs two columns, which is the main
open question (§12).

A room row is drawn when it or any of its sub-rooms has changes. Its folder row
is drawn only when the room itself has changes. Rooms come after the root branch
and before the non-room branches. Branches that belong to a room are no longer
listed a second time as plain branch rows.

### 8.2 Bases

`claude#difftree#base_for()` stays the single place a base is decided. It gains
one step:

```
explicit :ClaudeDiffBase override    (unchanged, wins)
  → the room's `base`                (new: claude#room#base_of_branch())
  → the default base                 (unchanged)
```

This is a lookup, not a write. Creating a room does not call
`claude#difftree#set_branch_base()`, so the diff base store keeps only what the
user asked for, and clearing an override (`:ClaudeDiffBase` with no argument)
falls back to the room's base, not to `main`.

`claude#difftree#has_override()` (`difftree.vim:102`) stays true only for
explicit overrides. A sub-room would otherwise show `[room/panel]` on every row,
repeating what the nesting already says.

### 8.3 Removing (`d` / `D`)

`s:remove_worktree()` (`difftree.vim:1162`) works on room and sub-room rows, and
the panel gets the same keys.

- A room with sub-rooms is **refused**: `panel has 2 sub-rooms; remove them
  first`. Removing a room is never a cascade, so one keypress never discards
  several agents' uncommitted work.
- `d` is `git worktree remove`, which refuses a dirty worktree. `D` is
  `--force`, behind the existing confirmation.
- The branch is never deleted. The record is dropped, and the room directory is
  removed when it is empty afterwards, so `.vim-workspace/` does not fill with
  empty folders.
- Sessions that were in a removed room show under a `(missing)` row and resume in
  their recorded `cwd` with the existing warning (`s:spawn_dir()`,
  `session.vim:809`).

---

## 9. Edge cases

| Case | Behaviour |
|------|-----------|
| Not inside a git repository | The picker offers only "here". The session runs in `getcwd()` with `room: ''` and groups under `(no project)` |
| Bare repository | Same |
| No remote, or the fetch fails | Cut from `<remote>/<default>` if it exists, else local `<default>`; one warning names the ref used, and `base` records it (§3.2) |
| No default branch detected | Creating a room asks for the base branch instead of offering "blank = latest" |
| Named base branch does not exist | Refused at the prompt, with completion offered again; never silently branched off `HEAD` as workspaces did |
| Room name collides | Uniquified with `-1`, `-2`, as `claude#workspace#unique_name()` does |
| `room/<name>` branch already exists, unused | Refused: the room would silently take over earlier work. The user picks another name or adopts the branch as a named base |
| `room/<name>` branch already checked out elsewhere | Adopted as a room, as `s:existing()` (`workspace.vim:339`) does today |
| Room directory deleted by hand | Pruned from the store on the next list, as workspaces are. Its sub-rooms are pruned too if their directories are gone, and kept, under a `(missing)` room row, if they are not |
| Parent branch moves after a sub-room is cut | Nothing to do: the three-dot diff is against the merge-base (§3.3) |
| Parent branch renamed or deleted | The sub-room's `base` no longer resolves. The diff tree shows the sub-room with `(base gone)` and falls back to the default base |
| `.vim-workspace` in NERDTree | Hidden unless `NERDTreeShowHidden` is set. The docs give the `NERDTreeIgnore` line; the plugin does not edit the user's config |
| ripgrep, fd, fzf, Claude Code's own search | Excluded through `.git/info/exclude` (§4.2) |
| Tools that do not read git ignores (`:vimgrep **`, jest, pytest, tsc) | They see every room's copy of the project. Documented, with `g:claude_room_dir` set to an absolute path as the fix |
| `git clean -ffdx` in the main checkout | Deletes every room's worktree, including uncommitted work (§4.2). The plugin cannot intercept it; `doc/claude.txt` says so in a warning box, and the room list prunes what it removed |
| `.git/info/exclude` not writable | One warning; the room is still created |
| Two Vim instances create a room of the same name | The second `git worktree add` fails on the existing directory and is reported, as for workspaces |
| Claude Code transcripts | Filed by the session's `cwd`, so `s:sweep_cwds()` (`session.vim:279`) walks every room and sub-room path |

---

## 10. Migration

| What exists | What happens |
|-------------|--------------|
| `data/workspaces.json`, no `rooms.json` | On first load each workspace becomes a top-level room: same id, name, branch, path; `parent: ''`, `base: ''` (meaning the default), `legacy: 1`. `rooms.json` is written; `workspaces.json` is left untouched, so reverting the plugin loses nothing |
| A legacy room's directory | Not moved. It is listed and works like any other room, can have sub-rooms (which go under `.vim-workspace/<room>/`), and is marked `(legacy)` in the picker only |
| Session record with `workspace: "<id>"` | Read as `room: "<id>"` |
| Session record with `workspace: ""` in the project root | Read as `room: "root"` |
| Session record with `workspace: ""` in another worktree | Matched to a room by path, or adopted as a legacy room (`s:existing()`) |
| `g:claude_workspace_dir` set | Read as an absolute `g:claude_room_dir`, with one deprecation notice |
| `g:claude_workspace_store` set | Read as the migration source |
| Diff base store | Unchanged |

---

## 11. API

### Module

`autoload/claude/workspace.vim` becomes `autoload/claude/room.vim`
(`claude#room#…`). It stays git and bookkeeping only, with no UI, so it can be
tested against a fixture repository. `claude#workspace#*` is removed rather than
shimmed: every caller is inside the plugin. The user-facing entry points keep
their names: `:ClaudeWorkspaces` stays as an alias of `:ClaudeRooms`, and
`<leader>cw` is unchanged.

### New

| Function | Purpose |
|----------|---------|
| `claude#room#create(name, base)` | Fetch, then `worktree add --no-track -b room/<name>`; `base` blank = latest default |
| `claude#room#create_sub(parent, name)` | Cut `room/<parent>--<name>` from the parent's branch |
| `claude#room#list()` | Root, then rooms, each followed by its sub-rooms; prunes missing directories |
| `claude#room#children(id)` | A room's sub-rooms |
| `claude#room#base_of_branch(branch)` | The `base` of the room on `branch`, or `''` |
| `claude#room#of_path(path)` | Path → room id, for migration and the diff tree |
| `claude#room#pick_for_session(cb)` | The §5.1 picker; calls `cb(room id)` or nothing on cancel |
| `claude#room#ensure_excluded(root)` | The §4.2 `info/exclude` write |

### Kept, renamed from `claude#workspace#`

`project_root()`, `get()`, `for_session()`, `unique_name()`, `remove()`,
`force_remove()`, `current()`, `set_current()`, `cwd()`, `pick()`, `select()`,
`_reset()`.

### Changed

| Function | Change |
|----------|--------|
| `claude#session#spawn()` (`session.vim:964`) | Takes `room` instead of `branch`/`workspace`; the picker replaces the branch prompt |
| `claude#session#tree()` (`:716`) | Project > room > sub-room, nodes from `claude#room#list()` |
| `claude#session#groups()` (`:668`) | Each status group carries `rooms: [{key, label, sessions}]` |
| `s:make_record()` / `s:persist()` (`:545`, `:896`) | `room` field |
| `s:spawn_dir()`, `s:sweep_cwds()` | Read rooms |
| `s:build_tree()`, `s:build_states()`, `s:place_under_cursor()` (`panel.vim`) | §6 |
| `claude#difftree#base_for()` (`difftree.vim:96`) | §8.2 |
| `s:build_sources()`, `claude#difftree#tree()` (`:250`, `:598`) | §8.1 |
| `claude#store#workspace_path()` | Becomes `claude#store#room_path()` |

### Removed

`s:prompt_branch()`, `s:dir_for()`'s sibling-directory default, `claude#workspace#create(branch, name)`.

---

## 12. Test plan

Fixture repositories in a temp directory, as `test/workspace_create.vader`
already builds them. A bare repository serves as `origin` for the fetch tests.

| File | Covers |
|------|--------|
| `test/room_create.vader` *(from `workspace_create`)* | Layout under `.vim-workspace`; `room/<name>` with no upstream; cut from `origin/main` *after* the remote advanced; fetch failure falls back and warns; named base; `info/exclude` written once |
| `test/room_sub.vader` *(new)* | `room/<r>--<s>` from the room tip; `--` collapsed in names; dirty-room warning; sub-room of root refused; no third level |
| `test/room_name.vader`, `test/room_store.vader` *(from `workspace_*`)* | Uniquifying; store round-trip; pruning, including a room gone but sub-rooms kept |
| `test/room_migrate.vader` *(new)* | `workspaces.json` → `rooms.json`, source left intact; `workspace` → `room` on session load; `g:claude_workspace_dir` mapping |
| `test/session_room.vader` *(from `session_workspace`)* | Every row of §5.2; CTRL-C at each prompt creates nothing |
| `test/panel_grouping.vader`, `test/panel_render.vader` | §6.1 and §6.2 shapes, indents, label elision, the `[sub]` tag surviving truncation, the mixed-project prefix |
| `test/panel_keys.vader` | Fold keys at each level; `n` on room and sub-room rows; `d` refused on a room with sub-rooms |
| `test/difftree_root.vader`, `test/difftree_base.vader`, `test/difftree_render.vader` | §8.1 shape; base chain (override → room → default); `has_override()` false for room bases; `(base gone)` |

No existing test is deleted to make the new shape pass; those that assert the
workspace shape are rewritten to assert the room shape.

---

## 13. Open questions

- **The worktree folder row in the diff tree (§8.1).** It mirrors the disk and
  was asked for, but in a 35-column sidebar it pushes a sub-room's files to
  indent 8. The alternative is to drop it and put the files directly under the
  room and sub-room rows.
- **What a room created from a named branch diffs against.** This design says
  the branch it was cut from, so a room cut from `feature/x` shows only its own
  work. Diffing every room against `main` would show `feature/x`'s commits too.
- **A "finish" verb.** Merge a sub-room into its room, or a room into the
  default branch, then offer to remove it. It would be the plugin's first write
  to a branch it does not own, so it gets its own design.
- **Should creating a room be possible without starting a session?** The panel
  lists empty rooms, so a `:ClaudeRoomNew` is cheap. It is not required by
  anything here.

---

## 14. As built

Where the implementation differs from the design above, and why.

| Section | Design said | Built | Why |
|---------|-------------|-------|-----|
| §5.1 | Popup picker, the current room preselected | `inputlist()`; a blank answer keeps the current room | The questions after it are `input()` prompts, and a popup would hand the rest of the chain to a callback. `s:ask_provider()` made the same choice for the same reason. Only CTRL-C cancels, as for every other prompt |
| §9 | An unused `room/<name>` branch is refused | The name is uniquified past it (`old` → `old-1`) | Same protection — earlier work is never checked out silently — without a dead end at the prompt |
| §9 | An unknown base branch is asked again | Refused, nothing created | Re-asking inside a chain of `input()` prompts reads as a hang |
| §5 | — | `:ClaudeNew room: name` / `:PiNew room: name` skip the questions: an existing room or sub-room is joined, an unknown name becomes a new room off the latest default branch, `room/sub:` a new sub-room, `root:` the main checkout (`claude#room#answer_for()`) | Carries over main's `workspace:` prefix (ff3adb4), which landed while rooms were being built |
| §6.2 | Sessions in no room group under `(no project)` | They sit directly under the status group, ending with the directory they ran in | A room row with nothing to say costs an indent; this is also how every session outside a repository was drawn before |
| §6.1 | — | Sessions in no room sit under the project row, after its rooms | The case §6.1 did not cover: a worktree the plugin does not know |
| §6.2 | Root row as in the place view | `claude-pluing (root)`, no branch | The status group already says what the session is doing; a 35-column row has no space for both |
| §10 | A session in an unknown worktree is adopted as a legacy room | It is left without a room | Adoption wrote store records as a side effect of drawing the panel. Migrated workspaces still become rooms |
| §7.1 | — | `order` field | Rooms made in the same second sorted by name, not creation |
| §11 | `claude#room#pick_for_session(cb)` | `claude#room#ask()` returns the answer; `claude#room#realise()` creates it | Synchronous, so nothing is created until the session name is in too |
| §8.3 | — | `d`/`D` in the session panel check for sub-rooms before asking | A yes would only be met with a no |

Tests: `test/room_create.vader`, `test/room_sub.vader`, `test/room_store.vader`,
`test/session_room.vader` and `test/difftree_rooms.vader` are new or replace
their `workspace_*` predecessors. `confirm()` cannot be answered from a Vader
test, so `d` removing a room is covered through `claude#room#remove()` rather
than through the key.
