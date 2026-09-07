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
let g:claude_panel_height = 15

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

It works whichever opens first, and closing either one hands the column to the other. The panel starts at `g:claude_panel_height` lines and NERDTree takes the rest; resize either by hand and it stays put, since the size is applied only when the two first come together. While stacked the column is NERDTree's width, since NERDTree resets its own width on every redraw. Set `g:claude_panel_nerdtree_stack = 0` to opt out.

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
