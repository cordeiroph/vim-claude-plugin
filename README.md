# claude.vim

A Vim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you a persistent AI session alongside your code.

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
| `<leader>co` | `:ClaudeOpen` | Open Claude in a split |
| `<leader>ct` | `:ClaudeToggle` | Show/hide the Claude window |
| `<leader>cx` | `:ClaudeClose` | Close Claude and end the session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to the Claude window (enters insert mode) |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Toggle the input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |

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

" 1 = each tab gets its own session (default), 0 = single shared session
let g:claude_tab_sessions = 1

" Models shown in the :ClaudeModel picker
let g:claude_models = [
      \ 'claude-opus-4-7',
      \ 'claude-sonnet-4-6',
      \ 'claude-haiku-4-5-20251001',
      \ ]

" Set to 1 to disable all default mappings
let g:claude_no_default_mappings = 0
```

## Tab sessions

By default each Vim tab page gets its own Claude session. Opening a new tab and running `:ClaudeOpen` starts a fresh Claude process; closing the tab terminates it automatically. Set `g:claude_tab_sessions = 0` to share a single session across all tabs.

## Model switching

`:ClaudeModel` (or `<leader>cm`) shows a numbered picker and switches models without interrupting the conversation. Opens a new session first if none is running.

## Help

Full documentation is available inside Vim:

```
:help claude
```

## License

MIT
