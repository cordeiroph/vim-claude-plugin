" Tracks the terminal buffer number and (Neovim) the job channel id
let s:claude_bufnr  = -1
let s:claude_chanid = -1

function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  let l:prev_win = win_getid()
  execute s:split_cmd()

  " Open a new terminal running the claude CLI
  if has('nvim')
    let s:claude_chanid = termopen(g:claude_cmd, {'on_exit': function('s:on_exit')})
    let s:claude_bufnr  = bufnr('%')
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
  if s:claude_bufnr == -1 || !bufexists(s:claude_bufnr)
    let s:claude_bufnr  = -1
    let s:claude_chanid = -1
    return v:false
  endif
  " Vim 8 has no on_exit hook for ++curwin terminals; detect a dead job here.
  if !has('nvim') && has('terminal')
    let l:job = term_getjob(s:claude_bufnr)
    if l:job is v:null || job_status(l:job) ==# 'dead'
      call s:cleanup_dead_terminal()
      return v:false
    endif
  endif
  return v:true
endfunction

" Close the dead terminal window and wipe its buffer so the next
" claude#open() starts from a clean state.
function! s:cleanup_dead_terminal() abort
  let l:bufnr = s:claude_bufnr
  let s:claude_bufnr  = -1
  let s:claude_chanid = -1
  if l:bufnr == -1
    return
  endif
  let l:win = bufwinid(l:bufnr)
  if l:win != -1
    call win_execute(l:win, 'close')
  endif
  if bufexists(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
  endif
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
  " Defer cleanup so Neovim finishes settling the terminal buffer state first.
  call timer_start(0, {-> s:cleanup_dead_terminal()})
endfunction

" ── explain ──────────────────────────────────────────────────────────────────

" claude#explain('n') — explain current file
" claude#explain('v') — explain visual selection
function! claude#explain(mode) abort
  let l:ft = &filetype

  if a:mode ==# 'v'
    let l:lines = s:get_visual_selection()
    let l:desc  = 'the selected text'
  else
    let l:lines = getline(1, '$')
    let l:fname = expand('%:t')
    let l:desc  = empty(l:fname) ? 'this code' : 'the file ' . l:fname
  endif

  let l:fence  = '```' . l:ft
  let l:prompt = 'Explain ' . l:desc . ":\n\n" . l:fence . "\n"
        \ . join(l:lines, "\n") . "\n```"

  let l:already_open = s:is_open()
  if !l:already_open
    call claude#open()
  else
    call claude#focus()
  endif

  if l:already_open
    call s:send(l:prompt)
  else
    " Poll until Claude has produced output (startup UI visible = input ready).
    " Max 15 attempts × 300 ms = 4.5 s before giving up.
    call s:send_when_ready(l:prompt, 15)
  endif
endfunction

function! s:get_visual_selection() abort
  let [l:l1, l:c1] = getpos("'<")[1:2]
  let [l:l2, l:c2] = getpos("'>")[1:2]
  let l:lines = getline(l:l1, l:l2)
  if empty(l:lines)
    return []
  endif
  " Clamp columns to actual selection bounds
  let l:lines[-1] = l:lines[-1][:l:c2 - 1]
  let l:lines[0]  = l:lines[0][l:c1 - 1:]
  return l:lines
endfunction

" Retry sending every 300 ms until the terminal has produced output,
" meaning Claude has finished initialising and enabled bracketed-paste mode.
function! s:send_when_ready(text, retries) abort
  if !s:is_open()
    return
  endif
  if s:terminal_has_output() || a:retries <= 0
    call s:send(a:text)
  else
    call timer_start(300, {-> s:send_when_ready(a:text, a:retries - 1)})
  endif
endfunction

" Returns true once the terminal buffer contains at least one non-empty line.
function! s:terminal_has_output() abort
  if has('nvim')
    let l:lines = nvim_buf_get_lines(s:claude_bufnr, 0, 10, v:false)
    return !empty(filter(copy(l:lines), {_, v -> v !=# ''}))
  else
    for l:i in range(1, 10)
      if term_getline(s:claude_bufnr, l:i) !=# ''
        return v:true
      endif
    endfor
    return v:false
  endif
endfunction

" Send text to the Claude terminal using bracketed-paste so embedded newlines
" are not treated as Enter/submit by Claude's input handler.
function! s:send(text) abort
  if has('nvim')
    if s:claude_chanid != -1
      call chansend(s:claude_chanid, "\e[200~" . a:text . "\e[201~\n")
    endif
  else
    if bufexists(s:claude_bufnr)
      call term_sendkeys(s:claude_bufnr, "\e[200~" . a:text . "\e[201~\r")
    endif
  endif
endfunction

function! claude#split_cmd() abort
  return s:split_cmd()
endfunction
