" Tracks the terminal buffer number
let s:claude_bufnr = -1

function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  let l:prev_win = win_getid()

  if g:claude_split_direction ==# 'horizontal'
    execute g:claude_split_size . 'split'
  else
    execute 'vertical ' . g:claude_split_size . 'split'
  endif

  " Open a new terminal running the claude CLI
  if has('nvim')
    call termopen(g:claude_cmd, {'on_exit': function('s:on_exit')})
    let s:claude_bufnr = bufnr('%')
    startinsert
  elseif has('terminal')
    execute 'terminal ' . g:claude_cmd
    let s:claude_bufnr = bufnr('%')
  else
    echoerr 'claude.vim: terminal support required (Vim 8+ or Neovim)'
    close
    return
  endif

  call s:set_buf_options()
endfunction

function! claude#close() abort
  if !s:is_open()
    return
  endif

  let l:win = bufwinid(s:claude_bufnr)
  if l:win != -1
    call win_execute(l:win, 'close')
  endif

  if bufexists(s:claude_bufnr)
    execute 'bdelete! ' . s:claude_bufnr
  endif

  let s:claude_bufnr = -1
endfunction

function! claude#toggle() abort
  if !s:is_open()
    call claude#open()
    return
  endif

  let l:win = bufwinid(s:claude_bufnr)

  if l:win != -1
    " Window is visible — hide it (close the window, keep the buffer)
    call win_execute(l:win, 'hide')
  else
    " Buffer exists but window is hidden — reopen the split
    if g:claude_split_direction ==# 'horizontal'
      execute g:claude_split_size . 'split'
    else
      execute 'vertical ' . g:claude_split_size . 'split'
    endif
    execute 'buffer ' . s:claude_bufnr
    call s:set_buf_options()
    if has('nvim')
      startinsert
    endif
  endif
endfunction

function! claude#focus() abort
  if !s:is_open()
    call claude#open()
    return
  endif

  let l:win = bufwinid(s:claude_bufnr)
  if l:win != -1
    call win_gotoid(l:win)
    if has('nvim')
      startinsert
    endif
  else
    " Buffer hidden — bring it back and focus
    call claude#toggle()
  endif
endfunction

" Move from any window in the given direction (standard Ctrl-W navigation)
function! claude#win_move(dir) abort
  execute 'wincmd ' . a:dir
endfunction

" ── private helpers ──────────────────────────────────────────────────────────

function! s:is_open() abort
  return s:claude_bufnr != -1 && bufexists(s:claude_bufnr)
endfunction

function! s:set_buf_options() abort
  setlocal nobuflisted
  setlocal nonumber
  setlocal norelativenumber
  setlocal signcolumn=no
  setlocal winfixwidth
endfunction

function! s:on_exit(job_id, code, event) abort
  " Neovim callback when the claude process exits
  let s:claude_bufnr = -1
endfunction
