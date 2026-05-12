" ── session storage ──────────────────────────────────────────────────────────
" Per-tab mode (default): each tab stores its session in the t: namespace.
" t: variables are automatically scoped to the current tab, so no manual
" tab-tracking is needed for reads/writes. When the tab is closed, Vim
" garbage-collects its t: variables automatically.
"
" Global mode (g:claude_tab_sessions=0): a single session is kept in s: vars.
"
" Neovim's on_exit callback fires outside the originating tab's context, so
" we maintain a chanid→tabnr map to route cleanup to the correct tab.
let s:g_bufnr       = -1  " buffer nr for the global-mode terminal
let s:g_chanid      = -1  " channel id for the global-mode terminal (nvim only)
let s:chanid_to_tab = {}  " nvim: maps chanid → tabnr (0 = global mode)

" Returns 1 when per-tab sessions are enabled (the default).
function! s:tab_mode() abort
  return get(g:, 'claude_tab_sessions', 1)
endfunction

" Returns the buffer number of the active Claude terminal for the current tab
" (or the global buffer in global mode). -1 when no session exists.
function! s:get_bufnr() abort
  return s:tab_mode() ? get(t:, 'claude_bufnr', -1) : s:g_bufnr
endfunction

" Returns the channel id of the active Claude terminal (Neovim only).
" -1 when not set or in Vim 8 mode.
function! s:get_chanid() abort
  return s:tab_mode() ? get(t:, 'claude_chanid', -1) : s:g_chanid
endfunction

" Stores the buffer number and channel id for the current session.
" In tab mode writes to t: (tab-local); in global mode writes to s:.
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

" Open a new Claude terminal in a split window. If a session is already open
" for this tab, focus it instead of opening a second one.
function! claude#open() abort
  if s:is_open()
    call claude#focus()
    return
  endif

  " Create the split window at the configured anchor position.
  execute s:split_cmd()

  if has('nvim')
    let l:tabnr  = tabpagenr()
    " termopen() starts the job and returns a channel id used for sending input.
    let l:chanid = termopen(g:claude_cmd, {'on_exit': function('s:on_exit')})
    call s:set_session(bufnr('%'), l:chanid)
    " Record which tab owns this channel so on_exit can clean up the right tab.
    let s:chanid_to_tab[l:chanid] = s:tab_mode() ? l:tabnr : 0
    startinsert
  elseif has('terminal')
    " ++curwin reuses the current window instead of opening a new one.
    execute 'terminal ++curwin ' . g:claude_cmd
    call s:set_session(bufnr('%'), -1)
  else
    echoerr 'claude.vim: terminal support required (Vim 8+ or Neovim)'
    close
    return
  endif

  call s:set_buf_options()
endfunction

" Close the Claude terminal for the current tab and wipe its buffer.
function! claude#close() abort
  if !s:is_open()
    return
  endif

  " In Vim 8, bwipeout! on a running terminal can still error, so we stop
  " the job first before wiping.
  if !has('nvim') && has('terminal')
    let l:job = term_getjob(s:get_bufnr())
    if l:job isnot v:null && job_status(l:job) ==# 'run'
      call job_stop(l:job)
    endif
  endif

  call s:cleanup_current()
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
    if has('nvim')
      startinsert
    endif
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
    startinsert
  else
    " Session alive but no visible window — toggle will reopen the split.
    call claude#toggle()
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
    call s:set_session(-1, -1)
    return v:false
  endif
  " Vim 8 has no on_exit hook for ++curwin terminals, so we detect a dead job
  " here by polling job_status on every is_open() call.
  if !has('nvim') && has('terminal')
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
  let l:bufnr  = s:get_bufnr()
  let l:chanid = s:get_chanid()
  " Clear session state before wiping so re-entrant calls see no session.
  call s:set_session(-1, -1)
  if l:chanid != -1
    unlet! s:chanid_to_tab[l:chanid]
  endif
  if l:bufnr != -1 && bufexists(l:bufnr)
    execute 'bwipeout! ' . l:bufnr
  endif
endfunction

" Neovim on_exit callback. Fires asynchronously and outside the originating
" tab's context, so we look up the tab via s:chanid_to_tab and defer the
" actual cleanup with timer_start(0) to avoid re-entrancy issues.
function! s:on_exit(job_id, code, event) abort
  let l:tabnr = get(s:chanid_to_tab, a:job_id, -1)
  unlet! s:chanid_to_tab[a:job_id]
  call timer_start(0, {-> s:cleanup_for_tab(l:tabnr)})
endfunction

" Clean up a session identified by tab number (Neovim on_exit path).
" tabnr=0 means global mode; tabnr=-1 means unknown tab (no-op).
function! s:cleanup_for_tab(tabnr) abort
  if a:tabnr == -1
    return
  endif

  if a:tabnr == 0
    " Global mode: read and clear the script-local vars directly.
    let l:bufnr    = s:g_bufnr
    let s:g_bufnr  = -1
    let s:g_chanid = -1
  else
    " Tab mode: use gettabvar/settabvar to reach the target tab's variables.
    let l:bufnr = gettabvar(a:tabnr, 'claude_bufnr', -1)
    call settabvar(a:tabnr, 'claude_bufnr',  -1)
    call settabvar(a:tabnr, 'claude_chanid', -1)
  endif

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
  if has('nvim')
    let l:lines = nvim_buf_get_lines(l:bufnr, 0, 50, v:false)
    return !empty(filter(copy(l:lines), {_, v -> v =~# a:pattern}))
  else
    for l:i in range(1, 50)
      if term_getline(l:bufnr, l:i) =~# a:pattern
        return v:true
      endif
    endfor
    return v:false
  endif
endfunction

" Send {text} to the Claude terminal using bracketed-paste escape sequences.
" Bracketed paste tells Claude's input handler to treat the entire block as
" pasted text, so embedded newlines don't trigger premature submission.
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

" ── input window ─────────────────────────────────────────────────────────────

let s:input_winid  = -1  " nvim: win id of the open input float (-1 = none)
let s:input_bufnr8 = -1  " vim8: bufnr of the open input split  (-1 = none)
let s:input_saved  = []  " draft lines preserved across toggle-off

" Open or toggle the input window. If it is already visible, close it and save
" the current text as a draft; the draft is restored on the next open.
function! claude#input() abort
  if has('nvim')
    if s:input_winid != -1 && nvim_win_is_valid(s:input_winid)
      call s:input_float_save_and_close()
    else
      call s:input_float()
    endif
  else
    if s:input_bufnr8 != -1 && bufexists(s:input_bufnr8)
      call s:input_split_save_and_close()
    else
      call s:input_split()
    endif
  endif
endfunction

" ── Neovim floating window ────────────────────────────────────────────────────

function! s:input_float() abort
  let l:buf = nvim_create_buf(v:false, v:true)
  call nvim_buf_set_option(l:buf, 'filetype', 'markdown')

  let l:width  = min([max([40, &columns - 20]), 100])
  let l:height = min([max([8,  &lines   - 10]), 20])
  let l:row    = (&lines   - l:height) / 2
  let l:col    = (&columns - l:width)  / 2

  let l:opts = {
        \ 'relative': 'editor',
        \ 'width':    l:width,
        \ 'height':   l:height,
        \ 'row':      l:row,
        \ 'col':      l:col,
        \ 'style':    'minimal',
        \ 'border':   'rounded',
        \ }
  if has('nvim-0.9')
    let l:opts.title     = ' Claude Input '
    let l:opts.title_pos = 'center'
  endif
  if has('nvim-0.10')
    let l:opts.footer     = ' <C-s> send  ·  <Esc> cancel '
    let l:opts.footer_pos = 'center'
  endif

  let l:win = nvim_open_win(l:buf, v:true, l:opts)
  call nvim_win_set_option(l:win, 'wrap', v:true)
  call nvim_win_set_option(l:win, 'linebreak', v:true)
  call nvim_buf_set_var(l:buf, 'claude_input_win', l:win)
  let s:input_winid = l:win

  " Reset winid if the window is closed by any means (e.g. :q).
  execute 'autocmd WinClosed ' . l:win . ' ++once let s:input_winid = -1'

  " Restore saved draft if one exists.
  if !empty(s:input_saved)
    call nvim_buf_set_lines(l:buf, 0, -1, v:false, s:input_saved)
    call nvim_win_set_cursor(l:win, [len(s:input_saved), 0])
  endif

  for l:mode in ['n', 'i']
    call nvim_buf_set_keymap(l:buf, l:mode, '<C-s>',
          \ '<Cmd>call claude#_input_submit()<CR>',
          \ {'noremap': v:true, 'silent': v:true})
  endfor
  call nvim_buf_set_keymap(l:buf, 'n', '<Esc>',
        \ '<Cmd>call claude#_input_cancel()<CR>',
        \ {'noremap': v:true, 'silent': v:true})
  call nvim_buf_set_keymap(l:buf, 'n', 'q',
        \ '<Cmd>call claude#_input_cancel()<CR>',
        \ {'noremap': v:true, 'silent': v:true})

  startinsert!
endfunction

" Toggle-off: save current float content as draft then close.
function! s:input_float_save_and_close() abort
  let l:lines = nvim_buf_get_lines(nvim_win_get_buf(s:input_winid), 0, -1, v:false)
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  let s:input_saved = l:lines
  call nvim_win_close(s:input_winid, v:true)
  " s:input_winid is reset by the WinClosed autocmd.
endfunction

" Send: collect content, close, send to Claude, clear draft.
function! claude#_input_submit() abort
  let l:buf   = bufnr('%')
  let l:win   = nvim_buf_get_var(l:buf, 'claude_input_win')
  let l:lines = nvim_buf_get_lines(l:buf, 0, -1, v:false)

  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile

  if nvim_win_is_valid(l:win)
    call nvim_win_close(l:win, v:true)
  endif
  let s:input_saved = []

  if !empty(l:lines)
    call s:send_input(join(l:lines, "\n"))
  endif
endfunction

" Cancel: discard the draft and close.
function! claude#_input_cancel() abort
  let l:win = nvim_buf_get_var(bufnr('%'), 'claude_input_win')
  if nvim_win_is_valid(l:win)
    call nvim_win_close(l:win, v:true)
  endif
  let s:input_saved = []
endfunction

" ── Vim 8 split fallback ──────────────────────────────────────────────────────

function! s:input_split() abort
  botright 10new
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile filetype=markdown
  setlocal statusline=Claude\ Input\ ——\ <C-s>\ send,\ <Esc>\ cancel

  let s:input_bufnr8 = bufnr('%')

  " Restore saved draft if one exists.
  if !empty(s:input_saved)
    call setline(1, s:input_saved)
    execute len(s:input_saved)
  endif

  nnoremap <buffer> <silent> <C-s> :call claude#_input_submit_split()<CR>
  inoremap <buffer> <silent> <C-s> <Esc>:call claude#_input_submit_split()<CR>
  nnoremap <buffer> <silent> <Esc> :call claude#_input_cancel_split()<CR>
  nnoremap <buffer> <silent> q     :call claude#_input_cancel_split()<CR>

  startinsert!
endfunction

" Toggle-off: save split content as draft then close.
function! s:input_split_save_and_close() abort
  let l:lines = getbufline(s:input_bufnr8, 1, '$')
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  let s:input_saved = l:lines
  execute 'bwipeout! ' . s:input_bufnr8
  let s:input_bufnr8 = -1
endfunction

" Send: collect content, close, send to Claude, clear draft.
function! claude#_input_submit_split() abort
  let l:lines = getline(1, '$')
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  bwipeout!
  let s:input_bufnr8 = -1
  let s:input_saved  = []
  if !empty(l:lines)
    call s:send_input(join(l:lines, "\n"))
  endif
endfunction

" Cancel: discard the draft and close.
function! claude#_input_cancel_split() abort
  bwipeout!
  let s:input_bufnr8 = -1
  let s:input_saved  = []
endfunction

" ── common ────────────────────────────────────────────────────────────────────

" Open or focus Claude then send {text}, waiting for startup if needed.
function! s:send_input(text) abort
  if !s:is_open()
    call claude#open()
    call s:send_when_ready(a:text, 15)
  else
    call claude#focus()
    call s:send(a:text)
  endif
endfunction
