" Tracks the terminal buffer number
let s:claude_bufnr = -1

function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  let l:prev_win = win_getid()
  execute s:split_cmd()

  " Open a new terminal running the claude CLI
  if has('nvim')
    call termopen(g:claude_cmd, {'on_exit': function('s:on_exit')})
    let s:claude_bufnr = bufnr('%')
    startinsert
  elseif has('terminal')
    " ++curwin runs the terminal inside the current split instead of opening another window
    execute 'terminal ++curwin ' . g:claude_cmd
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

  " Stop the running job before wiping — bwipeout! alone can still error on
  " an active terminal buffer in Vim 8.
  if !has('nvim') && has('terminal')
    let l:job = term_getjob(s:claude_bufnr)
    if l:job isnot v:null && job_status(l:job) ==# 'run'
      call job_stop(l:job)
    endif
  endif

  if bufexists(s:claude_bufnr)
    execute 'bwipeout! ' . s:claude_bufnr
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
    execute s:split_cmd()
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

" Returns the Ex split command for the configured anchor position.
" botright/topleft pin the window to the very edge of the screen.
function! s:split_cmd() abort
  let l:size = g:claude_split_size
  let l:anchor = get(g:, 'claude_split_anchor', 'right')
  if l:anchor ==# 'left'
    return 'topleft vertical ' . l:size . 'split'
  elseif l:anchor ==# 'top'
    return 'topleft ' . l:size . 'split'
  elseif l:anchor ==# 'bottom'
    return 'botright ' . l:size . 'split'
  else
    return 'botright vertical ' . l:size . 'split'
  endif
endfunction

function! s:set_buf_options() abort
  setlocal nobuflisted
  setlocal nonumber
  setlocal norelativenumber
  setlocal signcolumn=no
  let l:anchor = get(g:, 'claude_split_anchor', 'right')
  if l:anchor ==# 'left' || l:anchor ==# 'right'
    setlocal winfixwidth
  else
    setlocal winfixheight
  endif
  " In terminal-mode Vim gives up mouse reporting so the terminal emulator
  " handles drag-selection at raw screen coordinates, crossing window borders.
  " Mapping <Esc> to terminal-normal mode lets Vim own the mouse again —
  " visual selection then stays bounded to this window.
  tnoremap <buffer> <Esc> <C-\><C-n>
endfunction

function! s:on_exit(job_id, code, event) abort
  " Neovim callback when the claude process exits
  let s:claude_bufnr = -1
endfunction

function! claude#split_cmd() abort
  return s:split_cmd()
endfunction
