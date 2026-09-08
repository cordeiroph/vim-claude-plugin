# Design: sessions belong to workspaces

Status: proposed
Target: `claude.vim`
Last updated: 2026-09-08

Supersedes `doc/design/workspaces.md`, which introduced workspaces as a thing a
session could optionally be given. This design makes them the thing a session
*belongs to*, and reshapes the panel around that.

---

## 1. Summary and motivation

A workspace is a git worktree. `doc/design/workspaces.md` added them, but the
panel was never reshaped to match, and three things follow from that mismatch.

**The tree describes where sessions landed, not where they belong.**
`claude#session#tree()` (`autoload/claude/session.vim:512`) folds sessions into
Project > Worktree > Branch, all three derived per session by
`s:derive_group()` (`:108`) from the directory it was spawned in. A session that
was given a workspace and one that merely happened to start in that directory
are indistinguishable. The worktree level is an accident of `getcwd()` rather
than a choice the user made.

**The root folder has no identity.** The main checkout is where most sessions
run, but nothing names it. `s:existing()`
(`autoload/claude/workspace.vim:339`) returns a record with an empty `id` for
it — somewhere to run, deliberately not a workspace — so it cannot be selected
in the picker as itself, cannot be a stable fold key, and every session in it
carries `workspace: ''`, which also means "no workspace at all".

**Two levels that are always 1:1.** A worktree holds exactly one branch, so
the worktree and branch levels never branch apart: every worktree node has
exactly one branch child. The diff tree already reached this conclusion and
collapsed the two (`autoload/claude/difftree.vim:599`); the session panel still
spends a level and two indents on it, inside a 35-column sidebar.

The fix is to make the workspace the unit the panel is built from, and to make
the root folder one of them.

---

## 2. Goals / Non-goals

### Goals

- One workspace per branch, many sessions per workspace, and a panel that says
  so at a glance.
- The root folder is a workspace like any other — selectable, labelled, and
  able to hold sessions — without being removable.
- Two questions when starting a session, no more, whatever the answer.
- Every session record says which workspace it belongs to, and that survives a
  restart.

### Non-goals

- **Removing worktrees.** `git worktree remove` on a directory holding real
  work is not a panel key. §4 has more to say about why.
- **Managing branches** beyond creating one when asked.
- **Per-tab workspaces.** The selection stays one per Vim, like the diff
  tree's session-wide base.
- **More than one workspace per branch.** Evaluated in §4 and not adopted.

---

## 3. The tree

### 3.1 Shape

```
Project > Workspace > Session
```

The branch is not a level: it is 1:1 with the workspace, so it is shown in the
workspace's label, exactly as the diff tree names a worktree in its branch
label. The project level stays — several repositories can be open at once, and
`claude#session#refresh()` (`:372`) now restores sessions by project, so a
panel with two projects in it is a normal state rather than a curiosity.

```
Claude Sessions               (4)

▾ claude-pluing
  ▾ claude-pluing (root) — sidebar-column
    ● panel design
    ○ blah
  ▾ feature-git-diff-tree — feature/git-diff-tree
    ● diff tree work
    ✗ review pass
  ▾ panel-rework — feature/panel-rework
    ● prototype
▾ dotfiles
  ▾ dotfiles (root) — main
    ○ zsh cleanup
```

Three levels instead of four; sessions sit at indent 4 rather than 6, which is
two more columns of name in a 35-column sidebar.

A workspace row is listed whether or not it holds sessions, so the panel
doubles as the workspace list and `<leader>cw` has a visible counterpart. A
project row appears when it has at least one workspace with a session, or is
the project Vim is in.

### 3.2 Labels

| Row | Label |
|-----|-------|
| Project | Basename of the project root, as today |
| Root workspace | `<basename> (root) — <branch>`, branch read live |
| Workspace | `<name> — <branch>` |
| Workspace whose directory is gone | `<name> — (missing)`, dimmed |
| Session | Unchanged: `claude#session#label()` (`:702`) |

The branch suffix is elided when the workspace name and the branch are the same
string, which is the common case for a workspace created from a branch: `panel-rework — panel-rework` reads as noise.

### 3.3 Fold keys and highlights

Fold state lives in `s:collapsed`, keyed by the strings `claude#session#tree()`
builds. Two keys instead of three:

| Level | Key |
|-------|-----|
| Project | `p:<project root>` |
| Workspace | `w:<project root>\|<workspace id>` |

The workspace key is the *id*, not the path, so a workspace stays folded across
a restart even though `claude#session#tree()` no longer derives it from a
directory.

The highlight group names are public — `doc/claude.txt:497` and `README.md:143`
tell people to override them — so they are kept and re-pointed rather than
renamed:

| Group | Was | Becomes |
|-------|-----|---------|
| `ClaudeSessionProject` | Project row | Unchanged |
| `ClaudeSessionWorktree` | Worktree row | The workspace name |
| `ClaudeSessionBranch` | Branch row | The ` — <branch>` suffix on that row |
| Others | — | Unchanged |

`s:setup_syntax()` (`autoload/claude/panel.vim:172`) matches by indent, so the
patterns move from `^    ` to `^  `, and the branch group becomes a `contained`
match on the suffix rather than a whole-line match. Anyone who linked the two
groups to the same colour — which is what the documented example does — sees no
change at all.

---

## 4. Evaluation: several workspaces on one branch, via `--detach`

The premise: `git worktree add --detach <dir> <branch>` puts a workspace at a
branch's tip *without* checking the branch out, so the one-worktree-per-branch
rule does not apply and a branch could carry any number of parallel agent
workspaces. Each agent commits in its own workspace; the work is merged back
into the branch — and on to `origin` — when it is done.

Every claim below was verified by running the commands in a throwaway
repository, not from memory.

### 4.1 It does work

```
$ git worktree add --detach ../w1 feature
$ git worktree add --detach ../w2 feature      # no refusal
$ git worktree list
  .../repo  0194371 [main]
  .../w1    0194371 (detached HEAD)
  .../w2    0194371 (detached HEAD)
```

Both agents commit freely; neither moves `feature`:

```
w1 HEAD -> 3b4a8d0    w2 HEAD -> 8a95338    feature -> 0194371
```

Contrast `--force`, which is the naive way to get two worktrees on one branch
and is disqualified outright: the two share the ref, so after agent 1 commits
`new.txt`, agent 2's index reads as `D new.txt` and its next commit is
`new.txt | 1 -` — agent 1's file is deleted from the branch. Verified. That is
silent data loss between two agents, so `--force` is not a candidate.

### 4.2 Getting the work back

Two paths, both verified:

**A. Merge the sha into the branch.** From a worktree that has `feature`
checked out — the root workspace, normally:

```sh
git merge --no-ff <sha-from-w1> -m "merge agent 1"
git merge --no-ff <sha-from-w2> -m "merge agent 2"
```

Produces the expected two-parent history. The second merge is a real merge of
two independent lines of work, with the conflicts that implies whenever both
agents touched the same file.

**B. Push the sha straight to the remote branch.**

```sh
git push origin <sha>:refs/heads/feature
   2598b61..861ba4b  861ba4b -> feature
```

This works, and it is a trap: it advances `origin/feature` while the *local*
`feature` stays at `2598b61`. The next person to pull gets a divergence they
did not create. If this design ever pushes on the user's behalf it must go
through path A first.

So "merge it into origin/branch" means: merge into the local branch, then push
that branch. Path B is not the shortcut it appears to be.

### 4.3 What it costs

**Unmerged work is deleted without a word.** This is the finding that decides
it:

```sh
$ git worktree add --detach ../w3 feature
$ (cd ../w3 && ... && git commit -m "agent 3")
$ git worktree remove ../w3        # no --force needed; exit 0
$ git for-each-ref --contains <sha> | wc -l
0
```

The worktree is clean — everything is committed — so `git worktree remove`
raises nothing. The commits are then reachable from no ref at all and survive
only in the reflog until `gc`. A branch-per-workspace has no equivalent
failure: the branch keeps the commits whatever happens to the directory.

**Merging is now the user's job, repeatedly.** Two agents from one tip produce
two lines of history that must be merged and conflict-resolved. With a branch
each, that cost exists too — but it is paid at review time against a named
branch, not against a sha the user has to go and find.

### 4.4 What it breaks in the code as it stands

| Where | What happens |
|-------|--------------|
| `s:worktrees()` (`workspace.vim:104`) | Only records lines matching `^branch `; the porcelain emits `detached` instead, so detached worktrees are **invisible** — to it and to `s:checkout_of()` (`:121`) |
| `s:derive_group()` (`session.vim:141-146`) | Labels a detached checkout `(detached: <sha>)`. Verified: two detached workspaces on one branch land under *two different* branch rows, so the grouping the feature exists to provide is exactly what is lost |
| The workspace record | Has `branch`, which a detached workspace does not have. It would need a second field — the branch it was cut from — and every consumer taught the difference |
| `claude#difftree#` | Diffs a branch by name (`base_for()`, `:96`); a detached workspace has no name to diff, so its changes would not appear in the diff tree |
| `claude#session#new()` | Would need a third answer — join, derive, or detach — which the two-question budget in §5 does not have room for |

`autoload/claude/difftree.vim:192` does handle the `detached` porcelain line, so
the two modules already disagree about detached worktrees. Adopting this would
mean reconciling them.

### 4.5 Verdict: not adopted

Rejected, on the strength of §4.3: a workspace whose commits live on no ref is
one `git worktree remove` — or one `rm -rf` — away from losing an agent's
entire output, and the plugin cannot warn about it without reimplementing
reachability checks. The feature's own purpose argues against it too: the
reason to want several workspaces on one branch is to see them *together*, and
§4.4 shows they would be scattered across `(detached: sha)` rows.

The parallelism is available at no risk by giving each workspace its own
branch — `feature/x` and `feature/x-2`, or a name of the user's choosing —
where every agent's work is on a ref, visible in the diff tree, and mergeable
by name.

What would change the verdict: a "finish workspace" verb that merges a
workspace's commits into a named branch and refuses to remove a workspace whose
commits are not reachable from one. With that in place, `--detach` becomes a
reasonable opt-in for throwaway experiments, and §7's record already has room
for the `from_branch` field it needs. It is future work (§12), not this design.

---

## 5. The prompt flow

Two questions, branch then name, as today — `s:prompt_branch()`
(`session.vim:652`) and `s:prompt_name()` (`:669`), unchanged in appearance.
What changes is what the branch answer does.

| Branch | Workspace | Session runs in | Session named |
|--------|-----------|-----------------|---------------|
| Exists, no worktree | Created on it | The new worktree | The name, else the workspace name |
| Exists, has a workspace | **Joined**, nothing created | That workspace | The name, else the workspace name |
| Does not exist | Branch created, workspace created on it | The new worktree | The name, else the workspace name |
| Blank | None | The current workspace (`<leader>cw`), else the root workspace | The name, else nothing — the session is unnamed |

Three notes on the rows:

- **Joining is the normal path, not a fallback.** Asking for a branch that
  already has a workspace is how you put a second session in it, which is the
  whole point of "many sessions per workspace". No question is asked to confirm
  it; the panel shows where the session landed.
- **The blank row takes the workspace's branch, not `getcwd()`'s.** Today the
  session's `branch` field comes from `s:derive_group()` on its spawn
  directory, which is the same answer by accident. Making it the workspace's
  branch by construction is what keeps the tree honest when the root
  workspace's branch changes under a running session (§6).
- **Blank branch and blank name is unchanged.** The session belongs to the
  current workspace, is left unnamed, and stays hidden until `I` reveals it.
  `s:was_named()` (`:689`) and the `I` toggle are untouched.

CTRL-C at either prompt abandons everything and returns `''`, as now. Nothing
is created before both answers are in: the workspace is created after the name
prompt, so cancelling the second question does not leave a worktree behind.

`g:claude_session_prompt_name = 0` still skips both prompts: no workspace, the
current one, unnamed.

---

## 6. The root workspace

The main checkout becomes a workspace with the reserved id `root`.

| Property | Value |
|----------|-------|
| `id` | `root` |
| `name` | Basename of the project root |
| `path` | The project root (`claude#workspace#project_root()`, `:73`) |
| `branch` | **Derived live**, never stored |
| `created` | The repository's own age, or 0 |

It is **materialised, not persisted**: `claude#workspace#list()` (`:159`) puts
it at the head of the list, computed each time, and the workspace store never
holds a `root` key. That gives it everything the current empty-`id` record
lacks — a stable fold key, a picker entry, a value for a session's `workspace`
field — without inventing a store record for a directory git already manages.

Its branch is derived because it is the one workspace whose branch changes: the
user switches branches in their main checkout all day. The consequences:

- A session started in the root workspace records `workspace: 'root'` and the
  branch **as it was at spawn**, which is what `s:make_record()` (`:444`)
  already does and what the panel groups by. The workspace row shows the
  branch as it is *now*.
- So a workspace row can disagree with the sessions under it after a branch
  switch. That is truthful — the sessions really did start on the old branch —
  and the row label is the live answer. No repair is attempted.
- The root workspace is never pruned by the missing-directory sweep in
  `claude#workspace#list()`, and `claude#workspace#create()` never returns it
  as a place to *create*: a branch checked out in the main checkout resolves to
  it via `s:existing()` (`:339`), which is the behaviour that already exists,
  now with a real id instead of an empty one.

---

## 7. Data model

### 7.1 The workspace record

| Field | Source | Note |
|-------|--------|------|
| `id` | The name, or `root` | Unique per project |
| `name` | Display name | Slugged, uniquified |
| `branch` | The branch checked out there | Derived, not stored, for `root` |
| `path` | Absolute worktree directory | |
| `project` | Main repository root | Shared by every workspace of one repo |
| `created` | Unix time | |
| `from_branch` | *(reserved)* | The branch a detached workspace was cut from; unused until §4.5's condition is met |

### 7.2 The session record

Two fields, both already present:

| Field | Change |
|-------|--------|
| `workspace` | Now always set: a workspace id, or `root`. The empty string no longer occurs in new records |
| `named` | Unchanged |

`project`, `worktree` and `branch` stay on the record. They are no longer what
the tree is built from, but `claude#session#refresh()` matches on `project`
(`s:belongs_here()`, `:431`), the diff tree reads `branch`, and a record whose
workspace has been deleted still has them to fall back on.

### 7.3 On disk

```json
{
  "version": 1,
  "workspaces": {
    "/home/me/src/claude.vim": {
      "feature-git-diff-tree": {
        "id": "feature-git-diff-tree",
        "name": "feature-git-diff-tree",
        "branch": "feature/git-diff-tree",
        "path": "/home/me/src/claude.vim-feature-git-diff-tree",
        "project": "/home/me/src/claude.vim",
        "created": 1788860439
      }
    }
  }
}
```

Unchanged from today — `root` is never written here.

---

## 8. Migration

| What exists | What happens |
|-------------|--------------|
| Session with `workspace: ""` whose `cwd` is the project root | Read as `workspace: "root"`; no rewrite needed, the mapping is derived on load |
| Session with `workspace: ""` whose `cwd` is a linked worktree | Matched to a workspace by path; adopted as one when it is not registered, which `s:existing()` (`:339`) already does |
| Session with `workspace: ""` whose `cwd` no longer exists | Grouped under a `(missing)` workspace row, keeping its recorded branch as the label. Resumable only after the directory comes back — the warning in `s:spawn_dir()` (`:629`) already covers it |
| Session naming a workspace that has been deleted | Same `(missing)` row |
| Workspace store from the current build | Loads as is; no schema bump |
| Fold state | In-memory only; a restart starts unfolded, as now |

No store rewrite, no version bump, nothing to undo if the design is reverted.

---

## 9. Edge cases

| Case | Behaviour |
|------|-----------|
| Branch checked out in a worktree made outside the plugin | Adopted as a workspace and listed, as `s:existing()` (`:339`) does today |
| Workspace directory deleted behind our back | Pruned from the store; sessions that named it show under a `(missing)` row and are not resumable until it returns |
| Root workspace's branch changes | Row label follows it; sessions keep the branch they started on (§6) |
| Session resumed after its workspace is gone | Warned once, spawned in its recorded `cwd`, per `s:spawn_dir()` (`:629`) |
| Detached worktree present | Listed as a workspace with `(detached: <sha>)` as its branch; never *created* by the plugin (§4.5) |
| Bare repository | No project root, so no workspaces; the branch prompt still appears and creation warns |
| Not a git repository | Same; sessions run in `getcwd()` and group under `(no project)` |
| Two Vim instances | Both read the same store; last writer wins per key, as the store already guarantees |
| Two workspaces whose names collide | Cannot happen: `claude#workspace#unique_name()` (`:236`) suffixes within the project |
| Project with no sessions at all | Its row is still drawn when it is the project Vim is in, so the root workspace is always reachable |

---

## 10. API

### Changed

| Function | Change |
|----------|--------|
| `claude#session#tree()` (`session.vim:512`) | Returns Project > Workspace > Session; workspace nodes come from `claude#workspace#list()`, not from per-session grouping |
| `claude#session#new()` (`:740`) | §5 table; always records a workspace id |
| `s:make_record()` (`:444`) | `workspace` defaults to `root`, never `''` |
| `claude#workspace#list()` (`workspace.vim:159`) | Prepends the materialised root workspace |
| `claude#workspace#get()` (`:199`) | Answers for `root` |
| `s:existing()` (`:339`) | Returns the root workspace record instead of an empty-id stand-in |
| `claude#workspace#cwd()` (`:449`) | Falls back to the root workspace's path rather than `getcwd()` |
| `s:build()` (`panel.vim:252`) | Two levels of indent instead of three |
| `s:setup_syntax()` (`:172`) | Indent patterns shift; branch becomes a contained match |

### New

| Function | Purpose |
|----------|---------|
| `claude#workspace#root()` | The materialised root record for the current project |
| `claude#workspace#is_root(id)` | Guard for the paths that must not remove or prune it |
| `claude#workspace#of_path(path)` | Path → workspace id, for migrating `workspace: ""` records |

### Removed

Nothing. `claude#session#group_of()` (`:101`) stays: the diff tree and the
session record still use it.

---

## 11. Test plan

Fixture repositories in a temp directory, as `test/session_group.vader` and
`test/workspace_create.vader` already build them.

| File | Change |
|------|--------|
| `test/session_registry.vader` | Tree assertions move from Project > Worktree > Branch to Project > Workspace |
| `test/panel_render.vader` | Indents, labels including the ` — <branch>` suffix and its elision, the `(root)` marker, and a `(missing)` row |
| `test/panel_keys.vader` | Fold keys at the new levels; `I` unchanged |
| `test/workspace_create.vader` | `root` is listed first, is never pruned, and is never created |
| `test/session_workspace.vader` | Each row of the §5 table, including two sessions joining one workspace and the blank-branch row taking the current workspace's branch |
| `test/session_hidden.vader` | Unchanged; re-run as a regression guard |
| New: `test/workspace_root.vader` | The materialised record: derived branch, stable id across a restart, never in the store, `workspace: ""` records mapping onto it |

The suite is 393 tests / 858 assertions today; none of them may be deleted to
make the new shape pass.

---

## 12. Open questions

- Should a workspace row show a session count when folded (`▸ panel-rework — feature/panel-rework (3)`)? Cheap, and the header already carries a live count.
- Should `<leader>cw` remain a separate picker now that the panel lists every
  workspace, or become "jump to the workspace row"?
- The "finish workspace" verb from §4.5 — merge a workspace's commits into a
  named branch, refuse removal when they are reachable from nothing — is the
  gate on ever revisiting `--detach`.
