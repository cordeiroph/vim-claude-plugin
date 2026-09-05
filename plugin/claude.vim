" Guard against being sourced twice (e.g. when Vundle reloads plugins).
if exists('g:loaded_claude_plugin')
  finish
endif
let g:loaded_claude_plugin = 1

" ── configuration defaults ───────────────────────────────────────────────────

" g:claude_split_anchor — which screen edge the Claude window is pinned to.
" Accepted values: 'right' (default), 'left', 'top', 'bottom'.
if !exists('g:claude_split_anchor')
  let g:claude_split_anchor = 'right'
endif

" g:claude_split_size — width (columns) for left/right anchors, or height
" (lines) for top/bottom anchors.
if !exists('g:claude_split_size')
  let g:claude_split_size = 80
endif

" g:claude_cmd — the shell command used to launch Claude CLI.
if !exists('g:claude_cmd')
  let g:claude_cmd = 'claude'
endif

" g:claude_tab_sessions — 1 (default): each tab gets its own Claude session.
"                         0: a single session is shared across all tabs.
if !exists('g:claude_tab_sessions')
  let g:claude_tab_sessions = 1
endif

" g:claude_models — ordered list of model names shown by ClaudeModel picker.
if !exists('g:claude_models')
  let g:claude_models = [
        \ 'claude-opus-4-7',
        \ 'claude-sonnet-4-6',
        \ 'claude-haiku-4-5-20251001',
        \ ]
endif

" ── commands ─────────────────────────────────────────────────────────────────

command! ClaudeOpen    call claude#open()
command! ClaudeToggle  call claude#toggle()
command! ClaudeClose   call claude#close()
command! ClaudeExplain call claude#explain('n')
command! ClaudeModel   call claude#select_model()
command! ClaudeResume  call claude#resume()
command! ClaudeInput   call claude#input#open()

" Window navigation commands (wrappers around wincmd h/l/k/j).
command! ClaudeFocus      call claude#focus()
command! ClaudeWinLeft    call claude#win_move('h')
command! ClaudeWinRight   call claude#win_move('l')
command! ClaudeWinUp      call claude#win_move('k')
command! ClaudeWinDown    call claude#win_move('j')

" ── autocommands ─────────────────────────────────────────────────────────────

augroup claude_plugin
  autocmd!
  " Vim refuses to exit while a terminal job is running (E947), so the jobs
  " must be stopped before that check runs. ExitPre fires just after QuitPre
  " but only for a :q / :wq / :qall that actually ends the session, so a live
  " session survives closing an ordinary split. QuitPre must not be used here:
  " it fires for every window close and would kill the session each time.
  if exists('##ExitPre')
    autocmd ExitPre * call claude#_stop_jobs()
  else
    " Vim 8.1 before patch 8.1.0446 has no ExitPre; fall back to QuitPre with
    " a guard so only the quit that closes the last window stops the jobs.
    autocmd QuitPre * call claude#_quit_pre()
  endif
  " VimLeavePre fires after Vim commits to exiting; wipe the buffers then.
  autocmd VimLeavePre * call claude#close_all()
augroup END

" ── keymaps ──────────────────────────────────────────────────────────────────

" All default mappings can be disabled by setting g:claude_no_default_mappings=1
" before this plugin loads.
if !exists('g:claude_no_default_mappings')
  nnoremap <silent> <leader>co :ClaudeOpen<CR>
  nnoremap <silent> <leader>ct :ClaudeToggle<CR>
  nnoremap <silent> <leader>cx :ClaudeClose<CR>
  nnoremap <silent> <leader>cf :ClaudeFocus<CR>

  " Explain: normal mode sends the whole file; visual mode sends the selection.
  nnoremap <silent> <leader>ce :call claude#explain('n')<CR>
  xnoremap <silent> <leader>ce :<C-u>call claude#explain('v')<CR>

  " Switch model for the current session.
  nnoremap <silent> <leader>cm :ClaudeModel<CR>

  " Resume a previous session from the last 10 for this directory.
  nnoremap <silent> <leader>cr :ClaudeResume<CR>

  " Floating input window for composing multi-line messages.
  nnoremap <silent> <leader>ci :ClaudeInput<CR>

  " Window navigation (mirrors Ctrl-W hjkl as leader shortcuts).
  nnoremap <silent> <leader>ch :ClaudeWinLeft<CR>
  nnoremap <silent> <leader>cl :ClaudeWinRight<CR>
  nnoremap <silent> <leader>ck :ClaudeWinUp<CR>
  nnoremap <silent> <leader>cj :ClaudeWinDown<CR>
endif
