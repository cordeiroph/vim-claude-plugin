if exists('g:loaded_claude_plugin')
  finish
endif
let g:loaded_claude_plugin = 1

" Default configuration
" g:claude_split_anchor: where the Claude window is pinned — 'right' (default), 'left', 'top', 'bottom'
if !exists('g:claude_split_anchor')
  let g:claude_split_anchor = 'right'
endif

if !exists('g:claude_split_size')
  let g:claude_split_size = 80
endif

if !exists('g:claude_cmd')
  let g:claude_cmd = 'claude'
endif

" Commands
command! ClaudeOpen    call claude#open()
command! ClaudeToggle  call claude#toggle()
command! ClaudeClose   call claude#close()
command! ClaudeExplain call claude#explain('n')

" Window navigation
command! ClaudeFocus      call claude#focus()
command! ClaudeWinLeft    call claude#win_move('h')
command! ClaudeWinRight   call claude#win_move('l')
command! ClaudeWinUp      call claude#win_move('k')
command! ClaudeWinDown    call claude#win_move('j')

" Default keymaps (can be disabled by setting g:claude_no_default_mappings = 1)
if !exists('g:claude_no_default_mappings')
  nnoremap <silent> <leader>co :ClaudeOpen<CR>
  nnoremap <silent> <leader>ct :ClaudeToggle<CR>
  nnoremap <silent> <leader>cx :ClaudeClose<CR>
  nnoremap <silent> <leader>cf :ClaudeFocus<CR>

  " Explain: normal mode sends whole file, visual mode sends selection
  nnoremap <silent> <leader>ce :call claude#explain('n')<CR>
  xnoremap <silent> <leader>ce :<C-u>call claude#explain('v')<CR>

  " Move between windows (same as Ctrl-W hjkl but as leader shortcuts)
  nnoremap <silent> <leader>ch :ClaudeWinLeft<CR>
  nnoremap <silent> <leader>cl :ClaudeWinRight<CR>
  nnoremap <silent> <leader>ck :ClaudeWinUp<CR>
  nnoremap <silent> <leader>cj :ClaudeWinDown<CR>
endif
