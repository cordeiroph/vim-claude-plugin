# claude.vim

A Vim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you persistent AI sessions alongside your code.

Run as many sessions as you like, name them, and switch between them from a NERDTree-style side panel grouped by what they're doing or by workspace and branch.

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
| `<leader>cw` | `:ClaudeWorkspaces` | Choose the workspace (git worktree) to work in |
| `<C-a>` | `:ClaudeSidebars` | Raise or dismiss the whole sidebar column |
| `<leader>ct` | `:ClaudeToggle` | Show/hide a Claude window |
| `<leader>cx` | `:ClaudeClose` | End a session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to a Claude window (enters insert mode) |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Toggle the input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |

`:ClaudeNew [name]` starts an extra session, and `:ClaudeRename [name]` renames one. When several sessions are running, commands that need just one show a picker; when only one is running, it is used without prompting.

Starting a session without naming it on the command line asks for a branch first, and gives the session its own checkout of that branch — see [Workspaces](#workspaces).

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
" nothing writes them until you install examples/hooks/claude-vim-status.mjs;
" terminal patterns and the idle timer remain the classifier until then.
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

" Where new workspaces (git worktrees) are checked out. Empty puts each one
" beside the main checkout as <repo>-<workspace name>.
let g:claude_workspace_dir = ''

" Where workspaces are remembered. Empty means data/workspaces.json inside
" the plugin directory.
let g:claude_workspace_store = ''
```

## Session panel

`<leader>cs` toggles a panel listing every session — the ones running now and the ones you can resume. It has two views, swapped with `g`.

**By state**, which is what it opens on. With several agents running the question is almost always *which one is waiting for me?*, and only this view answers it without being asked:

```
Claude Sessions           2 waiting

▾ Needs you (2)
  ✻ pick a diff base        wt · 2m
  ✻ rerun the tests?      root · 5m
▾ Working (1)
  ● panel rework          root · 1m
▾ Idle (1)
  ○ user_interface        root · 2h
▸ Done (10)
```

**By place** — group, then branch — for when the question really is what is happening in that checkout. A session that ran in a plugin-managed workspace gets its own group, one per workspace; a session run straight in the main checkout shares a group with every other such session in the repo, split by branch:

```
Claude Sessions           2 waiting

▾ claude-plugin
  ▾ main
    ● panel design           1m
    ○ doc rewrite            2h
  ▾ feature/session-registry
    ○ registry spike         4h
▾ claude-plugin-hotfix-e947
  ▾ hotfix/e947
    ✗ E947 repro             2d
```

Each view keeps its own folds, so swapping back and forth loses neither.

`✻` waiting for you, `●` working, `○` idle, `✗` closed but resumable.

Waiting and working are read from the bottom rows of the session's terminal, where Claude prints its own state — a spinner while it works, a numbered list while it asks. Both are patterns you can change (`g:claude_panel_waiting_pat`, `g:claude_panel_working_pat`); when neither matches, the idle timer decides, as it did before.

`Done` starts folded, draws at most `g:claude_panel_done_rows` rows with a `… N more` for the rest, and hides the sessions nobody named or nobody has touched for `g:claude_panel_stale_days` days. It says how many it is hiding; `I` reveals them.

`/` filters every group by label, workspace or branch. Groups left empty are dropped, folds that hid a match are opened, and the hidden tail is searched too — a row you asked for by name is not a row to hide.

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

The branch you are actually sitting on comes first. It is what shows *your* uncommitted work: a branch has no committed changes against itself, so on the base branch every other rule would skip your checkout and the panel would come up empty. When a branch is the base, the committed half is compared against its upstream instead, so unpushed commits still show. A row disappears when it has nothing to report.

Branch names are **yellow**, except a branch with no remote-tracking branch — work that exists only on your machine — which is **grey**. In the status glyphs, added is **green** and removed is **red**, taken from your `DiffAdd` and `DiffDelete` colours.

Each branch can diff against a base of its own: press `b` on a branch row to set it, or clear it with an empty answer. The choice persists across Vim restarts in `g:claude_difftree_store`, keyed by repository. `B` sets a session-wide default for branches with no base of their own. A branch on a non-default base shows it in brackets: `[feature/alpha] feature/delta (beta)`.

The branches listed are the union of every worktree, every branch a Claude session has run on (live or closed, taken from the session registry), and the branch you are on now. That is the point: a branch Claude worked on stays visible after you move off it. A branch no longer checked out anywhere is listed under the root workspace beside the branch that *is* checked out there, marked `(no worktree)` and dimmed. It shows **committed changes only** — with no working tree there is nothing to be dirty, so its second indicator slot is always blank.

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

Sessions can run Claude or [Pi](https://github.com/earendil-works/pi). Everything else is the same for both: the panel lists them together, names and resumes them the same way, and a workspace can hold one of each.

```vim
" Which CLI a new session runs by default
let g:claude_provider = 'claude'

" Per-agent overrides, merged over the defaults
let g:claude_providers = {'pi': {'cmd': 'pi --thinking high'}}
```

| | |
| --- | --- |
| `<leader>pn`, `:PiNew [name]` | Start a Pi session, whatever the default is |
| `<leader>cn`, `:ClaudeNew [name]` | Start one on the default agent |
| `N` in the panel | Asks which agent, then which branch, then the name |
| `n` in the panel | Asks nothing, and runs the agent the cursor is on |

A row shows which agent it is running only while the panel is listing more than one, so a Claude-only panel reads exactly as it did. `/pi` filters to Pi sessions.

Claude keeps its own settings under the names it always had — `g:claude_cmd`, `g:claude_models`, `g:claude_panel_working_pat`, `g:claude_panel_waiting_pat` — and a `vimrc` that sets none of the new options behaves exactly as before.

> **Note:** `:ClaudeModel` offers a numbered list only when the agent has one. Pi ships none, so it sends a bare `/model` and lets Pi open its own picker; set `g:claude_providers.pi.models` to get the list here instead.

## Workspaces

A workspace is a git worktree a session owns: its own checkout of one branch, so two sessions can work on two branches at once without fighting over one directory.

Starting a session asks two questions:

```
Branch (blank for no workspace): <Tab> completes local and remote branches
Session name:
```

| Branch | Name | Result |
|--------|------|--------|
| given | given | A workspace called `<name>`, checked out on `<branch>` |
| given | blank | A workspace named after the branch |
| blank | given | No workspace — the session runs in the selected workspace, or where you are |
| blank | blank | The same, and the session is left unnamed |

The panel's `N` runs exactly these two prompts. Its `n` runs only the second: the new session lands where the cursor already is, so the only thing left to ask is what to call it. "Where the cursor is" means the whole subtree — a branch row, a worktree row and every session under them all mean that checkout. Leave that blank and the session labels itself from its first message; `g:claude_session_prompt_name = 0` skips it too.

A branch that matches nothing becomes a new branch off `HEAD`; one that exists only on a remote gets a local tracking branch. Names are unique per repository, so a second workspace called `feature-branch` becomes `feature-branch-1`, then `feature-branch-2`, and slashes become dashes (`feature/deep` → `feature-deep`).

The worktree is created beside the main checkout as `<repo>-<name>`, or under `g:claude_workspace_dir`.

A branch that already has a checkout is not an error — the session runs in that checkout. It joins the workspace if there is one, adopts the worktree as a workspace if you made it yourself, or just runs in the main checkout when that is where the branch lives. Nothing is created only when the directory is in the way; you are told, and the session runs where you already were. Removing a workspace is left to `git worktree remove`; a worktree that is gone drops out of the list on its own.

`<leader>cw` (`:ClaudeWorkspaces`) lists the main checkout and every workspace, and re-roots NERDTree onto the one you pick, so the file tree shows that checkout and nothing else. Sessions started without a branch run there. It also runs `:tcd` to that workspace's directory, so the current tab's working directory — and anything that depends on it, like `:Git status` — follows the switch too; other tabs are left alone.

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
