" ── agent session panel ──────────────────────────────────────────────────────
"
" A NERDTree-style side panel listing every Claude session. It has two views,
" swapped with g:
"
"   state   what each session is doing — Needs you, Working, Idle, Done.
"           The default, because with several agents running the question is
"           almost always "which one is waiting for me?"
"   place   Group > Branch, for when the question really is "what is
"           happening in that checkout?" A workspace-backed session gets its
"           own group (a workspace is one branch, always); a session run
"           straight in the main checkout shares a group with the repo's
"           other such sessions, split by branch.
"
" The panel owns presentation only: it never starts, stops or inspects a
" process directly — autoload/claude/session.vim is the single source of
" truth, reached through claude#session#groups() and claude#session#tree().
"
" Hiding the panel only closes its window. Sessions keep running.

let s:bufnr      = -1
let s:timer      = -1
let s:prev_winid = -1
let s:show_help  = 0
let s:rendered   = []     " session ids in the order last drawn
let s:grouping   = 'state'
let s:filter     = ''     " while set, only matching sessions are drawn
let s:done_all   = 0      " 1 once the Done group has been asked to show all

" Group key -> 1 while that node is folded shut. The two views use different
" key prefixes — 'st:' here, 'p:' / 'w:' / 'b:' in the tree — so switching
" views with g preserves both sets of folds. Done starts shut: it is the tail,
" and the tail is what nobody wants to scroll past.
let s:collapsed = {'st:done': 1}

" This panel is the top sidebar; autoload/claude/sidebar.vim keeps the column
" ordered and owns everything the panels share.
call claude#sidebar#register({
      \ 'name':     'sessions',
      \ 'priority': 10,
      \ 'Winid':    function('claude#panel#winid'),
      \ 'Height':   {-> claude#sidebar#height_pct(
      \                 'claude_panel_height_pct', 'claude_panel_height', 15)},
      \ })

" ── glyphs ───────────────────────────────────────────────────────────────────

" Status glyph for the panel and the picker.
function! claude#panel#icon(status) abort
  let l:default = claude#sidebar#ascii()
        \ ? {'waiting': '[?]', 'active': '[A]',
        \    'idle':    '[I]', 'closed': '[C]'}
        \ : {'waiting': '✻',   'active': '●',
        \    'idle':    '○',   'closed': '✗'}
  let l:icons = extend(l:default, get(g:, 'claude_panel_icons', {}))
  return get(l:icons, a:status, '?')
endfunction

" How many rows the Done group draws before it stops. Separate from
" g:claude_panel_closed_limit, which caps how many transcripts are read from
" disk: how much is scanned and how much is drawn are different questions.
function! s:done_rows() abort
  return get(g:, 'claude_panel_done_rows', 10)
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
"   branch             NERDTreeDir       Directory   (its directories)
"   fold marker        NERDTreeClosable  Directory   (its arrows)
"   session name       NERDTreeFile      Normal      (its files)
"   active icon        NERDTreeFlags     Number      (its flags)
"   help text          NERDTreeHelp      String
let s:highlights = [
      \ ['ClaudeSessionHeader',     'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionProject',    'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionBranch',     '',                 'Type'],
      \ ['ClaudeSessionMarker',     'NERDTreeClosable', 'Directory'],
      \ ['ClaudeSessionName',       'NERDTreeFile',     'Normal'],
      \ ['ClaudeSessionWaiting',    '',                 'WarningMsg'],
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
  execute 'syntax match ClaudeSessionBranch   /^  ' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker'
  execute 'syntax match ClaudeSessionMarker   /' . l:m . '/ contained'

  " Session rows: the glyph carries the status, the name is coloured like a
  " NERDTree file — except for a closed session, which is dimmed whole.
  for [l:status, l:group, l:name] in [
        \ ['waiting', 'ClaudeSessionWaiting', 'ClaudeSessionName'],
        \ ['active',  'ClaudeSessionActive',  'ClaudeSessionName'],
        \ ['idle',    'ClaudeSessionIdle',    'ClaudeSessionName'],
        \ ['closed',  'ClaudeSessionClosed',  'ClaudeSessionNameClosed'],
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
  " '… 8 more' and '… 12 hidden — I to show': notes, not rows.
  syntax match ClaudeSessionHelp /^\s*[…\.]\{1,3} .*$/
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
        \ 'suffix': '',
        \ 'path':   '',
        \ }
endfunction

function! s:session_line(node) abort
  return s:row(a:node.indent, claude#panel#icon(a:node.status),
        \ a:node.label, a:node.suffix)
endfunction

" A session row: '<indent><glyph> <label>' with {suffix} pushed against the
" right edge, and the label fitted into whatever is left between them. The
" suffix is dropped rather than allowed to squeeze the label to nothing.
function! s:row(indent, glyph, label, suffix) abort
  let l:width = s:width()
  let l:left  = a:indent . a:glyph . ' '
  let l:room  = l:width - strchars(l:left) - strchars(a:suffix) - 1
  if empty(a:suffix) || l:room < 4
    return l:left . claude#sidebar#fit(l:width, l:left, a:label)
  endif
  let l:label = claude#sidebar#fit(l:room + 1, '', a:label)
  let l:pad   = l:width - strchars(l:left) - strchars(l:label)
        \       - strchars(a:suffix)
  return l:left . l:label . repeat(' ', l:pad) . a:suffix
endfunction

" 5m / 3h / 2d since anything happened to a session. A live session is measured
" by its last output, a finished one by when it was last opened — a disk record
" has its last_active set to whenever Vim read it, which is no age at all.
function! s:age(rec) abort
  if get(a:rec, 'bufnr', -1) != -1
    let l:seen = get(a:rec, 'last_active', 0)
  else
    let l:seen = get(a:rec, 'last_focus', 0) > 0
          \ ? a:rec.last_focus : get(a:rec, 'created', 0)
  endif
  if l:seen <= 0
    return ''
  endif
  let l:secs = max([0, localtime() - l:seen])
  if l:secs < 3600
    return (l:secs / 60) . 'm'
  elseif l:secs < 86400
    return (l:secs / 3600) . 'h'
  endif
  return (l:secs / 86400) . 'd'
endfunction

" Where a session lives, in six columns. Its workspace when it has one, else
" the basename of its worktree.
function! s:where(rec) abort
  let l:where = get(a:rec, 'workspace', '')
  if empty(l:where)
    let l:where = fnamemodify(get(a:rec, 'worktree', ''), ':t')
  endif
  return strcharpart(l:where, 0, 6)
endfunction

" The right-hand column of a session row. In the state view nothing else says
" where the session lives, so the row must; in the place view the parent rows
" have already said it three times.
function! s:suffix(rec) abort
  let l:age = s:age(a:rec)
  if s:grouping !=# 'state'
    return l:age
  endif
  let l:where = s:where(a:rec)
  if empty(l:where)
    return l:age
  endif
  return empty(l:age) ? l:where : l:where . ' · ' . l:age
endfunction

" Whether a record survives the active filter. Matching is over everything the
" row could be recognised by, not only what it happens to be showing.
function! s:matches(rec) abort
  if empty(s:filter)
    return 1
  endif
  let l:hay = join([claude#session#label(a:rec), s:where(a:rec),
        \ get(a:rec, 'branch', ''), get(a:rec, 'workspace', '')], ' ')
  return l:hay =~? '\V' . escape(s:filter, '\')
endfunction

function! s:keep(sessions) abort
  return empty(s:filter) ? a:sessions
        \ : filter(copy(a:sessions), {_, r -> s:matches(r)})
endfunction

" Same-named sessions inside one group get a display-only suffix; the
" stored name is left alone.
function! s:disambiguate(sessions) abort
  let l:seen   = {}
  let l:labels = []
  for l:rec in a:sessions
    let l:name = claude#session#label(l:rec)
    let l:n    = get(l:seen, l:name, 0) + 1
    let l:seen[l:name] = l:n
    call add(l:labels, l:n == 1 ? l:name : l:name . ' (' . l:n . ')')
  endfor
  return l:labels
endfunction

" Add a session row to the buffer under construction.
function! s:add_session(lines, nodes, rec, indent, label) abort
  let l:node = s:node('session', '', a:rec.id, a:indent, a:label, a:rec.status)
  let l:node.suffix = s:suffix(a:rec)
  call add(a:lines, s:session_line(l:node))
  call add(a:nodes, l:node)
endfunction

" A group or tree row: '<indent><marker> <label>'.
"
" a:1 — 1 keeps {label} whole even past the window's width: the place tree's
" workspace and branch names are worth a scrollbar, not a truncated guess.
function! s:add_group(lines, nodes, kind, key, indent, label, ...) abort
  let l:text = a:0 > 0 && a:1 ? a:label : s:fit(a:indent, a:label)
  call add(a:lines, a:indent . s:marker(a:key) . ' ' . l:text)
  call add(a:nodes, s:node(a:kind, a:key, '', a:indent, a:label, ''))
endfunction

" An unselectable note, indented under the group it belongs to.
function! s:add_note(lines, nodes, indent, text) abort
  call add(a:lines, a:indent . claude#sidebar#fit(s:width(), a:indent, a:text))
  call add(a:nodes, s:node('note', '', '', a:indent, a:text, ''))
endfunction

" ── the state view ───────────────────────────────────────────────────────────

function! s:build_states(lines, nodes) abort
  " A filter reaches the buried tail: rows asked for by name are not rows to
  " hide, so the hide rule stands down while one is active.
  let l:groups = claude#session#groups(!empty(s:filter))
  let l:drawn  = 0

  for l:group in l:groups
    let l:sessions = s:keep(l:group.sessions)
    if empty(l:sessions) && l:group.buried == 0
      continue
    endif
    let l:drawn += len(l:sessions)

    call s:add_group(a:lines, a:nodes, 'group', l:group.key, '',
          \ l:group.label . ' (' . len(l:sessions) . ')')
    " A fold that hides a match makes the filter a lie, so an active filter
    " opens every group it matched in.
    if has_key(s:collapsed, l:group.key) && empty(s:filter)
      continue
    endif

    let l:cap = l:group.status ==# 'closed' && !s:done_all
          \ ? s:done_rows() : len(l:sessions)
    let l:shown  = l:cap < len(l:sessions) ? l:sessions[0 : l:cap - 1]
          \                                : l:sessions
    let l:labels = s:disambiguate(l:shown)
    let l:i = 0
    for l:rec in l:shown
      call s:add_session(a:lines, a:nodes, l:rec, '  ', l:labels[l:i])
      let l:i += 1
    endfor

    let l:rest = len(l:sessions) - len(l:shown)
    if l:rest > 0
      call add(a:lines, '  ' . s:fit('  ', '… ' . l:rest . ' more'))
      call add(a:nodes,
            \ s:node('more', '', '', '  ', '… ' . l:rest . ' more', ''))
    endif
    " The hide rule is suspended while filtering: rows asked for by name are
    " not buried, so there is nothing to report.
    if l:group.buried > 0 && empty(s:filter)
      call s:add_note(a:lines, a:nodes, '  ',
            \ '… ' . l:group.buried . ' hidden — I to show')
    endif
  endfor

  if empty(l:groups) || (!empty(s:filter) && l:drawn == 0)
    call s:add_note(a:lines, a:nodes, '  ',
          \ empty(s:filter) ? '(no sessions)' : '(nothing matches)')
  endif
endfunction

" ── the place view ───────────────────────────────────────────────────────────

function! s:build_tree(lines, nodes) abort
  let l:tree  = claude#session#tree(!empty(s:filter))
  let l:drawn = 0

  for l:proj in l:tree
    " A group whose every session was filtered out is not drawn at all.
    let l:count = 0
    for l:br in l:proj.branches
      let l:count += len(s:keep(l:br.sessions))
    endfor
    if l:count == 0 && !empty(s:filter)
      continue
    endif
    let l:drawn += l:count

    call s:add_group(a:lines, a:nodes, 'project', l:proj.key, '', l:proj.label,
          \ 1)
    let a:nodes[-1].path = l:proj.path
    if has_key(s:collapsed, l:proj.key) && empty(s:filter)
      continue
    endif

    for l:br in l:proj.branches
      let l:sessions = s:keep(l:br.sessions)
      if empty(l:sessions) && !empty(s:filter)
        continue
      endif
      call s:add_group(a:lines, a:nodes, 'branch', l:br.key, '  ',
            \ l:br.label, 1)
      let a:nodes[-1].path = l:br.path
      if has_key(s:collapsed, l:br.key) && empty(s:filter)
        continue
      endif

      let l:labels = s:disambiguate(l:sessions)
      let l:i = 0
      for l:rec in l:sessions
        call s:add_session(a:lines, a:nodes, l:rec, '    ', l:labels[l:i])
        let l:i += 1
      endfor
    endfor
  endfor

  if empty(l:tree) || (!empty(s:filter) && l:drawn == 0)
    call s:add_note(a:lines, a:nodes, '  ',
          \ empty(s:filter) ? '(no sessions)' : '(nothing matches)')
  endif
endfunction

" ── the whole buffer ─────────────────────────────────────────────────────────

" The right-hand side of the title line: what the panel most wants to say.
function! s:header_count() abort
  if !empty(s:filter)
    return '/' . s:filter
  endif
  let l:live    = claude#session#live()
  let l:waiting = len(filter(copy(l:live), {_, r -> r.status ==# 'waiting'}))
  if l:waiting > 0
    return l:waiting . ' waiting'
  endif
  return '(' . len(l:live) . ')'
endfunction

function! s:build() abort
  let l:lines = []
  let l:nodes = []

  let l:title = 'Claude Sessions'
  let l:count = s:header_count()
  let l:pad   = max([1, s:width() - strchars(l:title) - strchars(l:count)])
  call add(l:lines, l:title . repeat(' ', l:pad) . l:count)
  call add(l:nodes, s:node('header', '', '', '', l:title, ''))

  if s:show_help
    for l:h in [
          \ '',
          \ ' <CR>/o open   i split   s vsplit',
          \ ' t tab     n new here  N new…',
          \ ' g ' . (s:grouping ==# 'state' ? 'by place' : 'by state')
          \   . '  / filter  r rename',
          \ ' d end     D purge  R refresh',
          \ ' I ' . (claude#session#show_hidden() ? 'hide' : 'show')
          \   . ' hidden',
          \ ' <Space> fold   q hide   ? help',
          \ ]
      call add(l:lines, l:h)
      call add(l:nodes, s:node('help', '', '', '', l:h, ''))
    endfor
  endif

  call add(l:lines, '')
  call add(l:nodes, s:node('blank', '', '', '', '', ''))

  if s:grouping ==# 'state'
    call s:build_states(l:lines, l:nodes)
  else
    call s:build_tree(l:lines, l:nodes)
  endif

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
  if s:grouping ==# 'state'
    " The status *is* the row's position here: a session that starts waiting
    " moves to another group. There is no column to repaint in place.
    call s:render()
    return
  endif
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
  nnoremap <buffer> <silent> N       :call <SID>new_asking()<CR>
  nnoremap <buffer> <silent> g       :call <SID>swap_grouping()<CR>
  nnoremap <buffer> <silent> /       :call <SID>prompt_filter()<CR>
  nnoremap <buffer> <silent> r       :call <SID>rename()<CR>
  nnoremap <buffer> <silent> d       :call <SID>end_session()<CR>
  nnoremap <buffer> <silent> D       :call <SID>purge()<CR>
  nnoremap <buffer> <silent> R       :call <SID>full_refresh()<CR>
  " NERDTree's key for "show the hidden ones". Lowercase i keeps splitting.
  nnoremap <buffer> <silent> I       :call <SID>toggle_hidden()<CR>
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
  elseif l:node.kind ==# 'more'
    let s:done_all = 1
    call s:render()
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

" Show or hide the finished sessions the panel buries — the ones nobody named
" and the ones nobody has touched for days. They stay in the registry either
" way.
function! s:toggle_hidden() abort
  call claude#session#toggle_hidden()
  call s:render()
endfunction

function! s:full_refresh() abort
  call claude#session#regroup()
  call claude#session#refresh()
  call s:render()
endfunction

" Swap the top level between what sessions are doing and where they live.
function! s:swap_grouping() abort
  let s:grouping = s:grouping ==# 'state' ? 'place' : 'state'
  call s:render()
endfunction

function! s:prompt_filter() abort
  try
    let l:answer = input('Filter: ', s:filter)
  catch /^Vim:Interrupt$/
    redraw
    return
  endtry
  redraw
  let s:filter = trim(l:answer)
  call s:render()
endfunction

" Where a session started with n should run, as [workspace id, directory].
" At most one of the two is set; both empty means "wherever a session with no
" workspace would have run anyway".
"
" "Where the cursor is" means the whole subtree, not just the row it is on: a
" project row, a branch row and every session row under them all answer with
" the same directory, because that is the checkout you are looking at.
function! s:place_under_cursor() abort
  let l:nodes = get(b:, 'claude_panel_nodes', [])
  let l:idx   = line('.') - 1
  let l:dir   = ''

  if l:idx >= 0 && l:idx < len(l:nodes)
    if l:nodes[l:idx].kind ==# 'session'
      " A session row answers for itself, in either view: it knows both the
      " workspace it belongs to and the directory it ran in.
      let l:rec = claude#session#get(l:nodes[l:idx].id)
      if !empty(get(l:rec, 'workspace', ''))
        return [l:rec.workspace, '']
      endif
      let l:dir = get(l:rec, 'worktree', '')
    endif

    " Otherwise walk up the drawn rows to the nearest node that names a
    " directory: the worktree the cursor is inside, or the project root when
    " it is on the project row itself.
    let l:i = l:idx
    while empty(l:dir) && l:i >= 0
      if !empty(l:nodes[l:i].path)
        let l:dir = l:nodes[l:i].path
      endif
      let l:i -= 1
    endwhile
  endif

  if empty(l:dir) || !isdirectory(l:dir)
    return [get(claude#workspace#current(), 'id', ''), '']
  endif
  " A directory the plugin knows as a workspace is passed as one, so the new
  " session records where it belongs and not merely where it ran.
  for l:ws in claude#workspace#list()
    if l:ws.path ==# l:dir
      return [l:ws.id, '']
    endif
  endfor
  return ['', l:dir]
endfunction

" n — a session here. One question, not two: the row under the cursor already
" says which workspace "here" is, so only the name is worth asking for. Leaving
" it blank is still an answer — the session labels itself from its first
" message — and g:claude_session_prompt_name = 0 skips the question entirely.
function! s:new() abort
  let [l:ws, l:dir] = s:place_under_cursor()
  call s:enter_main()
  let l:id = claude#session#spawn({
        \ 'workspace': l:ws,
        \ 'cwd':       l:dir,
        \ 'ask_name':  get(g:, 'claude_session_prompt_name', 1),
        \ })
  if !empty(l:id)
    call claude#session#touch_focus(l:id)
  endif
endfunction

" N — the deliberate one: which branch, and what to call it.
function! s:new_asking() abort
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
  let l:new = input('Rename to: ', get(l:rec, 'name', ''))
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
  if confirm('End session "' . claude#session#label(l:rec) . '"?',
        \ "&Yes\n&No", 2) == 1
    call claude#session#delete(l:node.id)
  endif
endfunction

function! s:purge() abort
  let l:node = s:current_node()
  if empty(l:node) || l:node.kind !=# 'session'
    return
  endif
  let l:rec = claude#session#get(l:node.id)
  if confirm('Purge "' . claude#session#label(l:rec)
        \ . '" and delete its transcript?', "&Yes\n&No", 2) != 1
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

" Which view the panel is drawing — 'state' or 'place'. Passing a name swaps
" to it and redraws, which is what the g key does.
function! claude#panel#_grouping(...) abort
  if a:0 > 0 && a:1 !=# s:grouping
    let s:grouping = a:1
    call s:render()
  endif
  return s:grouping
endfunction

" The active filter, and a way to set one without the prompt. Test seam; the
" user types one at the / key.
function! claude#panel#_filter(...) abort
  if a:0 > 0
    let s:filter = a:1
    call s:render()
  endif
  return s:filter
endfunction

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
  let s:collapsed  = {'st:done': 1}
  let s:rendered   = []
  let s:grouping   = 'state'
  let s:filter     = ''
  let s:done_all   = 0
  call claude#sidebar#_reset()
endfunction
