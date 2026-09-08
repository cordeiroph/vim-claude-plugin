# claude.vim

A Vim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you persistent AI sessions alongside your code.

Run as many sessions as you like, name them, and switch between them from a NERDTree-style side panel grouped by project, worktree and branch.

## Requirements

- Vim 8.1+ (with `+terminal`)
- The `claude` CLI on your `$PATH`

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
| `<leader>cs` | `:ClaudeSessions` | Toggle the session panel |
| `<C-z>` | `:ClaudeSidebars` | Raise or dismiss the whole sidebar column |
| `<leader>ct` | `:ClaudeToggle` | Show/hide a Claude window |
| `<leader>cx` | `:ClaudeClose` | End a session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to a Claude window (enters insert mode) |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Toggle the input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |

`:ClaudeNew [name]` starts an extra session, and `:ClaudeRename [name]` renames one. When several sessions are running, commands that need just one show a picker; when only one is running, it is used without prompting.

Inside the Claude terminal, press `<Esc><Esc>` to enter terminal-normal mode (so Vim handles the cursor and mouse). Single `<Esc>` is passed through to Claude.

## Input window

`<leader>ci` toggles a dedicated buffer for writing long, multi-line prompts. It opens as a 10-line split at the bottom. Pressing `<leader>ci` again discards the content and closes the window. To preserve your text, press `<Esc>` instead — it saves a draft and hides the window; reopening restores it.

The buffer is a `.md` file, so syntax highlighting and Copilot completions work out of the box.

| Key | Action |
|-----|--------|
| `<C-s>` (insert or normal) | Send the message and close the window |
| `<Esc>` (normal) | Save draft and hide the window |
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
let g:claude_sidebar_toggle_key = '<C-z>'

" Session panel: width, edge, and how often status is polled while it is open
let g:claude_panel_width = 35
let g:claude_panel_anchor = 'left'
let g:claude_panel_refresh_ms = 2000

" Seconds of silence before a running session is shown as idle
let g:claude_panel_idle_secs = 30

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
```

## Session panel

`<leader>cs` toggles a panel listing every session — the ones running now and the ones you can resume — grouped by project, worktree and branch:

```
Claude Sessions               (3)

▾ claude-pluing
  ▾ ~/Workspace/vim/claude-pluing
    ▾ main
      ● panel design
      ○ doc rewrite
    ▾ feature/session-registry
      ○ registry spike
  ▾ ~/Workspace/vim/wt-hotfix
    ▾ hotfix/e947
      ✗ E947 repro
```

`●` active, `○` idle (no output for 30s), `✗` closed but resumable.

The panel uses NERDTree's palette — group nodes coloured like directories, session names like files — so the sidebar reads as one thing. Where NERDTree's highlight groups exist they are used directly, so restyling NERDTree restyles the panel. Override `ClaudeSessionProject`, `ClaudeSessionWorktree`, `ClaudeSessionBranch`, `ClaudeSessionName`, `ClaudeSessionActive` and friends to restyle just the panel; a link you set is never overwritten.

| Key | Action |
|-----|--------|
| `<CR>` / `o` | Open the session, or fold a group |
| `i` | Open in a horizontal split |
| `s` | Open in a vertical split |
| `t` | Open in a new tab |
| `n` | Start a new session |
| `r` | Rename |
| `d` | End the session (transcript kept, so it stays resumable) |
| `D` | Purge the session and delete its transcript |
| `R` | Rescan transcripts |
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

`<C-z>` (`:ClaudeSidebars`) raises all three at once and dismisses them again once they are all showing. It is mapped in normal mode only, so `<C-z>` still suspends Vim from a terminal buffer and from insert mode; rebind or disable it with `g:claude_sidebar_toggle_key`. While stacked the column is NERDTree's width, since NERDTree resets its own width on every redraw. Set `g:claude_panel_nerdtree_stack = 0` to opt out.

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

## Model switching

`:ClaudeModel` (or `<leader>cm`) shows a numbered picker and switches models without interrupting the conversation. Opens a new session first if none is running.

## Help

Full documentation is available inside Vim:

```
:help claude
```

## License

MIT
