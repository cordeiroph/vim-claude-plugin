# Design: the session panel groups by state

Status: **implemented**
Target: `claude.vim`
Last updated: 2026-09-08

Implements the recommendation of `doc/design/session-panel-proposals.md` §5 —
Proposal A, with Proposal B's grouping one key away.

Composes with `doc/design/session-workspaces.md` rather than competing with it,
and does **not** depend on it having landed. That design reshapes the tree of
places; this one demotes it from default to `g`, and takes its §5 prompt flow
as the `N` key. Until it lands, the `g` view is the panel's existing
`Project > Worktree > Branch` tree, unchanged; when it lands, the `g` view
becomes `Project > Workspace` and nothing here needs revisiting.

Where this document says what the code now does, it was verified against the
suite: 466 tests / 1002 assertions, up from 393 / 858.

---

## 1. Summary and motivation

Measured on this machine, not hypothesised: **130 session records, 11 of them
carrying a name a human typed, 3 live, in a 35-column sidebar.**

**The panel answers the wrong question first.** `s:build()`
(`autoload/claude/panel.vim:252`) draws `Project > Worktree > Branch > Session`
from `claude#session#tree()` (`autoload/claude/session.vim:678`). That shape
answers "what is in that folder?". With three agents running the question is
almost always "which one is waiting for me?", and the panel cannot answer it at
all — a session waiting for a permission prompt looks exactly like one that
finished four hours ago, two folds deep.

**There is no waiting state to show.** `claude#session#status()` (`:342`)
returns three values — `active`, `idle`, `closed` — and `idle` means only "no
terminal output for `g:claude_panel_idle_secs` seconds" (`plugin/claude.vim:68`). A session
blocked on "Do you want to proceed?" produces no output, so it is reported
`idle`: indistinguishable from one nobody has touched since lunch.

**Nobody names 130 things.** `claude#session#label()` (`session.vim:873`) shows
`(unnamed 9c926d10)` for 119 of the 130. The information to do better is
already read: `s:scan_transcript()` (`:212`) extracts a 60-character `snippet`
from the first user message of every transcript it scans, and
`claude#session#refresh()` (`:450`) already falls back to
`timestamp — snippet` for unnamed records — it just buries the snippet inside
the `name` field of a record that is simultaneously marked `named: 0`.

**And the long tail is smaller than it looks.** `s:transcript_paths()` (`:267`)
caps the scan at `g:claude_panel_closed_limit` newest transcripts per project
(default 10, `plugin/claude.vim:76`). The registry never holds 130 closed
sessions, so `Done (124)` is not a row this design can honestly draw today.
§8 says what it draws instead.

The fix is to group by what a session is *doing*, to make "doing" mean
something by reading the terminal we already read, and to keep the place-shaped
tree on `g` for when the question really is about a worktree.

---

## 2. Goals / Non-goals

### Goals

- A session that is waiting for the user is visible without opening a fold,
  scrolling, or filtering.
- The place-shaped tree stays one keystroke away and loses nothing.
- Every visible row is readable: no `(unnamed 9c926d10)` where a summary exists.
- The finished tail costs one line until asked for.
- No new process, no new file, no change to the user's Claude configuration.

### Non-goals

- **Pinned slots and numbered jumps.** Proposal C's rail is not adopted; §13
  keeps the door open.
- **Searching transcripts that are not in the registry.** `/` filters what the
  panel knows about (§8).
- **A notification, bell or popup** when a session starts waiting. The glyph
  and the header count are the whole of it.
- **Changing what a session *is*.** Workspaces, records and the store are
  `session-workspaces.md`'s business; this design reads them.

---

## 3. The two views

### 3.1 State view (default)

```
|<---------- 35 columns --------->|
Claude Sessions           2 waiting

▾ Needs you (2)
  ✻ pick a diff base        wt · 2m
  ✻ rerun the tests?      root · 5m
▾ Working (1)
  ● panel rework          root · 1m
▾ Idle (2)
  ○ user_interface        root · 2h
  ○ zsh cleanup             wt · 4h
▸ Done (10)

? help
```

Four groups, fixed order, always in this order: `Needs you`, `Working`,
`Idle`, `Done`. A group with no sessions is not drawn — except `Done`, which is
drawn folded whenever the registry holds a closed session, so the tail is never
invisible.

Sessions sit at indent 2 instead of 6. That is four columns of name back.

### 3.2 Place view (`g`)

The tree the panel drew before this change, unchanged and one key away. Once
`session-workspaces.md` lands it becomes `Project > Workspace` and this view
inherits that shape for free:

```
Claude Sessions           2 waiting

▾ claude-pluing
  ▾ claude-pluing (root) — sideb…
    ✻ pick a diff base           2m
    ● panel rework               1m
  ▾ feature-git-diff-tree
    ✻ rerun the tests?           5m
  ▸ panel-rework
▸ dotfiles
```

The header is the same header, so the waiting count follows you into this view.
The workspace suffix on each row drops — the parent row already says it — which
buys back the two indents this view spends.

### 3.3 The row

| View | Layout | Label budget at 35 columns |
|------|--------|----------------------------|
| State | `  <glyph> <label> <workspace> · <age>` | 18 |
| Place | `      <glyph> <label> <age>` | 21 |

The suffix is right-aligned to the panel edge and built first; the label is
fitted into what is left with `claude#sidebar#fit()`
(`autoload/claude/sidebar.vim:484`), which trims from the left so the
distinctive tail survives. When the two cannot both fit, the suffix is dropped
and the label keeps the row.

`<workspace>` is the session's workspace id, or the basename of its worktree
when it has none, truncated to 6 characters. `age` is `2m` / `4h` / `3d`,
measured from `last_active` for a live session and from `last_focus`, else
`created`, for a finished one — a disk record has `last_active` set to whenever
Vim read it, which is no age at all.

`s:row(indent, glyph, label, suffix)` in `panel.vim` owns this; nothing else
composes a session line.

### 3.4 Keymap

| Key | Does | Change |
|-----|------|--------|
| `<CR>` `o` `<2-LeftMouse>` | Open the session, or fold the group | Unchanged |
| `i` `s` `t` | Open in a split / vsplit / tab | Unchanged |
| **`g`** | **Swap the top level: state ⇄ workspace** | **New** |
| **`/`** | **Filter every group by label** | **New** |
| **`n`** | **New session here, asking only its name** | **Changed** (§5.1) |
| **`N`** | **New session: branch, then name** | **New** (§5.2) |
| `r` | Rename the session under the cursor | Unchanged |
| `d` / `D` | End / purge the session | Unchanged |
| `I` | Reveal the buried rows in `Done` | Changed (§6.2) |
| `<Space>` `za` | Fold | Unchanged |
| `R` | Full refresh | Unchanged |
| `q` `?` | Hide the panel / toggle help | Unchanged |

`n` moves from "ask two questions" to "do the obvious thing"; `N` inherits the
questions. Nothing else in `s:setup_keys()` (`panel.vim:659`) moves.

---

## 4. The waiting signal

`session-panel-proposals.md` §5 names this as the thing the whole shape rests
on: without a real *needs input* signal, `Needs you` is an empty group and B is
the honest choice. So it is settled first.

### 4.1 What is actually observable

| Source | Gives | Verdict |
|--------|-------|---------|
| `s:term_tail()` (`session.vim:371`) | The bottom 5 rows of the terminal, already rebuilt every poll | **Adopted.** It is where the question is literally printed |
| `claude agents --json` | `sessionId`, `cwd`, `name`, `kind`, `status: busy \| idle` — verified working on this machine | Rejected as the signal: it has no waiting value. §13 keeps it for foreign sessions |
| A `Notification` hook in `.claude/settings.json` | A true "blocked" event | Rejected: it edits configuration the plugin does not own, and covers only sessions started after it is installed |

### 4.2 The classifier

`claude#session#poll()` (`:411`) already calls `s:term_tail()` on every live
session and already compares the result to the previous one. Classification is
one regex over a string the poll has in hand:

```vim
" §4.2 — what the bottom of the terminal says the session is doing.
" '' means "cannot tell"; the caller falls back to the time rule.
function! s:classify(tail) abort
  if empty(a:tail)
    return ''
  endif
  if a:tail =~# s:working_pat()
    return 'active'
  endif
  if a:tail =~# s:waiting_pat()
    return 'waiting'
  endif
  return ''
endfunction
```

| Option | Default | Matches |
|--------|---------|---------|
| `g:claude_panel_working_pat` | `'esc to interrupt'` | The spinner footer Claude prints while it is working |
| `g:claude_panel_waiting_pat` | `'\%(^\|\n\)\s*❯\?\s*1\.\s\|Do you want\|(y/n)'` | A numbered choice, a permission question, a yes/no |

Both are user-overridable because they track another program's output, and that
output is not ours to promise. A pattern that stops matching degrades to the
time rule below — never to a wrong answer.

### 4.3 The status rules, restated

Replaces the table in `agent-session-panel.md` §5.1:

| Condition | Status |
|-----------|--------|
| No record | `closed` |
| `pinned` (a fabricated record, as tests build) | Verbatim, unchanged |
| No buffer, no job, or the job is not running | `closed` |
| `s:classify()` says `active` | `active` |
| `s:classify()` says `waiting` | **`waiting`** |
| Cannot tell, and output arrived within `g:claude_panel_idle_secs` | `active` |
| Cannot tell, and it did not | `idle` |

`waiting` is a fourth value, not a replacement for one. Every existing caller
that tests `!=# 'closed'` — `claude#session#live()` (`:1242`),
`s:cmp_records()` (`:608`) — keeps working unmodified.

### 4.4 Glyphs

| Status | Group | Glyph | ASCII |
|--------|-------|-------|-------|
| `waiting` | Needs you | `✻` | `[?]` |
| `active` | Working | `●` | `[A]` |
| `idle` | Idle | `○` | `[I]` |
| `closed` | Done | `✗` | `[C]` |

`claude#panel#icon()` (`panel.vim:46`) gains the `waiting` key in both sets;
`g:claude_panel_icons` (`plugin/claude.vim:50`) overrides it like the others.
A new `ClaudeSessionWaiting` highlight links to `WarningMsg`, then `Todo` —
the one row in the panel allowed to be loud.

### 4.5 What would change my mind

If the two patterns turn out to misfire in normal use — a false `waiting` is
worse than none, because it trains you to ignore the group — the honest retreat
is `Working` / `Idle` / `Done` with `g` unchanged, which is A's shape minus its
argument, and at that point B deserves to be the default. The patterns are
configuration precisely so that this is a settings change and not a redesign.

---

## 5. Creating a session

In a state-grouped tree the cursor is no longer over a workspace, so `n` has
lost the context `s:new()` (`panel.vim:818`) never used anyway.

### 5.1 `n` — here, and what to call it

"Where the cursor is" means the subtree it is in, not only the row it is on.
In the place view every row under a worktree — the worktree row, the branch
row, the sessions — answers with that worktree, because that is the checkout
you are looking at.

| Cursor is on | Session is created in |
|--------------|-----------------------|
| A session row | Its workspace, else the worktree it ran in |
| A branch row | The worktree it hangs under |
| A worktree row | That worktree |
| A project row | The repository root — the main checkout, whatever is selected |
| A state group header, the title, or a blank | `claude#workspace#current()` (`workspace.vim:431`), else where Vim already is |

A directory the plugin knows as a workspace is passed to `spawn()` as a
workspace id, so the new session records where it *belongs*. A worktree nobody
registered — one made by hand with `git worktree add`, or a record from before
workspaces existed — is passed as a plain `cwd`, so the session still runs in
the right place without a workspace being invented for it.

One question, not two. The row under the cursor has already answered *where*,
so the only thing worth asking is what to call it — and a blank answer is still
an answer: the session goes unnamed and §6.1 labels it from its first message.
`g:claude_session_prompt_name = 0` skips the question, as it skips both of `N`'s.
If the chosen workspace's directory has gone missing, the existing warning path
in `s:spawn_dir()` (`session.vim:796`) applies and the root workspace is used.

This is the common case, and it now costs one keystroke and one answer instead
of two.

### 5.2 `N` — the full flow

`session-workspaces.md` §5, verbatim and unchanged: `s:prompt_branch()`
(`session.vim:652`) with completion from `claude#difftree#complete_branch()`
(`difftree.vim:167`) over local and remote refs, then `s:prompt_name()`
(`:669`). Blank branch means the current workspace; a branch that exists
without a worktree gets one; a branch that does not exist is created off HEAD;
a branch that already has a workspace is *joined*. CTRL-C at either prompt
abandons everything.

`g:claude_session_prompt_name = 0` (`plugin/claude.vim:113`) keeps its meaning:
`N` behaves like `n`.

### 5.3 The API this needs

`claude#session#new()` (`:906`) is today the only way in, and its two
positional arguments (`name`, `placement`) cannot express "in this workspace,
asking only for a name". One new entry point owns the work:

```vim
" opts: workspace (id), cwd, name, branch, placement,
"       prompt (branch then name), ask_name (name only)
function! claude#session#spawn(opts) abort
```

`claude#session#new(...)` becomes a thin wrapper over it with today's exact
behaviour and signature, so `:ClaudeNew` (`plugin/claude.vim:240`),
`claude#session#target()` (`session.vim:1269`) and every test calling it are untouched.

---

## 6. Labels

### 6.1 What a row says

```vim
function! claude#session#label(rec) abort
  if !empty(get(a:rec, 'name', ''))
    return a:rec.name            " a name someone typed
  endif
  if !empty(get(a:rec, 'snippet', ''))
    return a:rec.snippet         " the first thing asked of it
  endif
  return '(unnamed ' . strpart(a:rec.id, 0, 8) . ')'
endfunction
```

`snippet` becomes a first-class field on the record, set by `s:make_record()`
(`:518`) from `s:scan_transcript()` (`:212`), which already produces it. Two
consequences worth stating:

- **`refresh()` stops smuggling the snippet into `name`.** Today an unnamed
  record is given `name = '2026-09-08 14:02 — pick a diff base'` while
  `named` stays 0 (`:372`). That string is a label pretending to be a name; it
  breaks `s:was_named()`'s (`:856`) contract and it wastes 17 columns on a
  timestamp. The snippet goes in `snippet`, and `name` stays empty.
- **A live session gets its snippet late.** Its transcript does not exist at
  spawn. `claude#session#poll()` reads it once, the first time the transcript
  appears, and never again — one 60-line read per session per Vim run.

`s:disambiguate()` (`panel.vim:351`) keeps working: it appends `(2)` to
repeated labels, and two sessions asked the same first question genuinely do
need telling apart.

### 6.2 What `Done` hides

A closed session is **buried** — not listed — when either is true:

- it has no name a human typed (`named` is 0), or
- its last activity is more than `g:claude_panel_stale_days` (default **2**)
  ago.

`I` reveals them, exactly as it reveals unnamed sessions today. The rule lives
in one predicate, `claude#session#is_buried(rec)`, and is applied by
`claude#session#list()` (`session.vim:587`) so the panel does no filtering of its own — as
now.

The change from today is the **scope**: `list()` currently drops every unnamed
session in every group. Under this design an unnamed session is perfectly
visible in `Needs you`, `Working` and `Idle` — it has a readable label now, and
a session waiting for you is the last thing to hide. Only `Done` buries.

`claude#session#live()` (`:1242`) and the pickers still see everything, as
`test/session_hidden.vader` already asserts.

When rows are buried, the group says so on its last line:

```
▾ Done (10)
  ✗ merge the diff base   root · 6h
  ✗ zsh cleanup             wt · 1d
  … 8 hidden — I to show
```

---

## 7. The filter

`/` prompts for a string and stores it in `s:filter`. Every group is rebuilt
with only the rows whose label, workspace name or branch contains it, case
insensitively; a group left empty is not drawn; folded groups open while a
filter is active, because a fold that hides a match makes the filter a lie.
`/` with an empty answer, or `<Esc>`, clears it. The header shows the active
filter in place of the count:

```
Claude Sessions           /diff (2)
```

While a filter is active the §6.2 hide rule is suspended. You asked for those
rows by name; burying them would be perverse.

---

## 8. `Done`, counts and the long tail

Three separate numbers, deliberately not conflated:

| Number | Meaning | Source |
|--------|---------|--------|
| Header `N waiting` | Sessions in `Needs you` | Live status |
| Header `(N)` when none are waiting | Live sessions | `claude#session#live()` |
| `Done (N)` | Closed records **the registry holds** | `claude#session#list()` |

`Done (N)` is not 124 and this design will not pretend otherwise.
`s:transcript_paths()` (`:267`) reads only the `g:claude_panel_closed_limit`
newest transcripts per project (default 10), so the other 120 are not in the
registry, are not in the panel, and are not findable with `/`. That cap is not
changed here: reading 130 transcripts on every `refresh()` is a cost nobody has
measured. §13 carries the question.

Within `Done`, at most `g:claude_panel_done_rows` (default 10) rows are drawn,
followed by `… N more` — activating that row draws the rest for the session.
Two caps rather than one, because "how much is scanned from disk" and "how much
is drawn" are different questions that `g:claude_panel_closed_limit` currently
answers with one number.

`Done` starts folded on every panel open.

---

## 9. What the panel remembers

| State | Where | Persisted |
|-------|-------|-----------|
| Grouping (`state` / `workspace`) | `s:grouping` in `panel.vim` | No — starts on `state` |
| Fold state | `s:collapsed` (`panel.vim:31`), keyed `st:waiting`, `st:working`, `st:idle`, `st:done` in the state view and `p:` / `w:` in the place view | No, as today |
| Filter | `s:filter` in `panel.vim` | No |
| `I` | `claude#session#show_hidden()` (`session.vim:544`) | No, as today |

The two key namespaces never collide, so switching views with `g` preserves
both sets of folds. `claude#panel#_reset()` (`panel.vim:962`) clears all of it, and
seeds `st:done` folded.

**One implementation consequence.** `s:repaint()` (`panel.vim:625`) rewrites a
row's glyph in place when only a status changed. In the state view a status
change *moves the row to another group*, so that fast path is invalid: in
`state` grouping a status change must call `s:render()`. `s:repaint()` stays
for the place view, where the tree shape genuinely does not move.

---

## 10. Migration

| What exists | What happens |
|-------------|--------------|
| 130 records in `data/sessions.json` | Read unchanged. No schema change, no version bump, nothing written |
| A record whose `name` is the old `timestamp — snippet` fallback | It was never persisted (only `new()` and `rename()` write names), so it simply stops being generated |
| A persisted name matching `s:AUTO_NAME` (`session.vim:848`) | Still not a name; the record labels from its snippet instead of its id |
| 119 unnamed records | Visible with a real label while live; buried in `Done` once closed, per §6.2 |
| A record older than 2 days with a typed name | Buried too. The rule is `or`, not `and`: an old session is old whoever named it |
| Fold state, grouping, filter | In-memory, so a restart starts on the state view with `Done` folded |
| `g:claude_panel_icons` set by a user | Keeps working; the new `waiting` key falls back to `✻` when unset |

Reverting the design costs nothing on disk.

---

## 11. API

### Changed

| Function | Change |
|----------|--------|
| `claude#session#status()` (`session.vim:342`) | May return `waiting`; the idle timer becomes the fallback, not the rule |
| `claude#session#poll()` (`:411`) | Classifies the tail it already reads; adopts a snippet once per session |
| `claude#session#label()` (`:873`) | Falls back to `snippet` before the id |
| `claude#session#list()` (`:587`) | Filters by `is_buried()` instead of by `named`, and is now a filter over `all()` |
| `claude#session#refresh()` (`:450`) | Fills `snippet`; stops writing a `timestamp — snippet` fallback into `name` |
| `claude#session#tree()` (`:678`) | Optional first argument: 1 includes the buried tail |
| `s:make_record()` (`:518`) | Carries `snippet` and `scan_ftime` |
| `claude#session#new()` (`:906`) | A wrapper over `spawn()`; behaviour and signature unchanged |
| `claude#resume()` (`claude.vim:379`) | Reads `all()`, so a session you buried is still resumable — and is now labelled by its first message rather than a timestamp |
| `s:build_sources()` (`difftree.vim:250`) | Reads `all()`: a branch is diffable whether or not its session was buried |
| `claude#panel#icon()` (`panel.vim:46`) | Knows `waiting` |
| `s:build()` (`:515`) | Dispatches to one of two views |
| `s:setup_keys()` (`:659`) | Adds `g`, `/`, `N`; `n` changes meaning |
| `s:setup_syntax()` (`:198`) | A `ClaudeSessionWaiting` glyph group, and a match for the `…` note rows |
| `s:repaint()` (`:625`) | Refuses the in-place fast path in the state view (§9) |
| `claude#panel#_reset()` (`:962`) | Also clears the view, the filter and the Done expansion, and re-seeds `st:done` folded |

### New

| Name | Purpose |
|------|---------|
| `claude#session#groups([all])` (`session.vim:640`) | The four state groups: `{key, label, status, sessions, buried}`, ordered and ready to draw |
| `claude#session#is_buried(rec)` (`:560`) | The §6.2 predicate |
| `claude#session#all()` (`:579`) | The registry, sorted, with nothing hidden — for callers that are not the panel |
| `claude#session#buried_count()` (`:599`) | How many rows the hide rule is holding back, for the note under `Done` |
| `claude#session#spawn(opts)` (`:943`) | The single creation path (§5.3) |
| `s:classify(tail)` (`session.vim:323`) | §4.2 |
| `s:adopt_snippet(rec)` (`:393`) | Reads a live session's first message once its transcript appears |
| `s:row()`, `s:age()`, `s:where()`, `s:suffix()`, `s:matches()` (`panel.vim`) | §3.3 and §7 |
| `s:place_under_cursor()` (`panel.vim:773`) | The §5.1 table: `[workspace, directory]` for wherever the cursor is |
| `g:claude_panel_waiting_pat`, `g:claude_panel_working_pat` | §4.2 |
| `g:claude_panel_stale_days` (2) | §6.2 |
| `g:claude_panel_done_rows` (10) | §8 |
| `claude#session#_classify()`, `claude#panel#_grouping()`, `claude#panel#_filter()` | Test seams, alongside the existing `_inject` / `_lines` / `_reset` |

### Removed

Nothing. `claude#session#tree()` is the `g` view and keeps its shape.

---

## 12. Test plan

Written and passing: **466 tests / 1002 assertions**, from 393 / 858. No
existing assertion was deleted to make the new shape pass; the ones that
changed are listed as such.

| File | What it covers |
|------|----------------|
| New: `test/session_state.vader` | The classifier against captured tails — spinner, numbered choice, yes/no, an empty prompt box, text matching neither; working outranking a stale question; both patterns overridden. Then end to end: a stand-in that prints a permission prompt at the bottom of a real terminal is read as `waiting`, and one that prints nothing falls back to the idle timer |
| New: `test/panel_groups.vader` | Group order and counts, empty groups dropped, the waiting glyph in both glyph sets, the header's `N waiting`, the 35-column row with its suffix, `Done` folded on open, the `done_rows` cap and its `… N more`, the `… N hidden — I to show` note, and `Done` drawn even when every row in it is buried |
| New: `test/panel_filter.vader` | `/` matching label, branch and workspace; empty groups dropped; folds opened; the hide rule standing down; `(nothing matches)`; the header; clearing; surviving a redraw; cleared by a reset |
| New: `test/panel_grouping.vader` | `g` swapping both ways, the two indents vs six, the header following across, each view keeping its own folds through a round trip, and what a reset restores |
| New: `test/session_label.vader` | Name > snippet > id; the snippet read from a transcript; the timestamp fallback gone; a stored name still winning; an auto `claude <date>` name dropped in favour of the first message; two identical snippets disambiguated |
| `test/session_hidden.vader` | **Changed**: the `I` assertions move from "unnamed anywhere" to "buried in Done" — an unnamed *live* session is now listed, and `all()` still sees what `list()` hides. A new section covers the staleness rule, including `stale_days = 0` |
| `test/panel_render.vader` | **Changed**: the four place-shaped tests ask for the place view first; the duplicate-label test reads rows rather than a bare line, since rows now carry a suffix |
| `test/panel_keys.vader` | **Changed**: `I` is tested on finished sessions, and the help text now reads `I show hidden`. New: `n` asking for a name and nothing else, a blank answer leaving it unnamed, `g:claude_session_prompt_name = 0` skipping the question, `N` mapped to the prompting path, and the new session being the one you land in |
| `test/session_workspace.vader` | **Changed**: an unnamed live session is listed and only buried once it ends; the transcript case asserts `snippet` rather than a name. New: `n` inheriting the workspace of the row under the cursor — from a session row, a branch row, a worktree row and the project row alike — a session with no workspace of its own still landing in its worktree, and the fall back to the selected workspace with no row to read |
| `test/session_registry.vader`, the rest | Unchanged, re-run as regression guards |

---

## 13. Open questions

- **Should `claude agents --json` back a fifth state?** It reports sessions
  this Vim does not own the terminal of, which `claude#session#is_foreign_active()`
  (`:1003`) currently infers from a transcript's mtime. A `Running elsewhere`
  group is defensible; a shelled-out command every 2 seconds is not obviously
  worth it.
- **Should the scan cap rise so `/` can reach all 130?** Filtering a registry
  that holds 10 of 130 closed sessions is honest but thin. The cost is 130
  reads of 60 lines per `refresh()`, unmeasured.
- **Should `Needs you` sort by wait time rather than by focus?** The oldest
  unanswered question is arguably the most urgent, and `s:cmp_records()`
  (`:494`) does not know how long a session has been waiting.
- **Is `2` the right number of days?** It was chosen, not derived. A week of
  use should settle it.
- **`g` shadows `gg`.** The key came from the proposals doc and from Claude
  Code's own toggle, but a bare `g` mapping means `gg` no longer goes to the
  top of the panel: the first `g` swaps the view and the second swaps it back.
  Mapping `gg` as well would make every `g` wait for `timeoutlen`. `1G` and `G`
  still work. If this grates, `<C-g>` is free.
- **Proposal C's numbered slots.** `1`–`9` jumping to a pinned session composes
  with this design — the rail would be a fifth group above `Needs you`. Left
  out until pinning is something anyone asks for.
