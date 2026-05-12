# claude.vim

A Vim/Neovim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you a persistent AI session alongside your code.

## Requirements

- Vim 8.1+ (with `+terminal`) or Neovim 0.5+
- The `claude` CLI on your `$PATH`

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'pedrocordeiro/claude.vim'
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'pedrocordeiro/claude.vim' }
```

Or copy `plugin/claude.vim` and `autoload/claude.vim` into your plugin directory manually.

## Usage

| Mapping | Command | Action |
|---------|---------|--------|
| `<leader>co` | `:ClaudeOpen` | Open Claude in a split |
| `<leader>ct` | `:ClaudeToggle` | Show/hide the Claude window |
| `<leader>cx` | `:ClaudeClose` | Close Claude and end the session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to the Claude window |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Open floating input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |

Inside the Claude terminal, press `<Esc><Esc>` to enter terminal-normal mode (so Vim handles the cursor and mouse). Single `<Esc>` is passed through to Claude.

## Floating input window

`<leader>ci` opens a dedicated buffer for writing long, multi-line prompts:

- **Neovim**: a centred floating window with rounded borders. Title bar shows "Claude Input"; on Neovim 0.10+ the footer shows the key hints.
- **Vim 8**: a 10-line horizontal split at the bottom; the statusline shows the hints.

| Key | Action |
|-----|--------|
| `<C-s>` (insert or normal) | Send the message and close the window |
| `<Esc>` / `q` (normal) | Cancel and close without sending |

Claude is opened automatically if no session is running.

## Configuration

All settings are optional. Add them to your `vimrc` / `init.vim`:

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
