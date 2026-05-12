" ── session storage ──────────────────────────────────────────────────────────
" When g:claude_tab_sessions=1 (default) each tab gets its own session stored
" in the t: namespace. t: variables are automatically scoped to the current
" tab, so no manual tab-tracking is needed for reads/writes.
" When g:claude_tab_sessions=0 a single global session is kept in s:.
"
" Neovim on_exit fires outside the originating tab's context, so we keep a
" chanid→tabnr map to route cleanup to the right tab.
let s:g_bufnr      = -1   " global-mode fallback
let s:g_chanid     = -1
let s:chanid_to_tab = {}  " nvim: chanid → tabnr (0 = global mode)

function! s:tab_mode() abort
  return get(g:, 'claude_tab_sessions', 1)
endfunction

function! s:get_bufnr() abort
  return s:tab_mode() ? get(t:, 'claude_bufnr', -1) : s:g_bufnr
endfunction

function! s:get_chanid() abort
  return s:tab_mode() ? get(t:, 'claude_chanid', -1) : s:g_chanid
endfunction

function! s:set_session(bufnr, chanid) abort
  if s:tab_mode()
    let t:claude_bufnr  = a:bufnr
    let t:claude_chanid = a:chanid
  else
    let s:g_bufnr  = a:bufnr
    let s:g_chanid = a:chanid
  endif
endfunction

" ── public API ───────────────────────────────────────────────────────────────

function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  execute s:split_cmd()

  if has('nvim')
    let l:tabnr  = tabpagenr()
    let l:chanid = termopen(g:claude_cmd, {'on_exit': function('s:on_exit')})
    call s:set_session(bufnr('%'), l:chanid)
    let s:chanid_to_tab[l:chanid] = s:tab_mode() ? l:tabnr : 0
    startinsert
  elseif has('terminal')
    " ++curwin runs the terminal inside the current split instead of opening another window
    execute 'terminal ++curwin ' . g:claude_cmd
    call s:set_session(bufnr('%'), -1)
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
    let l:job = term_getjob(s:get_bufnr())
    if l:job isnot v:null && job_status(l:job) ==# 'run'
      call job_stop(l:job)
    endif
  endif

  call s:cleanup_current()
endfunction

function! claude#toggle() abort
  if !s:is_open()
    call claude#open()
    return
  endif

  let l:win = bufwinid(s:get_bufnr())

  if l:win != -1
    call win_execute(l:win, 'hide')
  else
    execute s:split_cmd()
    execute 'buffer ' . s:get_bufnr()
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

  let l:win = bufwinid(s:get_bufnr())
  if l:win != -1
    call win_gotoid(l:win)
    if has('nvim')
      startinsert
    endif
  else
    call claude#toggle()
  endif
endfunction

function! claude#win_move(dir) abort
  execute 'wincmd ' . a:dir
endfunction

" ── private helpers ──────────────────────────────────────────────────────────

function! s:is_open() abort
  let l:bufnr = s:get_bufnr()
  if l:bufnr == -1 || !bufexists(l:bufnr)
    call s:set_session(-1, -1)
    return v:false
  endif
  " Vim 8 has no on_exit hook for ++curwin terminals; detect a dead job here.
  if !has('nvim') && has('terminal')
    let l:job = term_getjob(l:bufnr)
    if l:job is v:null || job_status(l:job) ==# 'dead'
      call s:cleanup_current()
      return v:false
    endif
  endif
  return v:true
endfunction

" Clean up the session that belongs to the current tab (or global session).
function! s:cleanup_current() abort
  let l:bufnr  = s:get_bufnr()
  let l:chanid = s:get_chanid()
  call s:set_session(-1, -1)
  if l:chanid != -1
    unlet! s:chanid_to_tab[l:chanid]
  endif
  let l:win = l:bufnr != -1 ? bufwinid(l:bufnr) : -1
  if l:win != -1
    call win_execute(l:win, 'close')
  endif
  if l:bufnr != -1 && bufexists(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
  endif
endfunction

" Neovim on_exit: fires outside the originating tab's context, so we look up
" the tab via s:chanid_to_tab and use gettabvar/settabvar to reach its state.
function! s:on_exit(job_id, code, event) abort
  let l:tabnr = get(s:chanid_to_tab, a:job_id, -1)
  unlet! s:chanid_to_tab[a:job_id]
  call timer_start(0, {-> s:cleanup_for_tab(l:tabnr)})
endfunction

" Clean up a session by explicit tabnr (Neovim on_exit path).
" tabnr=0 means global mode; tabnr=-1 means unknown (no-op).
function! s:cleanup_for_tab(tabnr) abort
  if a:tabnr == -1
    return
  endif

  if a:tabnr == 0
    let l:bufnr    = s:g_bufnr
    let s:g_bufnr  = -1
    let s:g_chanid = -1
  else
    let l:bufnr = gettabvar(a:tabnr, 'claude_bufnr', -1)
    call settabvar(a:tabnr, 'claude_bufnr',  -1)
    call settabvar(a:tabnr, 'claude_chanid', -1)
  endif

  let l:win = l:bufnr != -1 ? bufwinid(l:bufnr) : -1
  if l:win != -1
    call win_execute(l:win, 'close')
  endif
  if l:bufnr != -1 && bufexists(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
  endif
endfunction

" Returns the Ex split command for the configured anchor position.
" botright/topleft pin the window to the very edge of the screen.
function! s:split_cmd() abort
  let l:size   = g:claude_split_size
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
  let l:bufnr = s:get_bufnr()
  if has('nvim')
    let l:lines = nvim_buf_get_lines(l:bufnr, 0, 10, v:false)
    return !empty(filter(copy(l:lines), {_, v -> v !=# ''}))
  else
    for l:i in range(1, 10)
      if term_getline(l:bufnr, l:i) !=# ''
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
    let l:chanid = s:get_chanid()
    if l:chanid != -1
      call chansend(l:chanid, "\e[200~" . a:text . "\e[201~\n")
    endif
  else
    let l:bufnr = s:get_bufnr()
    if l:bufnr != -1 && bufexists(l:bufnr)
      call term_sendkeys(l:bufnr, "\e[200~" . a:text . "\e[201~\r")
    endif
  endif
endfunction

function! claude#split_cmd() abort
  return s:split_cmd()
endfunction
