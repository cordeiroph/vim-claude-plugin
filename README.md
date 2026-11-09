# claude.vim

A Vim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you persistent AI sessions alongside your code.

Run as many sessions as you like, name them, and switch between them from a NERDTree-style side panel grouped by what they're doing or by the room they run in. A room is a git worktree of its own — on its own branch, inside the project — and can be split into sub-rooms, so several agents can work side by side without sharing a checkout.

## Requirements

- Vim 8.1+ (with `+terminal`)
- The `claude` CLI on your `$PATH`
- Optional: the [`pi`](https://github.com/earendil-works/pi) CLI, to run Pi
  sessions alongside Claude ones — see [Choosing an agent](#choosing-an-agent)

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'cordeiroph/claude.vim'
```

Or copy `plugin/claude.vim`, `autoload/claude.vim`, and `autoload/claude/` into your plugin directory manually.

## Usage

| Mapping | Command | Action |
|---------|---------|--------|
| `<leader>co` | `:ClaudeOpen` | Focus a session, starting one if none is running |
| `<leader>cn` | `:ClaudeNew` | Start a session even when others are already running |
| `<leader>pn` | `:PiNew` | Start a session on Pi rather than the default agent |
| `<leader>cs` | `:ClaudeSessions` | Toggle the session panel |
| `<leader>cw` | `:ClaudeRooms` | Choose the room (git worktree) to work in |
| `<C-a>` | `:ClaudeSidebars` | Raise or dismiss the whole sidebar column |
| `<leader>ct` | `:ClaudeToggle` | Show/hide a Claude window |
| `<leader>cx` | `:ClaudeClose` | End a session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to a Claude window (enters insert mode) |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Toggle the input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |
| — | `:SessionPanelHookSetup` | Install the status hooks into the current folder |

`:ClaudeNew [name]` starts an extra session, and `:ClaudeRename [name]` renames one. When several sessions are running, commands that need just one show a picker; when only one is running, it is used without prompting.

Starting a session without naming it on the command line asks which room it goes in first — an existing one, or a new room or sub-room — see [Rooms](#rooms).

Inside the Claude terminal, press `<Esc><Esc>` to enter terminal-normal mode (so Vim handles the cursor and mouse). Single `<Esc>` is passed through to Claude.

## Input window

`<leader>ci` toggles a dedicated buffer for writing long, multi-line prompts. It opens as a 10-line split at the bottom. Pressing `<leader>ci` again discards the content and closes the window. To preserve your text, press `<C-c>` instead — it saves a draft and hides the window; reopening restores it.

The buffer is a `.md` file, so syntax highlighting and Copilot completions work out of the box.

| Key | Action |
|-----|--------|
| `<C-s>` (insert or normal) | Send the message and close the window |
| `<C-c>` (normal) | Save draft and hide the window |
| `q` (normal) | Discard draft and close |

Type `/` to trigger slash-command completion. Type `@` to complete file paths or agent names — file completions require [`rg`](https://github.com/BurntSushi/ripgrep) on your `$PATH` and support basename matching (e.g. `@cla` matches `doc/claude.txt`).

Claude is opened automatically if no session is running.

## Configuration

All settings are optional. Add them to your `vimrc`:

```vim
" Which edge the Claude window appears on: 'right' (default), 'left', 'top', 'bottom'
let g:claude_split_anchor = 'right'

" Width (columns) for left/right splits, height (lines) for top/bottom splits
let g:claude_split_size = 80

" Shell command used to launch Claude
let g:claude_cmd = 'claude'

" Share one column with NERDTree (panel on top); 0 keeps separate columns
let g:claude_panel_nerdtree_stack = 1

" Sidebar column heights, as a percentage of the screen. NERDTree takes the
" rest. Set a percentage to 0 to size that sidebar in lines instead.
let g:claude_panel_height_pct = 25
let g:claude_difftree_height_pct = 40
let g:claude_panel_height = 15
let g:claude_difftree_height = 15

" Key that raises or dismisses the whole sidebar column; '' leaves it unmapped
let g:claude_sidebar_toggle_key = '<C-a>'

" Session panel: width, edge, and how often status is polled while it is open
let g:claude_panel_width = 35
let g:claude_panel_anchor = 'left'
let g:claude_panel_refresh_ms = 2000

" Seconds of silence before a running session is shown as idle. Only consulted
" when the bottom of the terminal says nothing conclusive:
let g:claude_panel_idle_secs = 30

" Optional agent-hook state files, which report work a terminal never prints
" (a subagent, a background task outliving its turn). Disabled by default, and
" nothing writes them until :SessionPanelHookSetup installs the writers into
" the project; terminal patterns and the idle timer classify until then.
let g:claude_panel_hook_state = 1
" Empty follows the writer: $XDG_RUNTIME_DIR/claude-vim-status, else /tmp.
let g:claude_panel_hook_state_root = ''
" A backstop for a writer that died mid-state, not a freshness window.
let g:claude_panel_hook_state_ttl_secs = 900

" What the bottom of a Claude terminal looks like while it works, and while it
" waits for you. The second is what fills the panel's "Needs you" group.
let g:claude_panel_working_pat = 'esc to interrupt'
let g:claude_panel_waiting_pat = '\%(^\|\n\)\s*❯\=\s*1\.\s\|Do you want\|(y/n)'

" Days before a finished session drops out of the panel, and how many finished
" ones the Done group draws before it stops with a "… N more" row
let g:claude_panel_stale_days = 2
let g:claude_panel_done_rows = 10

" Where session names are stored. Empty = data/sessions.json inside the plugin
" directory, which a plugin update will wipe. Point it elsewhere to keep names.
let g:claude_session_store = ''

" 0 = don't prompt for a name when starting a session
let g:claude_session_prompt_name = 1

" Models shown in the :ClaudeModel picker
let g:claude_models = [
      \ 'claude-opus-4-7',
      \ 'claude-sonnet-4-6',
      \ 'claude-haiku-4-5-20251001',
      \ ]

" Set to 1 to disable all default mappings
let g:claude_no_default_mappings = 0

" Where rooms (git worktrees) are checked out. Empty means .vim-workspace
" inside the project; an absolute path keeps them outside it.
let g:claude_room_dir = ''

" Fetch the default branch before cutting a new room from it.
let g:claude_room_fetch = 1

" Where rooms are remembered. Empty means data/rooms.json inside the plugin
" directory.
let g:claude_room_store = ''
```

## Session panel

`<leader>cs` toggles a panel listing every session — the ones running now and the ones you can resume. It has two views, swapped with `g`.

**By state**, which is what it opens on. With several agents running the question is almost always *which one is waiting for me?*, and only this view answers it without being asked:

```
Claude Sessions           2 waiting

▾ Needs you (2)
  ▾ panel
    ✻ pick a diff base          2m
    ✻ icon set [icons]          5m
▾ Working (1)
  ▾ claude-plugin (root)
    ● panel rework              1m
▾ Idle (1)
  ▾ claude-plugin (root)
    ○ user_interface            2h
▸ Done (10)
```

Inside each group, sessions sit under their room; a sub-room's sessions sit with its room, tagged with its name.

**By place** — project, room, sub-room — for when the question really is what is happening in that room. Every room is listed, with sessions or without, so this view doubles as the room list:

```
Claude Sessions           2 waiting

▾ claude-plugin
  ▾ claude-plugin (root) — main
    ● panel design             1m
  ▾ panel
    ✻ pick a diff base         2m
    ▾ icons
      ✻ icon set               5m
    ▾ layout
  ▾ difftree — feature/git-diff-tree
    ✗ review pass              2d
```

Each view keeps its own folds, so swapping back and forth loses neither.

`✻` waiting for you, `●` working, `○` idle, `✗` closed but resumable.

Waiting and working are read from the bottom rows of the session's terminal, where Claude prints its own state — a spinner while it works, a numbered list while it asks. Both are patterns you can change (`g:claude_panel_waiting_pat`, `g:claude_panel_working_pat`); when neither matches, the idle timer decides, as it did before.

### Work the terminal cannot see

A subagent, or a background task that outlives the turn that started it, prints nothing — so the tail alone puts that session in Idle. The agents can say so themselves: `:SessionPanelHookSetup` installs the bundled writers into the folder you are in (Claude Code's hook into `.claude/`, Pi's extension into `.pi/extensions/`), and `g:claude_panel_hook_state = 1` lets the panel read what they write.

It writes only under the current directory, and running it twice changes nothing: a correct copy is left alone, an already-registered handler is not registered again, and a settings file it cannot parse is refused rather than replaced. `examples/hooks/README.md` has the event table, the manual install for every project, and the removal steps.

Records are evidence, never authority: a dead session can never be listed as alive, a record that asks for attention while the terminal says the session is working loses to the terminal, and anything stale, foreign or malformed leaves the patterns deciding exactly as they do today.

`Done` starts folded, draws at most `g:claude_panel_done_rows` rows with a `… N more` for the rest, and hides the sessions nobody named or nobody has touched for `g:claude_panel_stale_days` days. It says how many it is hiding; `I` reveals them.

`/` filters every group by label, room or branch. Groups left empty are dropped, folds that hid a match are opened, and the hidden tail is searched too — a row you asked for by name is not a row to hide.

The panel uses NERDTree's palette — group nodes coloured like directories, session names like files — so the sidebar reads as one thing. Where NERDTree's highlight groups exist they are used directly, so restyling NERDTree restyles the panel. Override `ClaudeSessionProject`, `ClaudeSessionBranch`, `ClaudeSessionName`, `ClaudeSessionActive` and friends to restyle just the panel; a link you set is never overwritten.

| Key | Action |
|-----|--------|
| `<CR>` / `o` | Open the session, or fold a group |
| `i` | Open in a horizontal split |
| `s` | Open in a vertical split |
| `t` | Open in a new tab |
| `n` | Start a session where the cursor is, asking only its name |
| `N` | Start a session, asking for a branch and then a name |
| `g` | Swap the top level: state ⇄ place |
| `/` | Filter every group |
| `r` | Rename |
| `d` | End the session (transcript kept, so it stays resumable) |
| `D` | Purge the session and delete its transcript |
| `R` | Rescan transcripts |
| `I` | Show or hide the buried sessions |
| `<Space>` / `za` | Fold or unfold |
| `q` | Hide the panel |
| `?` | Toggle the inline key reference |

Hiding the panel never stops a session. Status is polled only while the panel is visible.

Claude only writes a conversation to disk once it has content, so a session you started but never messaged has nothing to resume. Opening one of those claims its id for a fresh conversation rather than failing — the name and id are kept.

### Sharing a column with NERDTree

The panel and NERDTree would otherwise form two columns and swallow most of the screen. When both are open they share one column, panel on top:

```
+----------------+---------------------------+
| Claude Sessions|                           |
+----------------+   your code               |
| NERDTree       |                           |
+----------------+---------------------------+
```

It works whichever opens first, and closing either one hands the column to the other. The column is sized by percentage of the screen — the session panel takes `g:claude_panel_height_pct` (25), the diff tree `g:claude_difftree_height_pct` (40), and the bottom-most sidebar (NERDTree, when it is installed) absorbs the remaining 35%; zero either percentage to go back to a height in lines. Resize any of them by hand and it stays put, since the sizes are applied only when the sidebars first come together.

`<C-a>` (`:ClaudeSidebars`) raises all three at once and dismisses them again once they are all showing. It is mapped in normal mode only, so `<C-a>` still increments a number under the cursor from a terminal buffer, from insert mode, and in visual mode; rebind or disable it with `g:claude_sidebar_toggle_key`. While stacked the column is NERDTree's width, since NERDTree resets its own width on every redraw. Set `g:claude_panel_nerdtree_stack = 0` to opt out.

### Git diff tree

`<leader>cd` opens a tree of every file that differs from the base branch — committed and uncommitted together — grouped by worktree and directory:

```
Git Diff                      main

▾ claude-pluing
  ▾ main
    ▾ autoload/claude
      [✚|✹] difftree.vim
      [✚]   panel.vim
      [ |✭] scratch.vim
    ▾ doc
      [✹]   claude.txt
  ▾ hotfix/e947 (wt-hotfix)
    ▾ autoload/claude
      [✹]   input.vim
  ▾ feature/agent-session-panel (no worktree)
    ▾ autoload/claude
      [✚]   session.vim
      [✚]   sidebar.vim
```

One row per **branch**, directly under the project. A worktree holds exactly one branch, so it never needs a level of its own — it is named in the label instead:

| Label | Meaning |
|---|---|
| `main` | checked out in the repository's main worktree |
| `hotfix/e947 (wt-hotfix)` | checked out in a linked worktree of that name |
| `feature/x (no worktree)` | has commits but no checkout anywhere — committed changes only |

[Rooms](#rooms) are drawn the way they sit on disk instead, after your own branch: the room, its worktree folder, then each sub-room and its folder. A room diffs against what it was cut from, a sub-room against its room:

```
▾ panel/
  ▾ claude-plugin/        room/panel vs origin/main
    ▸ autoload/
  ▾ icons/
    ▾ claude-plugin/      room/panel--icons vs room/panel
      ▸ autoload/
```

The branch you are actually sitting on comes first. It is what shows *your* uncommitted work: a branch has no committed changes against itself, so on the base branch every other rule would skip your checkout and the panel would come up empty. When a branch is the base, the committed half is compared against its upstream instead, so unpushed commits still show. A row disappears when it has nothing to report.

Branch names are **yellow**, except a branch with no remote-tracking branch — work that exists only on your machine — which is **grey**. In the status glyphs, added is **green** and removed is **red**, taken from your `DiffAdd` and `DiffDelete` colours.

Each branch can diff against a base of its own: press `b` on a branch row to set it, or clear it with an empty answer. The choice persists across Vim restarts in `g:claude_difftree_store`, keyed by repository. `B` sets a session-wide default for branches with no base of their own. A branch on a non-default base shows it in brackets: `[feature/alpha] feature/delta (beta)`.

The branches listed are the union of every worktree, every branch a Claude session has run on (live or closed, taken from the session registry), and the branch you are on now. That is the point: a branch Claude worked on stays visible after you move off it. A branch no longer checked out anywhere is listed under the project beside the branch that *is* checked out there, marked `(no worktree)` and dimmed. It shows **committed changes only** — with no working tree there is nothing to be dirty, so its second indicator slot is always blank.

Each row carries a bracketed field with **two slots**. The first says what the branch did to the file relative to the base; the second what the working tree has done since:

| Field | Meaning |
|---|---|
| `[✚]` | added on this branch, clean in the working tree |
| `[✹]` | modified on this branch, clean in the working tree |
| `[ \|✹]` | untouched by the branch, modified in the working tree |
| `[✚\|✹]` | added on this branch **and** modified since |
| blank | neither |

The empty slot is kept when only the working tree changed — a lone `[✹]` could not say which of the two slots it came from.

The glyphs come from [nerdtree-git-plugin](https://github.com/Xuyuanp/nerdtree-git-plugin), so the diff tree and NERDTree describe git state in the same alphabet:

| Column | Git letter | Status | Glyph | ASCII | Colour source |
|---|---|---|---|---|---|
| branch vs base | `A` | Staged | `✚` | `+` | `NERDTreeGitStatusStaged` → `Function` |
| branch vs base | `M` | Modified | `✹` | `*` | `NERDTreeGitStatusModified` → `Special` |
| branch vs base | `D` | Deleted | `✖` | `D` | `NERDTreeGitStatusDeleted` → `Operator` |
| branch vs base | `R` `C` | Renamed | `➜` | `R` | `NERDTreeGitStatusRenamed` → `Title` |
| working tree | `M` | Modified | `✹` | `*` | `NERDTreeGitStatusModified` → `Special` |
| working tree | `A` | Staged | `✚` | `+` | `NERDTreeGitStatusStaged` → `Function` |
| working tree | `D` | Deleted | `✖` | `D` | `NERDTreeGitStatusDeleted` → `Operator` |
| working tree | `R` `C` | Renamed | `➜` | `R` | `NERDTreeGitStatusRenamed` → `Title` |
| working tree | untracked | Untracked | `✭` | `!` | `NERDTreeGitStatusUntracked` → `Comment` |
| either | — | none | blank | blank | — |

`A → Staged` is nerdtree-git-plugin's own rule (`x =~# '[MA]'`), not an invention here.

If the plugin is installed, its `gitstatus#getIndicator()` is called directly, so `g:NERDTreeGitStatusUseNerdFonts` and any `g:NERDTreeGitStatusIndicatorMapCustom` you set carry over automatically. Without it, an embedded copy of its defaults is used. `g:claude_panel_ascii` selects its ASCII set.

Colours prefer the plugin's own `NERDTreeGitStatus*` groups when its syntax file has been sourced, falling back to the groups it links them to — so restyling one restyles the other. A link you set yourself is never overwritten.

> **Limitation:** the tree uses `git diff --name-status`, not `git status --porcelain`, so staged-but-uncommitted work cannot be told apart from unstaged (both show `✹`/`✚` by letter, not by index state), and `═ Unmerged` never appears. Ignored and clean files are not listed at all.

### Session names

New sessions prompt for a name, which is passed to the Claude CLI too, so it shows up in Claude's own prompt box and `/resume` picker. Names are stored in `data/sessions.json` inside the plugin directory.

> **Note:** a plugin update or reinstall (`:PlugUpdate`, `:PlugClean`, deleting the bundle directory) deletes that file and every session name with it. To keep names across updates, set `g:claude_session_store` to a path outside the plugin, e.g. `expand('~/.claude/vim-sessions.json')`.

## Choosing an agent

Sessions can run Claude or [Pi](https://github.com/earendil-works/pi). Everything else is the same for both: the panel lists them together, names and resumes them the same way, and a room can hold one of each.

```vim
" Which CLI a new session runs by default
let g:claude_provider = 'claude'

" Per-agent overrides, merged over the defaults
let g:claude_providers = {'pi': {'cmd': 'pi --thinking high'}}
```

| | |
| --- | --- |
| `<leader>pn`, `:PiNew [room:] [name]` | Start a Pi session, whatever the default is |
| `<leader>cn`, `:ClaudeNew [room:] [name]` | Start one on the default agent |
| `N` in the panel | Asks which agent, then which workspace, then the name |
| `n` in the panel | Asks nothing, and runs the agent the cursor is on |

A row shows which agent it is running only while the panel is listing more than one, so a Claude-only panel reads exactly as it did. `/pi` filters to Pi sessions.

Claude keeps its own settings under the names it always had — `g:claude_cmd`, `g:claude_models`, `g:claude_panel_working_pat`, `g:claude_panel_waiting_pat` — and a `vimrc` that sets none of the new options behaves exactly as before.

> **Note:** `:ClaudeModel` offers a numbered list only when the agent has one. Pi ships none, so it sends a bare `/model` and lets Pi open its own picker; set `g:claude_providers.pi.models` to get the list here instead.

## Rooms

A room is a git worktree that sessions belong to: its own checkout, on its own branch, inside the project. A room can hold sub-rooms — each a worktree of its own, cut from the room — to split the room's work between agents. The project's main checkout is the root room. Work flows sub-room → room → main, but every merge is yours: the plugin never merges or pushes.

```
project/
└── .vim-workspace/                 kept out of git status via .git/info/exclude
    ├── panel/
    │   ├── project/                room panel, on room/panel
    │   └── icons/
    │       └── project/            sub-room icons, on room/panel--icons
    └── difftree/
        └── project/
```

Starting a session asks which room first, then the session's name:

```
Room for the new session (blank keeps *):
1. * claude-plugin (root) — main
2.   panel
3.     icons
4.   + New room…
5.   + New sub-room…
```

- **An existing room** — the session joins it; nothing is created. A blank answer keeps the selected room.
- **A new room** asks for a name and a base branch. Blank means the *latest* default branch: it is fetched (`g:claude_room_fetch`) and the room is cut from the remote's copy, not a stale local one. The room's branch has no upstream, so `git pull` in it never pulls main in.
- **A new sub-room** goes in the selected room (or asks which), and starts from the room's last commit. Uncommitted work in the room is not carried over, and you are told when there is some.

Nothing is created until every question is answered, so CTRL-C anywhere leaves nothing behind. A session left unnamed in a room it just created takes the room's name.

`:ClaudeNew`/`:PiNew` answer both questions without prompting when the text starts with `room:` — a word immediately followed by a colon. Everything after it is the session name, e.g. `:ClaudeNew panel: Fix the fleet config`. The room is used if it exists and made from the latest default branch if it doesn't; `panel/icons:` does the same for a sub-room of `panel`, and `root:` means the main checkout. `:ClaudeNew panel:` with nothing after the colon names the session after the room. Without a leading `word:` the whole text is still just the session name, spaces and all — `:ClaudeNew fix the bug` names the session "fix the bug" and touches no room.

The panel's `N` runs these prompts; its `n` asks only for the name, because the row under the cursor already says which room — a room row, a sub-room row, or any session under them. On a project row it means the root room.

The diff tree compares a room with what it was cut from and a sub-room with its room, so a sub-room shows its own work and nothing of the room's — see [Git diff tree](#git-diff-tree).

`<leader>cw` (`:ClaudeRooms`; `:ClaudeWorkspaces` still works) lists every room and re-roots NERDTree onto the one you pick. Sessions started without being asked run there. It also runs `:tcd` to that room, so the current tab's working directory — and anything that depends on it, like `:Git status` — follows; other tabs are left alone.

`d` on a room row, in the session panel or the diff tree, removes the room's worktree; `D` forces it past uncommitted changes. The branch is always kept. A room that still has sub-rooms is refused.

> **Watch out:** `git clean -ffdx` in the main checkout deletes every room, uncommitted work included (a single `-f` skips them). Tools that ignore git's ignore rules — `:vimgrep **`, some test runners — see one copy of the project per room; set an absolute `g:claude_room_dir` to keep rooms outside the project.

Existing workspaces become rooms the first time the plugin runs, where they already are — nothing is moved — and the sessions in them follow.

### Unnamed sessions, and the buried tail

Leaving both prompts blank is a real answer: the session goes unnamed and Claude names the conversation itself. Sessions carrying a `claude <date> <time>` name count as unnamed too — that is what earlier versions minted when the prompt was left empty, so nobody ever chose it.

An unnamed session is not a nameless row. It is labelled by the first thing that was asked of it, read from its transcript, and falls back to its id (`(unnamed 4f3c9a02)`) only when there is no message yet. On this machine 11 of 130 stored sessions carry a name someone typed, so a name is the exception, not the identity.

A **finished** session is buried — left out of the panel list, the way NERDTree leaves out dotfiles — when nobody named it, or when nobody has touched it for `g:claude_panel_stale_days` days (2 by default). A running session is never buried, whatever it is called: the one waiting for you is the last thing to hide.

Press `I` to show the buried ones and again to put them away; renaming one with `r` un-hides it until it goes stale. They are hidden from the panel list only: a buried session still counts in the header while it runs, still appears in the pickers and in `:ClaudeResume`, and still runs.

## Model switching

`:ClaudeModel` (or `<leader>cm`) shows a numbered picker and switches models without interrupting the conversation. Opens a new session first if none is running. The list belongs to the session's agent — `g:claude_models` for Claude, `g:claude_providers.pi.models` for Pi, which ships none and so opens Pi's own picker instead (see [Choosing an agent](#choosing-an-agent)).

## Help

Full documentation is available inside Vim:

```
:help claude
```

## License

MIT
