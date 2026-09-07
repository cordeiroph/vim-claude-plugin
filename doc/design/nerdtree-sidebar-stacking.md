# Design: stacking the session panel with NERDTree

Status: proposed
Target: `claude.vim`
Last updated: 2026-09-07

---

## 1. Summary and motivation

The session panel and NERDTree are both left-anchored vertical splits, and
neither knows about the other. `s:panel_split_cmd()`
(`autoload/claude/panel.vim`) returns `topleft vertical 35split`; NERDTree's
`lib/nerdtree/creator.vim:208-210` builds `topleft vertical <g:NERDTreeWinSize>split`.
Whichever opens second claims the screen edge and pushes the other aside, so
both end up as separate columns:

```
measured, panel opened while NERDTree was already open:
  row[ PANEL(69x43)  FAKE(31x43)  main(68x43) ]
                                  ^^^^^^^^^^^ only 68 of 170 columns left for code
```

Two sidebars eat ~100 columns before any code is visible, and the order they
appear in depends on which was opened first.

This design puts them in **one shared column**, split horizontally, with the
Claude session panel always on top:

```
  row[ col[ PANEL(31x15)
            NERD(31x27) ]  main(138x43) ]
```

The two stay completely independent: either can be opened, closed or toggled
without disturbing the other. The only coupling is geometric.

---

## 2. Goals / Non-goals

### Goals

- When both the session panel and NERDTree are visible in a tab, they occupy a
  single column, panel above NERDTree, regardless of which opened first.
- The panel takes a fixed height (`g:claude_panel_height`); NERDTree takes the
  remaining lines and absorbs any resize.
- Closing either one leaves the other exactly as it was, minus the geometry.
- With NERDTree absent, not loaded, or stacking disabled, behaviour is
  byte-for-byte what it is today.

### Non-goals

- **Claude terminal sessions are not involved.** They keep opening in the main
  area through `claude#split_cmd()`; `g:claude_split_anchor` and
  `g:claude_split_size` are untouched.
- No generic sidebar framework. This integrates with NERDTree specifically.
  tagbar, coc-explorer, netrw and friends are out of scope (§9).
- No attempt to make NERDTree itself aware of the panel, and no changes under
  `~/.vim/bundle/nerdtree`.
- No cross-tab coordination beyond §6.

---

## 3. Evaluation

Everything below was measured, not assumed. Vim 9.1 on macOS, 170x45.

### 3.1 What works

| Question | Finding |
|----------|---------|
| Can a window be moved into NERDTree's column? | **Yes.** `win_splitmove(panel, nerd, {'vertical': v:false, 'rightbelow': v:false})` turns `row[PANEL FAKE main]` into `row[col[PANEL FAKE] main]` — the exact target — with the panel on top. |
| Can a horizontal split be made directly inside the column? | **Yes.** Moving to NERDTree's window and running `leftabove 15split` yields `row[col[…] main]`. |
| Does a fixed panel height hold? | **Yes.** `resize 15` + `winfixheight` gives `col[PANEL(31x15) NERD(31x27)]`, and NERDTree absorbs subsequent resizes. |
| Is NERDTree closing detectable? | **Yes.** `WinClosed` fires with the window id (`WinClosed:1001`). |
| Does the panel reclaim the column afterwards? | **Yes, automatically.** After the sidebar window closed, the layout collapsed to `row[PANEL(31x43) main]` with no intervention. |

### 3.2 What the measurements force us to accept

- **NERDTree wins the column width.** After `win_splitmove` the shared column
  was 31 columns — `g:NERDTreeWinSize` — not the panel's 35, despite the panel
  having `winfixwidth`. Fighting this is a losing game: NERDTree re-asserts
  `vertical resize g:NERDTreeWinSize` on its own renders
  (`lib/nerdtree/ui.vim:545`), so any width we impose would be undone on the
  next NERDTree redraw. **Decision:** while stacked, the column is NERDTree's
  width and `g:claude_panel_width` does not apply. It still governs the
  standalone panel.
- **Heights split evenly on the move.** `win_splitmove` produced 21/21; the
  fixed height must be applied explicitly afterwards.
- **NERDTree fires no close event.** It emits only `User NERDTreeInit` and
  `User NERDTreeNewRoot` (`lib/nerdtree/creator.vim:32`,
  `lib/nerdtree/nerdtree.vim:31`). Close must be caught with `WinClosed`.

### 3.3 What could not be verified headlessly

NERDTree cannot be driven from a scripted Vim reliably. `silent NERDTree`
deadlocks outright, and `execute 'NERDTree'` inside a function deadlocks too;
even a bare top-level `NERDTree` frequently failed to return within 10s under a
pty. Every mechanism above was therefore verified against a **stand-in
sidebar** — a `topleft vertical 31split` scratch buffer with `winfixwidth`,
which is structurally what NERDTree creates.

Two behaviours consequently rest on reading NERDTree's source rather than on
measurement, and are called out as risks:

1. That `User NERDTreeInit` fires late enough for the repair to run. Reading
   `creator.vim:91-96` settles this: `_broadcastInitEvent()` is the last
   statement of `createTabTree()`, after `_createTreeWin()`, `_createNERDTree()`,
   `render()` and `putCursorHere()`, so the window is fully built when the hook
   runs and the move can be made synchronously.
2. What NERDTree does when reopened while the panel already holds the column.
   `creator.vim:208` runs an unconditional `topleft vertical` split, so it will
   create a **new column** rather than joining the panel's; the repair pass
   (§4.2) is what puts them back together, which is why the design is built
   around repair rather than around placing windows correctly up front.

This flakiness directly shapes the test plan (§8): the suite stubs NERDTree's
API instead of running it.

### 3.4 Version requirements

| Feature | Needed since | Behaviour when missing |
|---------|--------------|------------------------|
| `win_splitmove()` | Vim 8.1.1140 | Stacking disabled entirely; today's side-by-side behaviour |
| `WinClosed` | Vim 8.2.3100 | Fall back to the panel's existing refresh timer to notice NERDTree has gone |
| `winlayout()` | Vim 8.1.0631 | Only used by tests |

The plugin's floor stays Vim 8.1 + `+terminal`; stacking is a capability that
switches itself off on older builds.

### Verdict

**Feasible, with one accepted compromise.** Every required primitive exists and
was measured working. The compromise is the column width: while stacked, the
sidebar is NERDTree's width, not the panel's. The main risk is not the geometry
but the *trigger* — reacting to NERDTree opening — because NERDTree offers only
an init hook and no close hook, and cannot be exercised in automated tests.

---

## 4. Window-management strategy

One idempotent repair function, `s:stack()`, is the whole mechanism. It is
called at every moment the layout may have gone wrong, and does nothing when
the layout is already right.

```
s:stack():
  return early unless   g:claude_panel_nerdtree_stack
                        exists('*win_splitmove')
                        exists('g:NERDTree')
                        the panel is open in the current tab
                        NERDTree is open in the current tab
                        both are in the same tab
  if already stacked (same column, panel above)  -> just re-apply the height
  win_splitmove(panel_win, nerd_win, {'vertical': v:false, 'rightbelow': v:false})
  apply g:claude_panel_height + winfixheight to the panel window
```

### 4.1 Detecting "already stacked"

Compare the parent node in `winlayout()`: both windows are stacked when they
are leaves of the same `col` node, adjacent, with the panel first. Testing
this rather than blindly moving keeps `s:stack()` cheap and idempotent, so it
is safe to call from a timer.

### 4.2 Call sites

| Moment | Hook |
|--------|------|
| Panel opens while NERDTree is up | `claude#panel#open()`, **before** the transcript scan and first render — those are slow enough that Vim could otherwise redraw the unstacked layout first |
| NERDTree opens while the panel is up | `autocmd FileType nerdtree`, **synchronously** — see §4.4. `autocmd User NERDTreeInit` stays wired as a second chance |
| NERDTree closes | `autocmd WinClosed` → drop `winfixheight` from the panel so it reclaims the column (the layout collapse itself is automatic) |
| Anything else disturbs the layout | The panel's existing status-poll timer calls `s:stack()`, which is a no-op when the layout is already correct |

Both open paths must therefore complete the move before control returns to
Vim's main loop. Anything that yields — a timer, or a slow call made before the
move — shows the user a frame of two side-by-side columns that then jump
together.

`win_splitmove()` does not change the current window, but the move is wrapped
in a save/restore of `win_getid()` anyway so `:NERDTree` leaves the cursor in
NERDTree, where the user expects it.

### 4.4 Hook timing, and why it is `FileType`

Measured, with the panel already open and `:NERDTree` invoked:

```
WinNew        14.0 ms   layout = row[1002, 1001, 1000]   three columns already
BufWinEnter   18.5 ms   layout = row[1002, 1001, 1000]
BufWinEnter NERD_tree_tab_1   23.6 ms
NERDTreeInit  — did not fire within 12 s
```

NERDTree's window exists as its own column from the moment
`Creator._createTreeWin()` splits. `User NERDTreeInit` is the **last** statement
of `createTabTree()`, after `_createNERDTree()` and `render()` — and with
`nerdtree-git-plugin` installed, `render()` runs git status calls. Repairing
there is far too late: Vim has painted two columns and the user sees them jump
together.

`setlocal filetype=nerdtree` is the last line of `_setCommonBufOptions()`,
which is the last call in `_createTreeWin()`. So `FileType nerdtree` fires
**after NERDTree has created and sized its window, but before it builds or
renders the tree** — the earliest moment the window can be identified, and
before the slow part that gives Vim a chance to redraw.

This forces two things:

- The window lookup cannot use `g:NERDTree.ExistsForTab()`, which tests
  `b:NERDTree` — that is not set until `_createNERDTree()` runs, after our
  hook. `s:nerdtree_winid()` therefore resolves `t:NERDTreeBufName` through
  `bufwinnr()` directly, which is set before the split and is also what
  `IsOpen()`/`GetWinNum()` use.
- The cursor must be restored after the move, because NERDTree is mid-way
  through building itself and everything after `_setCommonBufOptions()` runs
  against the current window.

**Residual limitation.** The repair still cannot run *before* NERDTree's window
exists, so this narrows the window for a visible flash rather than closing it
by construction. Only driving the whole sequence ourselves — opening NERDTree
first and splitting the panel into its column — removes the intermediate state
entirely (§9).

### 4.3 Order enforcement

`win_splitmove()` with `'rightbelow': v:false` always places the moved window
*above* the target, so "panel on top" needs no extra logic — it is a property
of the move, applied identically no matter which window opened first.

---

## 5. Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `g:claude_panel_height` | `15` | Panel height in lines while stacked with NERDTree |
| `g:claude_panel_nerdtree_stack` | `1` | `0` disables stacking; the panel and NERDTree keep their own columns |

`g:claude_panel_width` keeps its meaning for a standalone panel and is ignored
while stacked (§3.2). `g:claude_panel_anchor` is also ignored while stacked —
the column is wherever `g:NERDTreeWinPos` puts it.

---

## 6. Changed functions

All in `autoload/claude/panel.vim` unless noted.

| Function | Change |
|----------|--------|
| `s:stack()` | **New.** The repair pass of §4 |
| `s:is_stacked()` | **New.** The `winlayout()` test of §4.1 |
| `s:nerdtree_winid()` | **New.** `win_getid(g:NERDTree.GetWinNum())` for the current tab, guarded by `exists('g:NERDTree')` and `g:NERDTree.IsOpen()`; `-1` otherwise |
| `s:apply_stacked_height()` | **New.** `resize g:claude_panel_height` + `setlocal winfixheight` |
| `claude#panel#open()` | Calls `s:stack()` after rendering |
| `claude#panel#close()` | Unchanged in effect; NERDTree keeps the column |
| `s:tick()` | Also calls `s:stack()`, making the timer the backstop |
| `s:enter_main()` | **Must skip the NERDTree window as well as the panel** when choosing where a session opens, or `i`/`s` would split NERDTree instead of the main area |
| `claude#panel#_reset()` | Also clears any stacking state (test seam) |
| `claude#_quit_pre()` (`autoload/claude.vim`) | Excludes the NERDTree window from the "ordinary windows" count, as it already does for the panel — otherwise a sidebar keeps `:q` from being recognised as the last real window |
| `plugin/claude.vim` | Adds the two options of §5 and the `User NERDTreeInit` / `WinClosed` autocommands to the `claude_plugin` augroup |

---

## 7. Ordering matrix

| Sequence | Result |
|----------|--------|
| Panel, then NERDTree | `NERDTreeInit` fires → deferred `s:stack()` → `col[PANEL NERD]` |
| NERDTree, then panel | `claude#panel#open()` calls `s:stack()` → `col[PANEL NERD]` |
| Stacked, close NERDTree | Column collapses automatically; panel reclaims full height, `winfixheight` cleared |
| Stacked, close panel (`q`) | NERDTree keeps the column at full height; no session is affected |
| Stacked, reopen panel | `s:stack()` puts it back on top |
| Stacked, NERDTree reopened after being closed | `NERDTreeInit` fires again → re-stacked |
| Panel in tab 1, NERDTree in tab 2 | No stacking; each tab is judged on its own |
| Stacking disabled | Two columns, exactly as today |

---

## 8. Edge cases

| Case | Behaviour |
|------|-----------|
| NERDTree not installed | Every hook is guarded by `exists('g:NERDTree')`; the plugin behaves as today |
| `win_splitmove()` unavailable (Vim < 8.1.1140) | Stacking silently disabled |
| `WinClosed` unavailable (Vim < 8.2.3100) | The poll timer notices NERDTree has gone on its next tick |
| `g:NERDTreeWinPos = 'right'` | The column is on the right; stacking still applies, panel still on top |
| NERDTree is the only window | `s:enter_main()` creates the main area via `claude#split_cmd()`, as it already does when the panel is alone |
| Panel and NERDTree already stacked | `s:stack()` re-applies the height and returns; no window churn |
| User manually rearranges the windows | The next timer tick re-stacks. Documented, since it overrides deliberate manual layout — `g:claude_panel_nerdtree_stack = 0` is the escape hatch |
| NERDTree opens in a tab with no panel | Nothing happens |
| Panel height exceeds the column | `resize` clamps; NERDTree keeps at least one line |

---

## 9. Future work

- **A combined open/close command** driving both windows as a unit: open
  NERDTree first, then split the panel into its column. Measured to produce
  `row[col[PANEL(31x15) TREE(31x27)] main]` in one step with no intermediate
  layout, so it is flash-free by construction rather than by narrowing a race.
  It would also let the poll-timer backstop be dropped. It cannot help when
  NERDTree is opened by its own command, which is what §4.4 covers.
- Generalise to any sidebar via a configurable buffer/filetype list — tagbar
  and coc-explorer are both installed here and have the same collision.
- Let the panel size itself to its content up to a cap, instead of a fixed
  height.
- Reconcile widths properly if NERDTree ever stops force-resizing itself.

---

## 10. Test plan

NERDTree cannot be driven headlessly (§3.3), so the suite does not try.

| File | Covers |
|------|--------|
| `test/panel_stack.vader` | `s:is_stacked()` against fabricated `winlayout()` shapes; `s:stack()` moving the panel above a **stand-in sidebar** and applying the height; idempotency (a second call changes nothing); order enforcement independent of which opened first; height reclaimed when the sidebar closes; `s:enter_main()` skipping the sidebar window; that the init hook stacks **synchronously** (asserted with no intervening `sleep`) and leaves the cursor where it was |
| `test/panel_stack_absent.vader` | With `g:NERDTree` undefined, and again with `g:claude_panel_nerdtree_stack = 0`, the panel opens exactly as it does today — the regression guard for everyone not using NERDTree |

The stand-in is the one from §3.3: `topleft vertical 31split` + scratch buffer
+ `winfixwidth`, which reproduces NERDTree's window structure. NERDTree's own
API is stubbed by defining `g:NERDTree` with `IsOpen()`/`GetWinNum()` and
setting `t:NERDTreeBufName`, so the detection paths are exercised without
running the plugin.

**What this does not prove:** that `User NERDTreeInit` fires at a usable
moment, and that real NERDTree tolerates being moved by `win_splitmove`. Both
need a manual check against the real plugin before the feature is considered
done.
