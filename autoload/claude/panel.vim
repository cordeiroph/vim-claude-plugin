" ── agent session panel ──────────────────────────────────────────────────────
"
" A NERDTree-style side panel listing every Claude session grouped
" Project > Worktree > Branch. The panel owns presentation only: it never
" starts, stops or inspects a process directly — autoload/claude/session.vim
" is the single source of truth, reached through claude#session#tree().
"
" Hiding the panel only closes its window. Sessions keep running.

let s:bufnr      = -1
let s:timer      = -1
let s:prev_winid = -1
let s:show_help  = 0
let s:collapsed  = {}     " group key -> 1 while that node is folded shut
let s:rendered   = []     " session ids in the order last drawn

" This panel is the top sidebar; autoload/claude/sidebar.vim keeps the column
" ordered and owns everything the panels share.
call claude#sidebar#register({
      \ 'name':     'sessions',
      \ 'priority': 10,
      \ 'Winid':    function('claude#panel#winid'),
      \ 'Height':   {-> get(g:, 'claude_panel_height', 15)},
      \ })

" ── glyphs ───────────────────────────────────────────────────────────────────

" Status glyph for the panel and the picker.
function! claude#panel#icon(status) abort
  let l:default = claude#sidebar#ascii()
        \ ? {'active': '[A]', 'idle': '[I]', 'closed': '[C]'}
        \ : {'active': '●',   'idle': '○',   'closed': '✗'}
  let l:icons = extend(l:default, get(g:, 'claude_panel_icons', {}))
  return get(l:icons, a:status, '?')
endfunction

function! s:marker(key) abort
  return claude#sidebar#marker(empty(a:key) || !has_key(s:collapsed, a:key))
endfunction

" ── window ───────────────────────────────────────────────────────────────────

function! s:width() abort
  return get(g:, 'claude_panel_width', 35)
endfunction

function! claude#panel#winid() abort
  return s:bufnr == -1 ? -1 : bufwinid(s:bufnr)
endfunction

" ── NERDTree stacking ───────────────────────────────────────────────────────
"
" The mechanics live in autoload/claude/sidebar.vim, which keeps every open
" sidebar in one column ordered by priority. These wrappers stay because
" plugin/claude.vim's autocommands and the tests call them by name.

function! claude#panel#stack() abort
  call claude#sidebar#stack()
endfunction

function! claude#panel#_nerdtree_init() abort
  call claude#sidebar#_nerdtree_init()
endfunction

function! claude#panel#_win_closed(winid) abort
  call claude#sidebar#_win_closed(a:winid)
endfunction

function! claude#panel#nerdtree_bufnr() abort
  return claude#sidebar#nerdtree_bufnr()
endfunction

function! claude#panel#is_open() abort
  return s:bufnr != -1 && bufexists(s:bufnr) && bufwinid(s:bufnr) != -1
endfunction

function! claude#panel#bufnr() abort
  return s:bufnr
endfunction

function! claude#panel#toggle() abort
  if claude#panel#is_open()
    call claude#panel#close()
  else
    call claude#panel#open()
  endif
endfunction

function! claude#panel#open() abort
  if claude#panel#is_open()
    call win_gotoid(bufwinid(s:bufnr))
    return
  endif

  " Remember where the user was: `i` and `s` split that window, not the panel.
  let s:prev_winid = win_getid()

  call claude#sidebar#open_window(s:width())

  if s:bufnr != -1 && bufexists(s:bufnr)
    execute 'buffer ' . s:bufnr
  else
    enew
    let s:bufnr = bufnr('%')
    silent! file [claude-sessions]
  endif

  call claude#sidebar#buf_options('claudesessions')
  call s:setup_keys()
  call s:setup_highlight()

  " Settle the geometry before the transcript scan, which is slow enough that
  " Vim could otherwise redraw the unstacked layout first.
  call claude#panel#stack()

  call claude#session#refresh()
  call s:render()
  call s:start_timer()
endfunction

" Hide the panel. Sessions and their windows are untouched.
function! claude#panel#close() abort
  call s:stop_timer()
  if s:bufnr == -1
    return
  endif
  let l:win = bufwinid(s:bufnr)
  if l:win == -1
    return
  endif
  " Never close the last window of the last tab: there would be nothing left.
  if winnr('$') <= 1 && tabpagenr('$') <= 1
    return
  endif
  call win_execute(l:win, 'close')
endfunction

" Colour the panel the way NERDTree colours its tree, so the two halves of the
" sidebar read as one thing.
"
" Each group prefers NERDTree's own highlight group when it is defined — so
" restyling NERDTree restyles the panel too — and otherwise falls back to the
" group NERDTree itself links to, which gives the same colours without
" depending on NERDTree being loaded at all.
"
"   header / project   NERDTreeCWD       Statement   (its root line)
"   worktree / branch  NERDTreeDir       Directory   (its directories)
"   fold marker        NERDTreeClosable  Directory   (its arrows)
"   session name       NERDTreeFile      Normal      (its files)
"   active icon        NERDTreeFlags     Number      (its flags)
"   help text          NERDTreeHelp      String
let s:highlights = [
      \ ['ClaudeSessionHeader',     'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionProject',    'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionWorktree',   'NERDTreeDir',      'Directory'],
      \ ['ClaudeSessionBranch',     'NERDTreeDir',      'Directory'],
      \ ['ClaudeSessionMarker',     'NERDTreeClosable', 'Directory'],
      \ ['ClaudeSessionName',       'NERDTreeFile',     'Normal'],
      \ ['ClaudeSessionActive',     'NERDTreeFlags',    'Number'],
      \ ['ClaudeSessionIdle',       '',                 'Comment'],
      \ ['ClaudeSessionClosed',     '',                 'Comment'],
      \ ['ClaudeSessionNameClosed', '',                 'NonText'],
      \ ['ClaudeSessionHelp',       'NERDTreeHelp',     'String'],
      \ ]

function! claude#panel#_relink() abort
  call claude#sidebar#link_highlights(s:highlights)
endfunction

" Buffer-local syntax. Must only ever run in the panel buffer.
function! s:setup_syntax() abort
  silent! syntax clear
  let l:m = claude#sidebar#marker_class()

  " Tree nodes, identified by their indent.
  execute 'syntax match ClaudeSessionProject  /^' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker'
  execute 'syntax match ClaudeSessionWorktree /^  ' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker'
  execute 'syntax match ClaudeSessionBranch   /^    ' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker'
  execute 'syntax match ClaudeSessionMarker   /' . l:m . '/ contained'

  " Session rows: the glyph carries the status, the name is coloured like a
  " NERDTree file — except for a closed session, which is dimmed whole.
  for [l:status, l:group, l:name] in [
        \ ['active', 'ClaudeSessionActive', 'ClaudeSessionName'],
        \ ['idle',   'ClaudeSessionIdle',   'ClaudeSessionName'],
        \ ['closed', 'ClaudeSessionClosed', 'ClaudeSessionNameClosed'],
        \ ]
    " The glyph is user-configurable and may contain regex metacharacters
    " (the ASCII set is literally "[A]"), so escape it into a plain match.
    execute 'syntax match ' . l:group . ' /'
          \ . escape(claude#panel#icon(l:status), '/\.*$^~[]')
          \ . '/ nextgroup=' . l:name . ' skipwhite'
  endfor
  syntax match ClaudeSessionName       /.*$/ contained
  syntax match ClaudeSessionNameClosed /.*$/ contained

  syntax match ClaudeSessionHeader /\%1lClaude Sessions.*/
  " The footer, and the inline help block, whose lines are the only ones
  " indented by a single space.
  syntax match ClaudeSessionHelp /^? help$/
  syntax match ClaudeSessionHelp /^ \S.*$/
endfunction

function! s:setup_highlight() abort
  call claude#sidebar#link_highlights(s:highlights)
  call s:setup_syntax()
endfunction

" ── rendering ────────────────────────────────────────────────────────────────

function! s:fit(indent, text) abort
  return claude#sidebar#fit(s:width(), a:indent, a:text)
endfunction

function! s:home_relative(path) abort
  return claude#sidebar#home_relative(a:path)
endfunction

function! s:node(kind, key, id, indent, label, status) abort
  return {
        \ 'kind':   a:kind,
        \ 'key':    a:key,
        \ 'id':     a:id,
        \ 'indent': a:indent,
        \ 'label':  a:label,
        \ 'status': a:status,
        \ }
endfunction

function! s:session_line(node) abort
  return a:node.indent . claude#panel#icon(a:node.status) . ' ' . a:node.label
endfunction

" Same-named sessions inside one branch group get a display-only suffix; the
" stored name is left alone.
function! s:disambiguate(sessions) abort
  let l:seen   = {}
  let l:labels = []
  for l:rec in a:sessions
    let l:n = get(l:seen, l:rec.name, 0) + 1
    let l:seen[l:rec.name] = l:n
    call add(l:labels, l:n == 1 ? l:rec.name : l:rec.name . ' (' . l:n . ')')
  endfor
  return l:labels
endfunction

function! s:build() abort
  let l:lines = []
  let l:nodes = []
  let l:live  = len(claude#session#live())

  let l:title = 'Claude Sessions'
  let l:count = '(' . l:live . ')'
  let l:pad   = max([1, s:width() - strchars(l:title) - strchars(l:count) - 1])
  call add(l:lines, l:title . repeat(' ', l:pad) . l:count)
  call add(l:nodes, s:node('header', '', '', '', l:title, ''))

  if s:show_help
    for l:h in [
          \ '',
          \ ' <CR>/o open   i split   s vsplit',
          \ ' t tab     n new    r rename',
          \ ' d end     D purge  R refresh',
          \ ' <Space> fold   q hide   ? help',
          \ ]
      call add(l:lines, l:h)
      call add(l:nodes, s:node('help', '', '', '', l:h, ''))
    endfor
  endif

  call add(l:lines, '')
  call add(l:nodes, s:node('blank', '', '', '', '', ''))

  let l:tree = claude#session#tree()
  if empty(l:tree)
    call add(l:lines, '  (no sessions)')
    call add(l:nodes, s:node('empty', '', '', '', '', ''))
  endif

  for l:proj in l:tree
    let l:n = s:node('project', l:proj.key, '', '', l:proj.label, '')
    call add(l:lines, s:marker(l:proj.key) . ' ' . s:fit('', l:proj.label))
    call add(l:nodes, l:n)
    if has_key(s:collapsed, l:proj.key)
      continue
    endif

    for l:wt in l:proj.worktrees
      let l:label = s:home_relative(l:wt.label)
      call add(l:lines, '  ' . s:marker(l:wt.key) . ' ' . s:fit('  ', l:label))
      call add(l:nodes, s:node('worktree', l:wt.key, '', '  ', l:wt.path, ''))
      if has_key(s:collapsed, l:wt.key)
        continue
      endif

      for l:br in l:wt.branches
        call add(l:lines,
              \ '    ' . s:marker(l:br.key) . ' ' . s:fit('    ', l:br.label))
        call add(l:nodes, s:node('branch', l:br.key, '', '    ', l:br.label, ''))
        if has_key(s:collapsed, l:br.key)
          continue
        endif

        let l:labels = s:disambiguate(l:br.sessions)
        let l:i = 0
        for l:rec in l:br.sessions
          let l:node = s:node('session', '', l:rec.id, '      ',
                \ s:fit('      ', l:labels[l:i]), l:rec.status)
          call add(l:lines, s:session_line(l:node))
          call add(l:nodes, l:node)
          let l:i += 1
        endfor
      endfor
    endfor
  endfor

  call add(l:lines, '')
  call add(l:nodes, s:node('blank', '', '', '', '', ''))
  call add(l:lines, '? help')
  call add(l:nodes, s:node('help', '', '', '', '? help', ''))

  return [l:lines, l:nodes]
endfunction

function! s:render() abort
  if s:bufnr == -1 || !bufexists(s:bufnr)
    return
  endif
  let [l:lines, l:nodes] = s:build()

  let l:win     = bufwinid(s:bufnr)
  let l:restore = (l:win != -1 && win_getid() == l:win) ? line('.') : 0

  call setbufvar(s:bufnr, '&modifiable', 1)
  silent! call deletebufline(s:bufnr, 1, '$')
  call setbufline(s:bufnr, 1, l:lines)
  call setbufvar(s:bufnr, '&modifiable', 0)
  call setbufvar(s:bufnr, 'claude_panel_nodes', l:nodes)

  let s:rendered = map(filter(copy(l:nodes),
        \ {_, n -> n.kind ==# 'session'}), {_, n -> n.id})

  if l:restore > 0
    call win_execute(l:win,
          \ 'call cursor(' . min([l:restore, len(l:lines)]) . ', 1)')
  endif
endfunction

" Rebuild the tree. Safe to call when the panel is not open.
function! claude#panel#refresh() abort
  if !claude#panel#is_open()
    return
  endif
  call s:render()
endfunction

" ── status polling ───────────────────────────────────────────────────────────

function! s:start_timer() abort
  call s:stop_timer()
  let l:ms = get(g:, 'claude_panel_refresh_ms', 2000)
  if l:ms > 0
    let s:timer = timer_start(l:ms, function('s:tick'), {'repeat': -1})
  endif
endfunction

function! s:stop_timer() abort
  if s:timer != -1
    call timer_stop(s:timer)
    let s:timer = -1
  endif
endfunction

" Poll only while the panel is visible: there is no background cost when it
" is hidden.
function! s:tick(timer) abort
  if !claude#panel#is_open()
    call s:stop_timer()
    return
  endif
  if claude#session#poll()
    call s:repaint()
  endif
  " Backstop: re-stack if something disturbed the layout. Cheap, and a no-op
  " when the panel and NERDTree already share a column.
  call claude#panel#stack()
endfunction

" Repaint the status column in place. Falls back to a full rebuild when the
" set of sessions itself changed, since the tree shape may differ.
function! s:repaint() abort
  let l:nodes = getbufvar(s:bufnr, 'claude_panel_nodes', [])
  let l:ids   = map(filter(copy(claude#session#list()),
        \ {_, r -> 1}), {_, r -> r.id})
  if sort(copy(l:ids)) != sort(copy(s:rendered))
    call s:render()
    return
  endif

  call setbufvar(s:bufnr, '&modifiable', 1)
  let l:i = 0
  for l:node in l:nodes
    let l:i += 1
    if l:node.kind !=# 'session'
      continue
    endif
    let l:status = claude#session#status(l:node.id)
    if l:status ==# l:node.status
      continue
    endif
    let l:node.status = l:status
    call setbufline(s:bufnr, l:i, s:session_line(l:node))
  endfor
  call setbufvar(s:bufnr, '&modifiable', 0)
endfunction

" ── keymaps ──────────────────────────────────────────────────────────────────

function! s:setup_keys() abort
  " Vim does not turn a double-click into <CR> on its own: it only moves
  " the cursor, so the click has to be mapped explicitly. NERDTree does
  " the same thing through <LeftRelease>. Needs 'mouse' to include n or a.
  nnoremap <buffer> <silent> <2-LeftMouse> :call <SID>activate()<CR>
  nnoremap <buffer> <silent> <CR>    :call <SID>activate()<CR>
  nnoremap <buffer> <silent> o       :call <SID>activate()<CR>
  nnoremap <buffer> <silent> i       :call <SID>open('split')<CR>
  nnoremap <buffer> <silent> s       :call <SID>open('vsplit')<CR>
  nnoremap <buffer> <silent> t       :call <SID>open('tab')<CR>
  nnoremap <buffer> <silent> n       :call <SID>new()<CR>
  nnoremap <buffer> <silent> r       :call <SID>rename()<CR>
  nnoremap <buffer> <silent> d       :call <SID>end_session()<CR>
  nnoremap <buffer> <silent> D       :call <SID>purge()<CR>
  nnoremap <buffer> <silent> R       :call <SID>full_refresh()<CR>
  nnoremap <buffer> <silent> za      :call <SID>fold()<CR>
  nnoremap <buffer> <silent> <Space> :call <SID>fold()<CR>
  nnoremap <buffer> <silent> q       :call claude#panel#close()<CR>
  nnoremap <buffer> <silent> ?       :call <SID>help()<CR>
endfunction

function! s:current_node() abort
  let l:nodes = get(b:, 'claude_panel_nodes', [])
  let l:idx   = line('.') - 1
  if l:idx < 0 || l:idx >= len(l:nodes)
    return {}
  endif
  return l:nodes[l:idx]
endfunction

function! s:activate() abort
  let l:node = s:current_node()
  if empty(l:node)
    return
  endif
  if l:node.kind ==# 'session'
    call claude#panel#open_session(l:node.id, 'here')
  elseif !empty(l:node.key)
    call s:fold()
  endif
endfunction

function! s:open(mode) abort
  let l:node = s:current_node()
  if empty(l:node) || l:node.kind !=# 'session'
    return
  endif
  call claude#panel#open_session(l:node.id, a:mode)
endfunction

function! s:fold() abort
  let l:node = s:current_node()
  if empty(l:node) || empty(l:node.key)
    return
  endif
  if has_key(s:collapsed, l:node.key)
    call remove(s:collapsed, l:node.key)
  else
    let s:collapsed[l:node.key] = 1
  endif
  call s:render()
endfunction

function! s:help() abort
  let s:show_help = !s:show_help
  call s:render()
endfunction

function! s:full_refresh() abort
  call claude#session#refresh()
  call s:render()
endfunction

function! s:new() abort
  call s:enter_main()
  let l:id = claude#session#new()
  if !empty(l:id)
    call claude#session#touch_focus(l:id)
  endif
endfunction

function! s:rename() abort
  let l:node = s:current_node()
  if empty(l:node) || l:node.kind !=# 'session'
    return
  endif
  let l:rec = claude#session#get(l:node.id)
  let l:new = input('Rename to: ', l:rec.name)
  redraw
  if !empty(l:new)
    call claude#session#rename(l:node.id, l:new)
  endif
endfunction

function! s:end_session() abort
  let l:node = s:current_node()
  if empty(l:node) || l:node.kind !=# 'session'
    return
  endif
  let l:rec = claude#session#get(l:node.id)
  if confirm('End session "' . l:rec.name . '"?', "&Yes\n&No", 2) == 1
    call claude#session#delete(l:node.id)
  endif
endfunction

function! s:purge() abort
  let l:node = s:current_node()
  if empty(l:node) || l:node.kind !=# 'session'
    return
  endif
  let l:rec = claude#session#get(l:node.id)
  if confirm('Purge "' . l:rec.name . '" and delete its transcript?',
        \ "&Yes\n&No", 2) != 1
    return
  endif
  if confirm('This cannot be undone. Really delete the transcript?',
        \ "&Yes\n&No", 2) != 1
    return
  endif
  call claude#session#purge(l:node.id)
endfunction

" ── opening a session ────────────────────────────────────────────────────────

function! s:enter_main() abort
  return claude#sidebar#enter_main(s:prev_winid)
endfunction

function! s:make_window(mode) abort
  call claude#sidebar#make_window(a:mode, s:prev_winid)
endfunction

" Show {id} in the main area. {mode} is 'here', 'split', 'vsplit' or 'tab'.
function! claude#panel#open_session(id, mode) abort
  let l:rec = claude#session#get(a:id)
  if empty(l:rec)
    return
  endif

  " Already visible in this tab: jump to it rather than duplicating the
  " window. A new tab is always created on request, though.
  if a:mode !=# 'tab' && l:rec.bufnr != -1
    let l:win = bufwinid(l:rec.bufnr)
    if l:win != -1
      call win_gotoid(l:win)
      call claude#session#touch_focus(a:id)
      call claude#enter_insert(l:rec.bufnr)
      return
    endif
  endif

  if claude#session#status(a:id) ==# 'closed'
    if claude#session#is_foreign_active(a:id)
      echohl WarningMsg
      echomsg 'claude.vim: session appears active in another editor'
            \ . ' — use R to refresh'
      echohl None
      return
    endif
    call s:make_window(a:mode)
    if empty(claude#session#resume(a:id, ''))
      return
    endif
  else
    call s:make_window(a:mode)
    execute 'buffer ' . l:rec.bufnr
    call claude#apply_buf_options(a:id)
  endif

  call claude#session#touch_focus(a:id)
  call claude#enter_insert(claude#session#get(a:id).bufnr)
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

function! claude#panel#_lines() abort
  if s:bufnr == -1 || !bufexists(s:bufnr)
    return []
  endif
  return getbufline(s:bufnr, 1, '$')
endfunction

function! claude#panel#_reset() abort
  call s:stop_timer()
  if s:bufnr != -1 && bufexists(s:bufnr)
    silent! execute 'bwipeout! ' . s:bufnr
  endif
  let s:bufnr      = -1
  let s:prev_winid = -1
  let s:show_help  = 0
  let s:collapsed  = {}
  let s:rendered   = []
  call claude#sidebar#_reset()
endfunction
