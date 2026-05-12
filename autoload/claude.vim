" ── session storage ──────────────────────────────────────────────────────────
" Per-tab mode (default): each tab stores its session in the t: namespace.
" t: variables are automatically scoped to the current tab, so no manual
" tab-tracking is needed for reads/writes. When the tab is closed, Vim
" garbage-collects its t: variables automatically.
"
" Global mode (g:claude_tab_sessions=0): a single session is kept in s: vars.
let s:g_bufnr = -1  " buffer nr for the global-mode terminal

" Returns 1 when per-tab sessions are enabled (the default).
function! s:tab_mode() abort
  return get(g:, 'claude_tab_sessions', 1)
endfunction

" Returns the buffer number of the active Claude terminal for the current tab
" (or the global buffer in global mode). -1 when no session exists.
function! s:get_bufnr() abort
  return s:tab_mode() ? get(t:, 'claude_bufnr', -1) : s:g_bufnr
endfunction

" Stores the buffer number for the current session.
" In tab mode writes to t: (tab-local); in global mode writes to s:.
function! s:set_session(bufnr) abort
  if s:tab_mode()
    let t:claude_bufnr = a:bufnr
  else
    let s:g_bufnr = a:bufnr
  endif
endfunction


" ── public API ───────────────────────────────────────────────────────────────

" Open a new Claude terminal in a split window. If a session is already open
" for this tab, focus it instead of opening a second one.
function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  " Create the split window at the configured anchor position.
  execute s:split_cmd()

  if has('terminal')
    " ++curwin reuses the current window instead of opening a new one.
    execute 'terminal ++curwin ' . g:claude_cmd
    call s:set_session(bufnr('%'))
    call claude#input#collect_data()
  else
    echoerr 'claude.vim: terminal support required (Vim 8+)'
    close
    return
  endif

  call s:set_buf_options()
endfunction

" Stop the terminal job in {bufnr} and block until it exits (up to 500 ms).
" Callers must do this before bwipeout! to avoid E947.
function! s:job_stop_wait(bufnr) abort
  let l:job = term_getjob(a:bufnr)
  if l:job is v:null || job_status(l:job) !=# 'run'
    return
  endif
  call job_stop(l:job)
  for l:_ in range(25)
    if job_status(l:job) !=# 'run'
      break
    endif
    sleep 20m
  endfor
endfunction

" Stop all running Claude jobs without wiping their buffers. Called from
" QuitPre — before Vim's E947 check — so :q / :qall can proceed cleanly.
" VimLeavePre then calls close_all() to do the final buffer wipeout.
function! claude#_stop_jobs() abort
  if !s:tab_mode()
    if s:g_bufnr != -1 && bufexists(s:g_bufnr)
      call s:job_stop_wait(s:g_bufnr)
    endif
    return
  endif
  for l:tabnr in range(1, tabpagenr('$'))
    let l:bufnr = gettabvar(l:tabnr, 'claude_bufnr', -1)
    if l:bufnr != -1 && bufexists(l:bufnr)
      call s:job_stop_wait(l:bufnr)
    endif
  endfor
endfunction

" Close the Claude terminal for the current tab and wipe its buffer.
function! claude#close() abort
  if !s:is_open()
    return
  endif
  call s:job_stop_wait(s:get_bufnr())
  call s:cleanup_current()
endfunction

" Wipe all Claude terminal buffers across every tab. Called from VimLeavePre
" after jobs have already been stopped by claude#_stop_jobs() in QuitPre.
function! claude#close_all() abort
  if !s:tab_mode()
    call claude#close()
    return
  endif
  for l:tabnr in range(1, tabpagenr('$'))
    let l:bufnr = gettabvar(l:tabnr, 'claude_bufnr', -1)
    if l:bufnr == -1 || !bufexists(l:bufnr)
      continue
    endif
    call s:job_stop_wait(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
    call settabvar(l:tabnr, 'claude_bufnr', -1)
  endfor
endfunction

" Toggle the Claude window: hide it if visible, show it if hidden, open a new
" session if none exists.
function! claude#toggle() abort
  if !s:is_open()
    call claude#open()
    return
  endif

  let l:win = bufwinid(s:get_bufnr())

  if l:win != -1
    " Window is visible — hide it (buffer stays alive, session continues).
    call win_execute(l:win, 'hide')
  else
    " Session exists but window is not visible — reopen the split and show it.
    execute s:split_cmd()
    execute 'buffer ' . s:get_bufnr()
    call s:set_buf_options()
    call s:terminal_enter_insert()
  endif
endfunction

" Move the cursor to the Claude window. Opens a new session if none exists,
" or reveals a hidden window if the session is alive but not displayed.
function! claude#focus() abort
  if !s:is_open()
    call claude#open()
    return
  endif

  let l:win = bufwinid(s:get_bufnr())
  if l:win != -1
    call win_gotoid(l:win)
    call s:terminal_enter_insert()
  else
    " Session alive but no visible window — toggle will reopen the split.
    call claude#toggle()
  endif
endfunction

" Enter terminal-insert mode, using feedkeys so the mode switch happens after
" the current command sequence finishes. Guards against feeding 'i' to a
" terminal that is already live (insert mode), which would type into Claude.
function! s:terminal_enter_insert() abort
  if term_getstatus(s:get_bufnr()) =~# 'normal'
    call feedkeys('i', 'n')
  endif
endfunction

" Move the cursor to an adjacent window using standard Vim wincmd directions
" (h=left, l=right, k=up, j=down).
function! claude#win_move(dir) abort
  execute 'wincmd ' . a:dir
endfunction

" ── private helpers ──────────────────────────────────────────────────────────

" Returns true when a live Claude session exists for the current tab.
" Also cleans up stale state if the buffer no longer exists or the job is dead.
function! s:is_open() abort
  let l:bufnr = s:get_bufnr()
  if l:bufnr == -1 || !bufexists(l:bufnr)
    call s:set_session(-1)
    return v:false
  endif
  " Vim has no on_exit hook for ++curwin terminals, so detect a dead job
  " by polling job_status on every is_open() call.
  if has('terminal')
    let l:job = term_getjob(l:bufnr)
    if l:job is v:null || job_status(l:job) ==# 'dead'
      call s:cleanup_current()
      return v:false
    endif
  endif
  return v:true
endfunction

" Wipe the terminal buffer for the current tab's session (or global session).
" bwipeout! closes any window displaying the buffer automatically.
function! s:cleanup_current() abort
  let l:bufnr = s:get_bufnr()
  " Clear session state before wiping so re-entrant calls see no session.
  call s:set_session(-1)
  if l:bufnr != -1 && bufexists(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
  endif
endfunction

" Returns the Ex command that creates the split at the configured anchor.
" botright/topleft pin the new window to the very edge of the screen so it
" doesn't push other splits around.
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

" Apply buffer-local options to the Claude terminal window.
function! s:set_buf_options() abort
  setlocal bufhidden=hide   " hide instead of unload on :q, avoiding E947
  setlocal nobuflisted      " hide from buffer list
  setlocal nonumber         " no line numbers
  setlocal norelativenumber
  setlocal signcolumn=no    " no sign column
  let l:anchor = get(g:, 'claude_split_anchor', 'right')
  if l:anchor ==# 'left' || l:anchor ==# 'right'
    setlocal winfixwidth    " prevent the vertical split from being resized
  else
    setlocal winfixheight   " prevent the horizontal split from being resized
  endif
  " In terminal-insert mode Vim surrenders mouse events to the terminal
  " emulator, which handles drag-selection at raw screen coordinates and lets
  " selections cross window borders. Double-Esc enters terminal-normal mode
  " so Vim regains mouse ownership and selection stays within this window.
  " Single Esc is left unbound so it reaches Claude (e.g. to dismiss pagers).
  tnoremap <buffer> <Esc><Esc> <C-\><C-n>
endfunction

" ── explain ──────────────────────────────────────────────────────────────────

" Send an explain prompt to Claude for the current file (mode='n') or the
" current visual selection (mode='v'). Opens Claude if not already running.
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

  " Wrap the code in a fenced code block so Claude gets syntax context.
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
    " Claude needs a moment to initialise before it can accept input.
    " Poll until output appears (max 15 × 300 ms = 4.5 s) then send.
    call s:send_when_ready(l:prompt, 15)
  endif
endfunction

" Return the lines covered by the most recent visual selection, trimmed to the
" exact character columns that were selected.
function! s:get_visual_selection() abort
  let [l:l1, l:c1] = getpos("'<")[1:2]
  let [l:l2, l:c2] = getpos("'>")[1:2]
  let l:lines = getline(l:l1, l:l2)
  if empty(l:lines)
    return []
  endif
  " Clamp last and first lines to the selection boundaries.
  let l:lines[-1] = l:lines[-1][:l:c2 - 1]
  let l:lines[0]  = l:lines[0][l:c1 - 1:]
  return l:lines
endfunction

" Poll the terminal every 300 ms until output appears (Claude's startup UI is
" visible), then send {text}. Gives up and sends anyway after {retries} tries
" so the caller is never silently dropped.
function! s:send_when_ready(text, retries) abort
  if !s:is_open()
    return
  endif
  if s:terminal_scan('\S') || a:retries <= 0
    call s:send(a:text)
  else
    call timer_start(300, {-> s:send_when_ready(a:text, a:retries - 1)})
  endif
endfunction


" Scan up to 50 lines of the Claude terminal buffer for lines matching
" {pattern}. Returns true on the first match, false if none found.
function! s:terminal_scan(pattern) abort
  let l:bufnr = s:get_bufnr()
  if l:bufnr == -1
    return v:false
  endif
  for l:i in range(1, 50)
    if term_getline(l:bufnr, l:i) =~# a:pattern
      return v:true
    endif
  endfor
  return v:false
endfunction

" Send {text} to the Claude terminal using bracketed-paste escape sequences.
" Bracketed paste tells Claude's input handler to treat the entire block as
" pasted text, so embedded newlines don't trigger premature submission.
function! s:send(text) abort
  let l:bufnr = s:get_bufnr()
  if l:bufnr != -1 && bufexists(l:bufnr)
    call term_sendkeys(l:bufnr, "\e[200~" . a:text . "\e[201~\r")
  endif
  call claude#focus()
endfunction

" ── model selection ──────────────────────────────────────────────────────────

" Present a numbered list of models from g:claude_models and send /model
" for the chosen one. Opens Claude first if no session is running.
function! claude#select_model() abort
  let l:models = get(g:, 'claude_models', [
        \ 'claude-opus-4-7',
        \ 'claude-sonnet-4-6',
        \ 'claude-haiku-4-5-20251001',
        \ ])

  " inputlist() expects item 0 to be a header and items 1..N to be choices.
  let l:menu = ['Switch Claude model:']
  let l:i = 1
  for l:m in l:models
    call add(l:menu, printf('%d. %s', l:i, l:m))
    let l:i += 1
  endfor

  let l:choice = inputlist(l:menu)
  if l:choice < 1 || l:choice > len(l:models)
    return
  endif

  let l:model = l:models[l:choice - 1]

  if !s:is_open()
    call claude#open()
    " Session just started; wait for Claude to initialise before sending.
    call s:send_when_ready('/model ' . l:model, 15)
  else
    call claude#focus()
    call s:send('/model ' . l:model)
  endif
endfunction

" Expose s:split_cmd() publicly so it can be used in tests.
function! claude#split_cmd() abort
  return s:split_cmd()
endfunction

" ── common ────────────────────────────────────────────────────────────────────

" Open or focus Claude then send {text}, waiting for startup if needed.
function! claude#_send_input(text) abort
  if !s:is_open()
    call claude#open()
    call s:send_when_ready(a:text, 15)
  else
    call claude#focus()
    call s:send(a:text)
  endif
endfunction
