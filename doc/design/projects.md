# Design: projects

Status: implemented
Target: `claude.vim`
Last updated: 2026-11-11

Supersedes `doc/design/rooms.md`. A project *is* a room — a git worktree
sessions belong to — with sub-rooms removed, a branch named after it, and a
baseline you can change and merge from. The sidebar column becomes one panel
that shows each project's diffs, files and sessions itself.

---

## 1. Summary and motivation

Three sidebars (session panel, diff tree, NERDTree) answered three questions
about the same line of work in three places: what are its agents doing, what
did it change, what is in it. `<C-a>` raised all three and the column ran out
of height long before it ran out of questions.

The projects panel answers them in one tree, per project:

```
Projects:
 ▾ Project A [Baseline]
    ▸ main Diff
    ▸ Local Diff
    ▸ Files
    ▾ Sessions
```

`<C-a>` raises that panel and nothing else. `g` still swaps to the sessions
grouped by status (Needs you, Working, Idle, Done).

## 2. Decisions

| Question | Decision | Why |
|---|---|---|
| Project vs room | A project replaces a room. The internal API keeps `claude#room#*`. | Sessions and stores written by older builds name rooms by id; renaming the module would break every one of them for no user-visible gain. |
| Sub-rooms | Dropped. A stored sub-room is read as a project of its own: same id, same directory, named `<room>-<sub>`, base unchanged. | One level is what the panel can show without a third indent; nothing on disk moves. |
| Branch name | The project's name, behind `g:claude_project_branch_prefix` (default empty). | "A new branch with the project name is created." The old `room/` prefix is still recognised in labels. |
| Default baseline | The default branch as the remote has it, fetched: `origin/main` on most repositories. | Unchanged from rooms. |
| Baseline named locally | `main` is read as `origin/main` when the remote has it (`claude#room#baseline()`). | `<baseline> Diff` is "the origin baseline vs the project". |
| Root checkout's baseline | Kept as the diff tree's per-branch base (`claude#difftree#set_branch_base()`). | The root is never stored; the diff tree already has a per-branch store. |
| A project's baseline vs a diff-tree override | Setting the baseline with `b` clears any override on the project's branch. | One value, read by both views. |
| Local Diff | Worktree vs the branch's upstream, else `origin/<branch>`; `(not pushed)` when neither exists. | Projects are created `--no-track`, so a pushed branch often has no upstream configured. |
| Files | Drawn by the panel, from `git ls-files --cached --others --exclude-standard`, indexed once per worktree, listed one level at a time. `readdir()` when git cannot list it. | NERDTree cannot be embedded in another buffer; git gives `.gitignore` for free. |
| `u` | `git fetch <remote> <branch>`, then `git merge --no-edit <baseline>` in the worktree. Refused on a dirty worktree; conflicts are left in progress. | Merge, not rebase: it never rewrites commits an agent may be building on. |
| `D` | Removes the worktree only; the branch is kept. Confirmed once, and again (then forced) when the worktree is dirty. The root cannot be deleted. | Deleting a project never loses a commit. |
| `n` outside a project | Asks which project (`claude#room#ask()`), unless `g:claude_session_prompt_name` is 0. | That option has always meant "ask nothing". |
| Purge | Moved from `D` to `X`. | `D` is delete-project now. |
| Sessions in other repositories | Listed under **Elsewhere** at the bottom of the projects view. | Nothing that used to be reachable from the panel becomes unreachable. |

## 3. Modules

- `autoload/claude/room.vim` — projects: create (`claude#room#create()`), the
  questions (`claude#room#ask()`, `claude#room#ask_new()`), baseline and
  upstream (`claude#room#baseline()`, `claude#room#upstream()`), change and
  update (`claude#room#set_base()`, `claude#room#update()`), remove.
- `autoload/claude/difftree.vim` — the diff engine, now also reached by the
  panel: `claude#difftree#changes(dir, against)`, `#dir_tree()`, `#field()`,
  `#has_own_base()`. Its cache is shared, so `R`, a write and
  `claude#difftree#refresh()` refresh both.
- `autoload/claude/panel.vim` — the projects view (`s:build_projects()`), the
  inline file tree (`s:file_index()`, `s:add_files()`), the project keys and
  the `m` menu. Section folds use `x:`-prefixed keys, shut by default.
- `autoload/claude/sidebar.vim` — `claude#sidebar#toggle_all()` toggles the
  panel alone; stacking the diff tree and NERDTree when they are opened on
  their own is unchanged.

## 4. Cost

Drawing the projects view runs git only for sections that are open: the diffs
through the diff tree's cache, the file tree through its own index. Opening a
section re-reads it; `R`, a write, and every project action drop both caches.
The status poller repaints session rows in place and rebuilds only when the
set of sessions changes, so an open diff is not recomputed every tick.

## 5. Tests

- `test/room_project.vader` — baseline, upstream, `set_base`, `update`
  (clean, dirty, conflicting), the project question.
- `test/room_store.vader` — sub-rooms from older builds flattened.
- `test/panel_projects.vader` — the rows, both diffs, Files, the menu, `<C-a>`.
- `test/sidebar_toggle.vader` — `<C-a>` raises the panel alone.
