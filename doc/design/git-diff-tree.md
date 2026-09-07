# Design: git diff file tree

Status: proposed
Target: `claude.vim`
Last updated: 2026-09-07

---

## 1. Summary and motivation

Seeing which files a branch touches currently means abusing NERDTree's
bookmark list. Two commands in `~/.vimrc` do it:

| | Command | Plumbing | Result |
|---|---|---|---|
| `<leader>fc` | `:GitChangedFiles` (`~/.vimrc:268`) | `git diff --name-only <base>...HEAD` | `[C]`-tagged bookmarks |
| `<leader>fu` | `:GitUncommittedFiles` (`~/.vimrc:276`) | `git diff --name-only HEAD` + `git ls-files --others` | `[U]`-tagged bookmarks |

Both funnel through `s:UpdateGitBookmarks()` (`~/.vimrc:240`), which rewrites
`g:NERDTreeBookmarksFile` and re-renders NERDTree. `s:UniqueBookmarkLabel()`
(`~/.vimrc:227`) disambiguates collisions by prepending parent folders.

Three problems follow from using bookmarks as the display:

1. **No hierarchy.** Bookmarks are a flat list, so `autoload/claude/panel.vim`
   and `test/panel_keys.vader` sit next to each other with no directory
   structure, and the label has to smuggle the path in.
2. **Two disconnected sets.** Committed and uncommitted changes are separate
   commands writing separate tags, so there is no single view of "what has this
   branch touched".
3. **No open verbs.** A bookmark opens one way. There is no split, vsplit or
   tab, and no way to keep the sidebar while doing it.

This design replaces both with a proper tree panel.

---

## 2. Goals / Non-goals

### Goals

- A sidebar listing every file that differs from the base branch, as a
  collapsible directory hierarchy, grouped per worktree.
- Committed and uncommitted changes in **one** view, visually distinguished.
- NERDTree-style open verbs, keyboard navigation, folding.
- Incremental filtering/searching within the tree.
- Base branch auto-detected, overridable by command.
- A fixed sidebar order: sessions on top, diff tree in the middle, NERDTree at
  the bottom.

### Non-goals

- Rendering diffs or hunks. This lists *files*; `<leader>fd` and
  `:GitGutterDiffUncommitted` (`~/.vimrc:200`) already show content.
- Staging, committing, or any repository mutation. Read-only.
- Branches without a working tree (§7.1).
- Replacing NERDTree as a general file browser.

---

## 3. Evaluation

Everything here was measured in this repository, not assumed.

### 3.1 Git plumbing

| Command | Result here |
|---------|-------------|
| `git symbolic-ref refs/remotes/origin/HEAD` | `refs/remotes/origin/main` — detection works |
| `git worktree list --porcelain` | one worktree, branch `feature/agent-session-panel` |
| `git diff --name-status main...HEAD` | 23 files, with `A`/`M` letters for free |
| `git diff --name-status HEAD` | empty |
| `git ls-files --others --exclude-standard` | 2 untracked |

`--name-status` costs nothing over `--name-only` and carries the change letter,
so it is used throughout.

### 3.2 Cost

Best of three, warm:

```
git diff --name-status main...HEAD          23.1 ms
git diff --name-status HEAD                 22.9 ms
git ls-files --others --exclude-standard    22.4 ms
git worktree list --porcelain               22.0 ms
```

Essentially all of that is process startup. A full refresh is
`1 + 3 × worktrees` invocations: ~90 ms for one worktree, ~350 ms for five.
**Fine on demand, far too slow for a timer** — which settles §8.

### 3.3 The ordered N-window stack

`claude#panel#stack()` today handles exactly two windows. The required order is
three. The proposed algorithm keeps the desired order as a list, filters it to
the windows actually open, and — if they are not already consecutive leaves of
one `col` node in that order — walks it **bottom-up**, moving each window above
its successor:

```
for i = len-2 downto 0:
    win_splitmove(wins[i], wins[i+1], {'vertical': v:false, 'rightbelow': v:false})
```

Bottom-up matters: each move's target is already in its final position, so the
pass is a single sweep of at most N-1 moves.

Tested against stand-in sidebars, every opening order of three windows:

```
opened ['SESS','DIFF','NERD'] -> row[col[SESS DIFF NERD] main]
opened ['SESS','NERD','DIFF'] -> row[col[SESS DIFF NERD] main]
opened ['DIFF','SESS','NERD'] -> row[col[SESS DIFF NERD] main]
opened ['DIFF','NERD','SESS'] -> row[col[SESS DIFF NERD] main]
opened ['NERD','SESS','DIFF'] -> row[col[SESS DIFF NERD] main]
opened ['NERD','DIFF','SESS'] -> row[col[SESS DIFF NERD] main]
```

All six converge, and a second pass changes nothing (idempotent). Every subset
keeps the relative order: `col[SESS NERD]`, `col[DIFF NERD]`, `col[SESS DIFF]`,
and a lone sidebar stays a plain column.

Closing and reopening:

```
1 stacked heights  SESS=10 DIFF=12 NERD=19  row[col[SESS DIFF NERD] main]
2 closed middle    SESS=10 NERD=32          row[col[SESS NERD] main]
3 closed bottom    SESS=10 DIFF=32          row[col[SESS DIFF] main]
5b reopened raw                             row[DIFF col[SESS NERD] main]
5c after restack                            row[col[SESS DIFF NERD] main]
6 with extra split                          row[col[SESS DIFF NERD] EXTRA main]
```

Four things this establishes:

- Closing any window reflows the column correctly with **no repair needed**;
  fixed heights survive and the bottom-most window absorbs the space.
- A reopened window lands as its own column and **does** need the repair pass,
  so it must run on every sidebar open.
- An unrelated split is never dragged into the column — the pass only touches
  registered sidebars.
- `winfixheight` is best-effort: when the last sibling closes, the survivor
  grows regardless (case 3, DIFF 12 → 32). Acceptable.

### 3.4 What to extract, and what to leave

`autoload/claude/panel.vim` is 873 lines across 56 functions. Splitting them by
whether a second panel would need them:

**Generic — extract to `autoload/claude/sidebar.vim`** (~280 lines): `s:ascii`,
`s:marker`, `s:marker_class`, `s:marker_alt`, `s:width`, `s:panel_split_cmd`,
`s:buf_options`, `s:stack_enabled`, `s:nerdtree_winid`, `nerdtree_bufnr`,
`s:is_stacked`, `s:find_stacked`, `s:apply_stacked_height`, `stack`,
`_nerdtree_init`, `_win_closed`, `s:unfix_height`, `s:link_target`,
`s:link_highlights`, `_relink`, `s:fit`, `s:home_relative`, `s:is_sidebar`,
`s:enter_main`, `s:make_window`.

**Session-specific — stays** (~590 lines): `claude#panel#icon`, `s:node`,
`s:session_line`, `s:disambiguate`, `s:build`, `s:render`, `s:repaint`,
`s:setup_syntax`, the poll timer, every key action (`s:new`, `s:rename`,
`s:end_session`, `s:purge`), `open_session`.

Extraction is not optional here: the stack has to know about *all* sidebars at
once to order them, so it cannot stay inside one panel's script scope. The
`is_sidebar`/`enter_main` pair likewise has to recognise all three, or opening
a file would split the diff tree.

### Verdict

**Feasible, and the ordering requirement is the easy part** — the algorithm is
proven and idempotent. The real work is the extraction, which is a refactor of
existing, tested code and must keep the current 143 assertions green.

---

## 4. Sidebar architecture

`autoload/claude/sidebar.vim` owns a registry of sidebars, ordered by a
priority number:

| Priority | Sidebar | Window id from |
|----------|---------|----------------|
| 10 | Claude sessions | `claude#panel#bufnr()` → `bufwinid()` |
| 20 | Git diff tree | `claude#difftree#bufnr()` → `bufwinid()` |
| 30 | NERDTree | `t:NERDTreeBufName` → `bufwinnr()` |

```vim
call claude#sidebar#register({
      \ 'name':     'difftree',
      \ 'priority': 20,
      \ 'winid':    function('claude#difftree#winid'),
      \ 'height':   {-> get(g:, 'claude_difftree_height', 15)},
      \ })
```

`claude#sidebar#stack()` resolves every registered sidebar to a window id,
drops the closed ones, sorts by priority and runs the §3.3 sweep. It is called
from each panel's `open()`, from `FileType nerdtree`, and from the session
panel's existing poll timer as a backstop.

Heights follow the rule established in
`doc/design/nerdtree-sidebar-stacking.md` §4.5: applied **only on the
transition** into the stacked state, never re-imposed, so a manual resize
sticks. Column *width* remains NERDTree's when NERDTree is present, for the
reason recorded in that document — it force-resizes itself on every redraw.

---

## 5. Panel UX

### 5.1 Layout

```
┌──────────────────────────────┬────────────────────────────┐
│ Claude Sessions         (2)  │                            │
│ ▾ claude-pluing              │                            │
│   ▾ main                     │                            │
│     ● panel design           │                            │
├──────────────────────────────┤                            │
│ Git Diff          main (23)  │   your code                │
│ ▾ claude-pluing              │                            │
│   ▾ feature/agent-session…   │                            │
│     ▾ autoload/claude        │                            │
│       M panel.vim            │                            │
│       A session.vim          │                            │
│       ? scratch.vim          │                            │
│     ▾ doc/design             │                            │
│       A git-diff-tree.md     │                            │
├──────────────────────────────┤                            │
│ NERDTree                     │                            │
│ …                            │                            │
└──────────────────────────────┴────────────────────────────┘
```

The header carries the base branch and the total file count. Directory nodes
collapse runs of single-child directories (`autoload/claude` rather than
`autoload` → `claude`), as that is what makes a change-set tree readable.

### 5.2 Status marks

| Mark | Meaning | Highlight group | Links to |
|------|---------|-----------------|----------|
| `A` `M` `D` | committed vs base | `ClaudeDiffCommitted` | `NERDTreeFile` → `Normal` |
| `A` `M` `D` | uncommitted (working tree vs HEAD) | `ClaudeDiffUncommitted` | `NERDTreeFlags` → `Number` |
| `?` | untracked | `ClaudeDiffUntracked` | `NERDTreeFlags` → `Number` |
| — | both committed **and** dirty | `ClaudeDiffUncommitted` + `*` suffix | |

Directory nodes use `ClaudeDiffDir` → `NERDTreeDir` → `Directory`; the project
and branch nodes use `ClaudeDiffBranch` → `NERDTreeCWD` → `Statement`. This
follows the same prefer-NERDTree's-group-then-fall-back scheme, and the same
`highlight! link` upgrade path, already implemented for the session panel.
`g:claude_panel_ascii` is honoured for the fold markers.

The change letter itself is coloured with the `DiffAdd`/`DiffChange`/
`DiffDelete` groups the user already defines (`~/.vimrc:184-187`).

### 5.3 Keymap

| Key | Action |
|-----|--------|
| `<CR>`, `o` | Open the file, or fold/unfold a node |
| `i` | Open in a horizontal split |
| `s` | Open in a vertical split |
| `t` | Open in a new tab |
| `j`, `k`, `<Down>`, `<Up>` | Move between rows |
| `<Space>`, `za` | Fold or unfold the node |
| `R` | Re-run git and rebuild |
| `/` | Filter (§5.4) |
| `<Esc>` | Clear the filter |
| `b` | Change the base branch (prompts, with completion) |
| `q` | Hide the panel |
| `?` | Toggle the inline key reference |

Files open in the main area through the shared `s:enter_main()`/`s:make_window()`
pair, so a sidebar is never replaced.

### 5.4 Filtering

`/` starts an incremental filter: a `getchar()` loop that appends printable
characters, handles `<BS>`, commits on `<CR>` and cancels on `<Esc>`, redrawing
the tree on every keystroke. Matching is a smart-case substring test against
the path relative to the worktree, so `pan/st` matches
`autoload/claude/panel.vim` only if it is a substring — plain substring, not
fuzzy, to keep results predictable.

While a filter is active: non-matching files are hidden, directories containing
a match are force-expanded regardless of fold state, directories with no match
are hidden entirely, and the header shows `Git Diff   main   /pan (3)`. Fold
state is preserved and restored when the filter clears.

---

## 6. Data model

One record per changed file:

| Field | Source |
|-------|--------|
| `path` | Path relative to the worktree root |
| `worktree` | Worktree root, from `git worktree list --porcelain` |
| `branch` | Branch of that worktree, or `(detached)` |
| `committed` | Letter from `diff --name-status <base>...HEAD`, or `''` |
| `dirty` | Letter from `diff --name-status HEAD`, `'?'` if untracked, or `''` |

`status` is derived: `committed` when only the first is set, `uncommitted` when
only the second, `both` when both. The tree is built by splitting `path` on `/`
and folding into project → branch → directories → file.

---

## 7. Git plumbing

Per worktree `W`, base `B`:

```sh
git -C W diff --name-status B...HEAD              # committed vs base
git -C W diff --name-status HEAD                  # working tree vs HEAD
git -C W ls-files --others --exclude-standard     # untracked
```

The three-dot form is deliberate and matches `s:GitChangedFilesRun` today: it
diffs against the **merge base**, so commits landing on `main` after the branch
was cut do not pollute the list.

### 7.1 Worktrees

`git worktree list --porcelain` is parsed exactly as `s:GitWorktrees()`
(`~/.vimrc:285`) does: `worktree <path>`, then `branch refs/heads/<name>` or
`detached`. A worktree whose branch **is** the base branch is skipped — its
diff against itself is empty and the node would always be blank.

### 7.2 Base branch resolution

In order, first hit wins:

1. `g:claude_difftree_base`, if set.
2. The session override from `:ClaudeDiffBase`.
3. `git symbolic-ref --short refs/remotes/origin/HEAD`, stripped of `origin/`.
4. `main`, if it exists.
5. `master`, if it exists.
6. Give up: the panel renders a single line explaining that no base branch
   could be determined, and `b` still works.

`g:gitgutter_diff_base` is deliberately **not** read or written. It is
gitgutter's setting for sign computation; coupling the two would mean changing
the tree's base silently restyles every buffer's signs. `:ClaudeDiffBase` is
documented as the place to change one, `let g:gitgutter_diff_base` the other.

---

## 8. Refresh and caching

Git is never run on a redraw. The file list is cached per
`(worktree, base)` and rebuilt only on:

- panel open,
- `R`,
- `:ClaudeDiffRefresh`,
- `BufWritePost`, when `g:claude_difftree_auto_refresh` is 1 and the panel is
  open — a save is the one event that reliably changes the dirty set.

At ~90 ms per refresh for one worktree (§3.2) this is comfortable on demand and
would be unacceptable on the session panel's 2-second timer, which is why the
diff tree has no timer of its own.

---

## 9. Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `g:claude_difftree_height` | `15` | Height in the shared column, on first stack |
| `g:claude_difftree_width` | `35` | Width when it is the only sidebar |
| `g:claude_difftree_base` | `''` | Base branch; empty means auto-detect (§7.2) |
| `g:claude_difftree_show_untracked` | `1` | Include `ls-files --others` |
| `g:claude_difftree_auto_refresh` | `1` | Refresh on `BufWritePost` |
| `g:claude_difftree_collapse_dirs` | `1` | Collapse single-child directory runs |

Shared with the session panel: `g:claude_panel_ascii`,
`g:claude_panel_nerdtree_stack`.

---

## 10. API

### New: `autoload/claude/sidebar.vim`

| Function | Purpose |
|----------|---------|
| `claude#sidebar#register(spec)` | Add a sidebar to the ordered registry |
| `claude#sidebar#stack()` | The §3.3 ordered sweep |
| `claude#sidebar#is_sidebar(winid)` | True for any registered sidebar or NERDTree |
| `claude#sidebar#enter_main()` | Leave the sidebars for the main area |
| `claude#sidebar#make_window(mode)` | `'here'` / `'split'` / `'vsplit'` / `'tab'` |
| `claude#sidebar#open(spec)` / `close(spec)` | Create/hide a sidebar window |
| `claude#sidebar#link_highlights(map)` | The prefer-NERDTree link scheme |
| `claude#sidebar#fit(indent, text)`, `home_relative(path)` | Text layout |
| `claude#sidebar#_relink()`, `_nerdtree_init()`, `_win_closed(id)` | Hooks |

### New: `autoload/claude/difftree.vim`

`claude#difftree#toggle()` / `open()` / `close()` / `refresh()` / `bufnr()` /
`winid()` / `set_base(branch)` / `base()` / `files()` / `tree()` /
`open_file(path, mode)` / `_reset()`.

### Changed

| Location | Change |
|----------|--------|
| `autoload/claude/panel.vim` | The 25 generic functions of §3.4 move to `sidebar.vim`; the panel registers itself at priority 10 and calls the shared helpers. **No behaviour change.** |
| `autoload/claude.vim` | `claude#_quit_pre()` excludes every registered sidebar, not just the panel and NERDTree |
| `plugin/claude.vim` | New options (§9), new commands, `<leader>cd` mapping, `BufWritePost` autocommand |

### Commands and mapping

| Command | Mapping | Action |
|---------|---------|--------|
| `:ClaudeDiff` | `<leader>cd` | Toggle the diff tree |
| `:ClaudeDiffOpen` / `:ClaudeDiffClose` | — | Explicit open/hide |
| `:ClaudeDiffRefresh` | — | Re-run git |
| `:ClaudeDiffBase [branch]` | — | Set the base; completes on branch names |

---

## 11. Ordering matrix

| Sequence | Result |
|----------|--------|
| sessions → diff → NERDTree | `col[SESS DIFF NERD]` |
| any of the other five orders | `col[SESS DIFF NERD]` (§3.3) |
| sessions + diff | `col[SESS DIFF]` |
| diff + NERDTree | `col[DIFF NERD]` |
| sessions + NERDTree | `col[SESS NERD]` (unchanged from today) |
| close the middle | column reflows; no repair needed |
| reopen the middle | lands as its own column, repaired on open |
| an unrelated split exists | untouched; never pulled into the column |
| stacking disabled | three independent columns, as today |

---

## 12. Edge cases

| Case | Behaviour |
|------|-----------|
| Not a git repository | Panel renders `(not a git repository)`; no git is run |
| No changes vs base | `(no changes vs main)` |
| Base branch cannot be resolved | `(no base branch — press b to set one)` |
| Base branch does not exist | Same, with the attempted name reported |
| Worktree **is** the base branch | Skipped entirely (§7.1) |
| Detached HEAD worktree | Listed as `(detached)`; committed diff still works |
| File deleted from the working tree | Listed with `D`; opening it reports that it no longer exists rather than creating an empty buffer |
| Renamed file | `--name-status` reports `R`; both paths listed until a rename-aware pass is added (future work) |
| Path with spaces or UTF-8 | `--name-status` quotes such paths with `core.quotepath`; run git with `-c core.quotepath=false` and handle the tab separator |
| Very deep tree | `s:fit()` truncation, as the session panel does |
| Filter matches nothing | `(no files match /xyz)`, filter still editable |
| NERDTree absent | Diff tree stacks with the session panel only |
| Both Claude panels closed | NERDTree keeps the column, unchanged |

---

## 13. Migration

The vimrc bookmark machinery is retired. The exact edit is produced during
implementation and **applied by the user, not by the tooling**:

- Delete `s:UpdateGitBookmarks` / `s:UniqueBookmarkLabel` / `s:GitRoot` /
  `s:RefreshNERDTree` (`~/.vimrc:205-266`), `s:GitChangedFilesRun` and its
  command (`268-273`), `s:GitUncommittedFilesRun` and its command (`276-280`).
- Rebind `<leader>fc` and `<leader>fu` (`~/.vimrc:523-524`) to `:ClaudeDiff`.
- **Keep `s:GitWorktrees()` (`~/.vimrc:285`)** unless nothing else references
  it — this must be checked before recommending removal.

`g:NERDTreeShowBookmarks` (`~/.vimrc:164`) and any hand-made bookmarks are left
alone; only the `[C]`/`[U]` entries stop being written. Existing ones remain in
`g:NERDTreeBookmarksFile` until the user clears them.

---

## 14. Test plan

Fixture repositories are built in a temp directory, as `test/session_group.vader`
already does (`git init -q -b main`, commit, `git worktree add`), so nothing
depends on this repository's own state.

| File | Covers |
|------|--------|
| `test/sidebar_order.vader` | The §3.3 sweep: all six opening orders of three stand-in sidebars converge; every subset keeps relative order; idempotency; closing the middle/bottom/top; a reopened sidebar is repaired; an unrelated split is never absorbed; `is_sidebar()` recognises all three |
| `test/difftree_git.vader` | Classification against a fixture repo: committed-only, dirty-only, both, untracked, deleted; `--name-status` letters; `show_untracked = 0`; a second worktree contributing its own branch node; a worktree on the base branch skipped |
| `test/difftree_base.vader` | Resolution order: explicit global, `:ClaudeDiffBase` override, `origin/HEAD`, `main`, `master`, none; a non-existent base reported rather than throwing; `g:gitgutter_diff_base` untouched |
| `test/difftree_render.vader` | Tree shape for a known file set; single-child directory collapsing; status marks and highlight groups applied; empty states for no-repo / no-changes / no-base; filter narrowing, auto-expansion, clearing, and the no-match state |
| `test/difftree_keys.vader` | Buffer options; `q` hides; `<CR>`/`i`/`s`/`t` placement; a file never opens into a sidebar; fold state persists across a rebuild |

NERDTree itself is stubbed throughout (`g:NERDTree.IsOpen`/`GetWinNum`,
`t:NERDTreeBufName`) with a stand-in window, for the reason recorded in
`doc/design/nerdtree-sidebar-stacking.md` §3.3: it cannot be driven from a
scripted Vim.

**The existing 143 assertions must stay green**, since §3.4 moves 25 functions
out of `panel.vim`. That is the real regression risk in this change.

---

## 15. Future work

- Rename detection (`--find-renames`) collapsing `R` pairs into one row.
- A count badge per directory node.
- Opening a file with `:Gdiffsplit` against the base, using vim-fugitive when
  present.
- Generalising the sidebar registry so tagbar and coc-explorer can join the
  column, which §4 already makes possible.
- Watching the index with a file-system event instead of `BufWritePost`.
