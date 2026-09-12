" ── claude.vim core ──────────────────────────────────────────────────────────
"
" Sessions live in a single global registry (autoload/claude/session.vim), not
" one per tab: several Claude terminals can run side by side. This file is the
" command surface — opening, focusing, closing and sending text — and resolves
" which session a command acts on via claude#session#target().
"
" Target resolution is asynchronous because popup_menu() is: the commands hand
" a callback to claude#session#target() rather than returning a session.

" ── public API ───────────────────────────────────────────────────────────────

" Open Claude: focus the current session, ask which one when several are
" running, or start a new one when there are none.
function! claude#open() abort
  call claude#session#target('Open Claude session', function('s:focus_id'))
endfunction

" Start a new session regardless of what is already running.
"
" a:1 name     — '' asks for one (unless the prompts are turned off)
" a:2 provider — which CLI to run; '' or absent means g:claude_provider
function! claude#new(...) abort
  call claude#session#new(a:0 > 0 ? a:1 : '', v:null,
        \ a:0 > 1 ? a:2 : '')
endfunction

" Toggle the Claude window: hide it if visible, show it if hidden, open a new
" session if none exists.
function! claude#toggle() abort
  call claude#session#target('Toggle Claude session', function('s:toggle_id'))
endfunction

" Move the cursor to a Claude window, revealing or resuming it as needed.
function! claude#focus() abort
  call claude#session#target('Focus Claude session', function('s:focus_id'))
endfunction

" End a session: stop the job and wipe its buffer. The conversation stays on
" disk and can be resumed from the panel or :ClaudeResume.
function! claude#close() abort
  if empty(claude#session#live())
    return
  endif
  call claude#session#target('Close Claude session', function('s:close_id'))
endfunction

" Rename a session. With no argument the new name is prompted for.
function! claude#rename(...) abort
  if empty(claude#session#live())
    return
  endif
  let l:name = a:0 > 0 ? a:1 : ''
  call claude#session#target('Rename which session',
        \ {id -> s:rename_id(id, l:name)})
endfunction

function! s:focus_id(id) abort
  if empty(a:id)
    return
  endif
  let l:rec = claude#session#get(a:id)
  if empty(l:rec)
    return
  endif

  if claude#session#status(a:id) ==# 'closed'
    if empty(claude#session#resume(a:id))
      return
    endif
    let l:rec = claude#session#get(a:id)
  else
    let l:win = bufwinid(l:rec.bufnr)
    if l:win != -1
      call win_gotoid(l:win)
    else
      " Session alive but not displayed — bring its buffer back into a split.
      execute claude#split_cmd()
      execute 'buffer ' . l:rec.bufnr
      call claude#apply_buf_options(a:id)
    endif
  endif

  call claude#session#touch_focus(a:id)
  call claude#enter_insert(l:rec.bufnr)
endfunction

function! s:toggle_id(id) abort
  if empty(a:id)
    return
  endif
  let l:rec = claude#session#get(a:id)
  if empty(l:rec)
    return
  endif
  if l:rec.bufnr != -1 && bufwinid(l:rec.bufnr) != -1
    " Visible — hide it. The buffer stays alive, so the session continues.
    call win_execute(bufwinid(l:rec.bufnr), 'hide')
  else
    call s:focus_id(a:id)
  endif
endfunction

function! s:close_id(id) abort
  if !empty(a:id)
    call claude#session#delete(a:id)
  endif
endfunction

function! s:rename_id(id, name) abort
  if empty(a:id)
    return
  endif
  let l:name = a:name
  if empty(l:name)
    let l:rec  = claude#session#get(a:id)
    let l:name = input('Rename to: ', get(l:rec, 'name', ''))
    redraw
  endif
  if !empty(l:name)
    call claude#session#rename(a:id, l:name)
  endif
endfunction

" ── exit handling ────────────────────────────────────────────────────────────

" Stop every running Claude job without wiping buffers. Called from ExitPre —
" before Vim's E947 check — so :q / :qall can proceed cleanly. VimLeavePre
" then calls close_all() to do the final buffer wipeout.
"
" With many sessions the per-job waits would add up, so the total is capped:
" whatever is still running is left to VimLeavePre.
function! claude#_stop_jobs() abort
  let l:start = reltime()
  for l:bufnr in claude#session#bufnrs()
    call claude#session#stop_job(l:bufnr)
    if str2float(reltimestr(reltime(l:start))) > 2.0
      break
    endif
  endfor
endfunction

" QuitPre fallback for Vim builds without ExitPre (before patch 8.1.0446).
" QuitPre also fires when closing an ordinary split, which must leave every
" session alone, so approximate ExitPre: stop the jobs only when the window
" being quit is the last one that is neither a Claude terminal nor the panel.
" Best-effort — with several tabs open QuitPre can't tell :q from :qall.
function! claude#_quit_pre() abort
  if tabpagenr('$') > 1
    return
  endif
  let l:claude_bufs  = claude#session#bufnrs()
  let l:sidebar_bufs = claude#sidebar#bufnrs()
  let l:others = 0
  for l:winnr in range(1, winnr('$'))
    let l:bufnr = winbufnr(l:winnr)
    " Sidebars are not ordinary windows: a visible NERDTree or panel must not
    " stop a real :q from being recognised as the last one.
    if index(l:claude_bufs, l:bufnr) == -1
          \ && index(l:sidebar_bufs, l:bufnr) == -1
      let l:others += 1
    endif
  endfor
  if l:others <= 1
    call claude#_stop_jobs()
  endif
endfunction

" Wipe every Claude terminal buffer. Called from VimLeavePre after the jobs
" have already been stopped by claude#_stop_jobs() in ExitPre.
function! claude#close_all() abort
  for l:bufnr in claude#session#bufnrs()
    call claude#session#stop_job(l:bufnr)
    silent! execute 'bwipeout! ' . l:bufnr
  endfor
endfunction

" ── window helpers ───────────────────────────────────────────────────────────

" Move the cursor to an adjacent window using standard Vim wincmd directions
" (h=left, l=right, k=up, j=down).
function! claude#win_move(dir) abort
  execute 'wincmd ' . a:dir
endfunction

" Returns the Ex command that creates the Claude split at the configured
" anchor. botright/topleft pin the new window to the very edge of the screen
" so it doesn't push other splits around.
function! claude#split_cmd() abort
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

" Apply buffer-local options to the current Claude terminal window and tag the
" buffer with its session id, so any window can be mapped back to a record.
function! claude#apply_buf_options(id) abort
  let b:claude_session_id = a:id
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

" Enter terminal-insert mode, using feedkeys so the mode switch happens after
" the current command sequence finishes. Guards against feeding 'i' to a
" terminal that is already live (insert mode), which would type into Claude.
function! claude#enter_insert(bufnr) abort
  if a:bufnr == -1 || !bufexists(a:bufnr) || !has('terminal')
    return
  endif
  if term_getstatus(a:bufnr) =~# 'normal'
    call feedkeys('i', 'n')
  endif
endfunction

" WinEnter hook: remember which session was most recently focused, so the
" picker can offer the likeliest target first.
function! claude#_win_enter() abort
  " Remember the last ordinary window, so a file opened from a sidebar lands
  " where the user was actually working.
  call claude#sidebar#note_focus()
  let l:id = get(b:, 'claude_session_id', '')
  if !empty(l:id)
    call claude#session#touch_focus(l:id)
  endif
endfunction

" ── explain ──────────────────────────────────────────────────────────────────

" Send an explain prompt for the current file (mode='n') or the current visual
" selection (mode='v'), to whichever session the user is working in.
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

  call claude#session#target('Explain in which session',
        \ {id -> s:deliver(id, l:prompt)})
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

" ── sending ──────────────────────────────────────────────────────────────────

" Send {text} to {id}, resuming it and waiting for startup when necessary.
function! s:deliver(id, text) abort
  if empty(a:id)
    return
  endif
  if claude#session#status(a:id) ==# 'closed'
    if empty(claude#session#resume(a:id))
      return
    endif
  endif
  " send_when_ready() returns immediately once the terminal has drawn
  " anything, so an established session is not delayed by the poll.
  call s:send_when_ready(a:id, a:text, 15)
endfunction

" Poll the terminal every 300 ms until output appears (Claude's startup UI is
" visible), then send {text}. Gives up and sends anyway after {retries} tries
" so the caller is never silently dropped.
function! s:send_when_ready(id, text, retries) abort
  if claude#session#status(a:id) ==# 'closed'
    return
  endif
  let l:bufnr = claude#session#get(a:id).bufnr
  if s:terminal_scan(l:bufnr, '\S') || a:retries <= 0
    call s:send(a:id, a:text)
  else
    call timer_start(300, {-> s:send_when_ready(a:id, a:text, a:retries - 1)})
  endif
endfunction

" Scan up to 50 lines of a Claude terminal buffer for lines matching
" {pattern}. Returns true on the first match, false if none found.
function! s:terminal_scan(bufnr, pattern) abort
  if a:bufnr == -1 || !bufexists(a:bufnr)
    return v:false
  endif
  for l:i in range(1, 50)
    if term_getline(a:bufnr, l:i) =~# a:pattern
      return v:true
    endif
  endfor
  return v:false
endfunction

" Send {text} to a session using bracketed-paste escape sequences. Bracketed
" paste tells Claude's input handler to treat the block as pasted text, so
" embedded newlines don't trigger premature submission.
function! s:send(id, text) abort
  let l:rec = claude#session#get(a:id)
  if empty(l:rec) || l:rec.bufnr == -1 || !bufexists(l:rec.bufnr)
    return
  endif
  call term_sendkeys(l:rec.bufnr, "\e[200~" . a:text . "\e[201~\r")
  call s:focus_id(a:id)
endfunction

" ── model selection ──────────────────────────────────────────────────────────

" Switch the model a session is running on.
"
" The session is resolved first, because which models there are to choose from
" and how the choice is delivered are both its provider's answer: Claude and Pi
" both take `/model <id>`, another CLI may take nothing at all.
function! claude#select_model() abort
  call claude#session#target('Switch model in which session',
        \ function('s:choose_model'))
endfunction

function! s:choose_model(id) abort
  if empty(a:id)
    return
  endif
  let l:rec      = claude#session#get(a:id)
  let l:provider = empty(l:rec)
        \ ? claude#provider#default() : claude#provider#of(l:rec)
  let l:label    = claude#provider#label(l:provider)

  if !claude#provider#has(l:provider, 'model_text')
    echomsg 'claude.vim: ' . l:label . ' has no in-session model switch'
    return
  endif
  " With no list to offer, hand over to the CLI's own picker rather than
  " inventing model names: Pi opens its selector on a bare /model, and a user
  " who wants the numbered list here sets g:claude_providers.<name>.models.
  let l:models = get(claude#provider#get(l:provider), 'models', [])
  if empty(l:models)
    call s:deliver(a:id, claude#provider#call(l:provider, 'model_text',
          \ [''], ''))
    return
  endif

  " inputlist() expects item 0 to be a header and items 1..N to be choices.
  let l:menu = ['Switch ' . l:label . ' model:']
  let l:i = 1
  for l:m in l:models
    call add(l:menu, printf('%d. %s', l:i, l:m))
    let l:i += 1
  endfor

  let l:choice = inputlist(l:menu)
  redraw
  if l:choice < 1 || l:choice > len(l:models)
    return
  endif

  let l:text = claude#provider#call(l:provider, 'model_text',
        \ [l:models[l:choice - 1]], '')
  if !empty(l:text)
    call s:deliver(a:id, l:text)
  endif
endfunction

" ── session resume ───────────────────────────────────────────────────────────

" List the closed sessions known for this directory and reopen the chosen one.
" Names come from the store; sessions never named in Vim fall back to their
" timestamp and first message.
function! claude#resume() abort
  call claude#session#refresh()
  " all(), not list(): the panel buries the sessions nobody named and the ones
  " nobody has touched for days, and resuming one is exactly when you want it
  " back. Each is labelled by its first message.
  let l:closed = filter(claude#session#all(),
        \ {_, r -> r.status ==# 'closed'})

  if empty(l:closed)
    echom 'No previous sessions found for this directory.'
    return
  endif

  let l:menu = ['Resume Claude session:']
  let l:i = 1
  for l:rec in l:closed
    call add(l:menu, printf('%d. %s', l:i, claude#session#label(l:rec)))
    let l:i += 1
  endfor

  let l:choice = inputlist(l:menu)
  redraw
  if l:choice < 1 || l:choice > len(l:closed)
    return
  endif

  " focus_id() resumes a closed session in the configured split.
  call s:focus_id(l:closed[l:choice - 1].id)
endfunction

" ── common ────────────────────────────────────────────────────────────────────

" Send {text} to the resolved session, opening or resuming one as needed.
function! claude#_send_input(text) abort
  call claude#session#target('Send to which session',
        \ {id -> s:deliver(id, a:text)})
endfunction
