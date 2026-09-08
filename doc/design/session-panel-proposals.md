# Session panel: three ways to organise it

A blank-page exercise. Nothing here is decided, and none of it is bound by the
panel that exists today (a `Project > Worktree > Branch > Session` tree in a
35-column sidebar). The question is only: what is the right shape?

## The problem, in numbers

Real state on this machine, not hypotheticals:

| | |
|---|---|
| Session records in the store | **130** |
| …that carry a name a human typed | **11** |
| Live sessions right now | 3, across 2 projects |
| Git worktrees of this repo | 2 |
| Panel width | 35 columns, shared with a diff tree and NERDTree |

Three hard parts follow:

1. **Scale.** 130 rows, of which maybe 5 matter today.
2. **Attention.** Which session is waiting for *me*, right now?
3. **Width.** 35 columns. Every level of indent costs 2 characters of name.

---

## 1. What other tools do

| Tool | Top-level unit | 100+ items | Shows "needs you" | Idea worth stealing |
|---|---|---|---|---|
| **Claude Code agent view** | **State** — Pinned, Ready for review, Needs input, Working, Completed | Completed folds into `… N more`; failures and open PRs never fold | `✻` yellow, animated, in its own group; `s:blocked` filter | The row label is a **generated one-line summary**, not a name you typed |
| **Cursor Agents Window** | Agent run | One row per run | Status per row | Row shows **the task that started it** plus repo and local/cloud |
| **tmux `choose-tree`** | Session > window > pane | `C-s` search; collapse all with `M--` | — | **Shortcut letter in brackets** on each row for direct jump; tag many, act on all |
| **zellij session manager** | Session | Fuzzy find across live *and* exited in one namespace | — | Exited sessions are a **section**, not a separate screen |
| **neo-tree.nvim** | Pluggable **source** — filesystem, buffers, git_status, symbols | `/` fuzzy find, `f` filter | — | One window, **swap what it lists** with `<` and `>` |
| **harpoon** | A hand-picked list of ~4 | Refuses to scale — that is the point | — | **Numbered slots**: `3` jumps to the third thing, no menu |
| **Slack sidebar** | User-made sections | **"Unread conversations only"** per section | Unread bold + count | Let the *user* define the sections; sort each by recent, alpha, or priority |
| **VS Code Repositories view** | Repository | Flat list | — | **Worktrees appear as repositories**, not as children of one |
| **NERDTree** *(from memory)* | Directory | Folds | — | `I` hides the noise by default |
| **Telescope** *(from memory)* | Nothing — no persistent list | Fuzzy filter over everything | — | The list only exists while you are searching it |

### Patterns that recur

- **State beats place.** The two tools built for *many agents* (Claude, Cursor) group by what a session is doing. The tools that group by location are file browsers, where location is the point.
- **The label is generated.** Both agent tools show a machine-written summary of the work. Neither expects you to name 130 things. Our 11-out-of-130 says the same.
- **Two lists, not one.** A short visible list plus a searchable long tail — zellij's fuzzy find, Claude's `… N more`, Slack's unread-only. Nobody scrolls a list of 130.
- **Sections are chosen, not derived.** Slack lets you make them; Claude derives them from state. Almost nobody derives them from the filesystem path.

---

## 2. Proposal A — Status first

**The idea.** The top level is what a session is doing, not where it lives.
Sessions needing you sit at the top; everything finished collapses to one line.

```
Claude Sessions        2 waiting

▾ Needs you (2)
  ✻ pick a diff base    wt · 2m
  ✻ rerun the tests?  root · 5m
▾ Working (1)
  ✽ panel rework      root · 1m
▾ Idle (3)
  ∙ user_interface    root · 2h
  ∙ test4               wt · 4h
  … 1 more
▸ Done (124)
```

**Top level: state.** Because the question you ask the panel is almost always
"who needs me?", not "what is in that folder?".

**Finding one of 130.** You do not browse for it. `/` filters every group by
name; `Done` stays folded until you open it.

| Key | Does |
|---|---|
| `<CR>` | Open the session |
| `/` | Filter all groups |
| `g` | Switch grouping: state ⇄ workspace |
| `<Space>` | Fold a group |
| `p` | Pin to a group that always shows |

**Bad at:** you lose sight of *where* work is happening — two sessions in two
worktrees sit side by side with only a dim suffix to tell them apart. And it
needs a reliable "needs input" signal; without one, `Needs you` is empty and
the whole shape is pointless.

---

## 3. Proposal B — Places

**The idea.** The top level is the workspace — a checkout on disk. Every
workspace is listed whether or not it has sessions, so the panel doubles as
the list of places you can work.

```
Claude Sessions             (7)

▾ claude-pluing
  ▾ root · sidebar-column
    ✽ panel rework        1m
    ∙ blah                5m
  ▾ feature-git-diff-tree
    ✻ diff tree work      2m
  ▸ panel-rework (empty)
▾ dotfiles
  ▾ root · main
    ∙ zsh cleanup         2h
```

**Top level: the project, then the workspace.** Because a session's real
identity is the directory it can write to, and that is what you must not mix up
when several agents run at once.

**Finding one of 130.** Fold everything but the workspace you are in. Old
sessions stay under their workspace, so a workspace you have not touched in a
week is one folded row.

| Key | Does |
|---|---|
| `<CR>` | Open session, or fold a group |
| `n` | New session in the workspace under the cursor |
| `c` | New workspace |
| `<Space>` | Fold |
| `I` | Show unnamed sessions |

**Bad at:** a session waiting for you is invisible inside a folded workspace —
the thing you most need to see is the thing this shape hides. And it spends two
indents before the first session, in a 35-column window.

---

## 4. Proposal C — Pinned rail, everything else searched

**The idea.** The panel shows only a handful of numbered slots plus the few
most recent sessions. The other 120 are reachable only through a filter. Scale
is not solved; it is refused.

```
Claude Sessions   3 live   130 all

 1 ✽ panel rework     root  1m
 2 ✻ diff tree work     wt  2m
 3 ∙ user_interface   root  2h

 recent
   ∙ blah             root  5m
   ✓ test4              wt  4h

 / find   p pin   ? keys
```

**Top level: nothing.** There is no tree. There is a list of what you chose to
keep, and a search box for the rest.

**Finding one of 130.** `/` opens a fuzzy filter over all 130, live and
finished, in one namespace — zellij's approach. Anything you return to twice,
you pin, and it gets a number: `2` jumps straight to it.

| Key | Does |
|---|---|
| `1`–`9` | Jump to that slot |
| `/` | Fuzzy find across all sessions |
| `p` | Pin / unpin the row under the cursor |
| `<C-j>` `<C-k>` | Reorder slots |

**Bad at:** you cannot see the shape of your work — no sense of which branch
has three sessions on it, or that a worktree exists at all. And it only works
if pinning is a habit; a user who never pins gets a panel showing five rows out
of a hundred and thirty, with no way to notice the rest.

---

## 5. Comparison

| | A · Status | B · Places | C · Pinned + search |
|---|---|---|---|
| Scales to 130 | Yes — `Done` folds to one line | Yes — fold by workspace | Yes — most are never shown |
| Find a known session | Filter, or scan 3 groups | Fold down to its workspace | Fuzzy find |
| Spot one needing you | **Immediate** — its own group at top | **Poor** — hidden in a fold | Only if pinned |
| Width cost | 2 indents | 4–6 indents | 0–2 indents |
| State to remember | Fold state per group | Fold state per workspace | Pin order (must persist) |
| Build difficulty | Medium — needs a real "waiting" signal | **Low** — closest to what exists | Medium — new picker, new pin store |

### Recommendation *(opinion)*

**A, with B's grouping one key away.** The panel's job when several agents run
is to answer "who needs me?", and only A answers it without being asked; both
agent-focused tools researched here landed on the same shape independently.
Claude Code's `Ctrl+S` toggle between state and directory grouping is the proof
that the two are not exclusive — build A, and make `g` swap the top level to B
for the times the question really is "what is happening in that worktree?".

What would change my mind: if a reliable *needs-input* signal turns out to be
unavailable, A's top group is dead weight and B is the honest choice. Worth
checking that first — `claude agents --json` reports `status: busy | idle` per
session today, which is a start but is not the same as "blocked on a question".

---

## Sources

Fetched directly:

- [Claude Code — agent view](https://code.claude.com/docs/en/agent-view)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)

From search-result summaries (not fetched in full):

- [harpoon](https://github.com/theprimeagen/harpoon)
- [tmux — Getting Started (tree mode)](https://github.com/tmux/tmux/wiki/Getting-Started)
- [zellij — session management](https://zellij.dev/tutorials/session-management/)
- [Slack — organize your sidebar with custom sections](https://slack.com/help/articles/360043207674-Organize-your-sidebar-with-custom-sections)
- [Cursor — multi-agent](https://cursor.com/help/ai-features/multi-agent)
- [VS Code — branches and worktrees](https://code.visualstudio.com/docs/sourcecontrol/branches-worktrees)

From memory, not verified here: NERDTree, Telescope.

Local measurement: `claude agents --json`, and the plugin's own `data/sessions.json`.
