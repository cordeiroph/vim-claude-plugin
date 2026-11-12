" ── projects panel ───────────────────────────────────────────────────────────
"
" A NERDTree-style side panel: the one sidebar <C-a> raises. It has two views,
" swapped with g:
"
"   projects  every project of the repository — a git worktree on a branch of
"             its own, diffed against a baseline — and under each:
"
"               ▾ panel [origin/main]
"                 ▸ main Diff         what the project changed vs its baseline,
"                                     named after the baseline branch
"                 ▸ Local Diff        what is not on the remote branch yet
"                 ▸ Files             the worktree's files, as a tree
"                 ▾ Sessions (2)      the agents working in it
"
"             The default: it is the one place to see and act on each line of
"             work without juggling a diff tree and a file tree beside it.
"   state     what each session is doing — Needs you, Working, Idle, Done —
"             and, inside each, which project it is in.
"
" The panel owns presentation only: sessions come from
" autoload/claude/session.vim, projects and their git from room.vim, and diffs
" from difftree.vim's engine, so a changed file reads the same everywhere.
"
" Hiding the panel only closes its window. Sessions keep running.

let s:bufnr      = -1
let s:timer      = -1
let s:prev_winid = -1
let s:show_help  = 0
let s:rendered   = []     " session ids in the order last drawn
let s:grouping   = 'projects'
let s:known      = []     " every listed session id at the last full render
let s:findex     = {}     " worktree -> {dir -> {'dirs', 'files'}}, see Files
let s:filter     = ''     " while set, only matching sessions are drawn
let s:mixed      = 0      " 1 while the drawn rows run more than one agent
let s:done_all   = 0      " 1 once the Done group has been asked to show all

" Group key -> 1 while that node is folded shut. The two views use different
" key prefixes — 'st:' in the state view, 'pp:' / 'ps:' / … in the projects
" view — so switching views with g preserves both sets of folds. Done starts
" shut: it is the tail, and the tail is what nobody wants to scroll past.
let s:collapsed = {'st:done': 1}

" Keys starting 'x:' are the other way round: shut until opened, and listed
" here while open. A project's diffs and files cost git to draw, and a file
" tree opened by default would bury every project under the first one.
let s:opened = {}

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

function! s:is_shut(key) abort
  if a:key =~# '^x:'
    return !has_key(s:opened, a:key)
  endif
  return has_key(s:collapsed, a:key)
endfunction

function! s:toggle_key(key) abort
  let l:dict = a:key =~# '^x:' ? s:opened : s:collapsed
  if has_key(l:dict, a:key)
    call remove(l:dict, a:key)
  else
    let l:dict[a:key] = 1
  endif
endfunction

function! s:marker(key) abort
  return claude#sidebar#marker(empty(a:key) || !s:is_shut(a:key))
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
"   room               NERDTreeDir       Directory   (its directories)
"   — branch, [sub]    Type
"   fold marker        NERDTreeClosable  Directory   (its arrows)
"   session name       NERDTreeFile      Normal      (its files)
"   active icon        NERDTreeFlags     Number      (its flags)
"   help text          NERDTreeHelp      String
let s:highlights = [
      \ ['ClaudeSessionHeader',     'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionProject',    'NERDTreeCWD',      'Statement'],
      \ ['ClaudeSessionWorktree',   'NERDTreeDir',      'Directory'],
      \ ['ClaudeSessionBranch',     '',                 'Type'],
      \ ['ClaudeSessionRoomTag',    '',                 'ClaudeSessionBranch'],
      \ ['ClaudeSessionMarker',     'NERDTreeClosable', 'Directory'],
      \ ['ClaudeSessionName',       'NERDTreeFile',     'Normal'],
      \ ['ClaudeSessionWaiting',    '',                 'WarningMsg'],
      \ ['ClaudeSessionActive',     'NERDTreeFlags',    'Number'],
      \ ['ClaudeSessionIdle',       '',                 'Comment'],
      \ ['ClaudeSessionClosed',     '',                 'Comment'],
      \ ['ClaudeSessionNameClosed', '',                 'NonText'],
      \ ['ClaudeSessionHelp',       'NERDTreeHelp',     'String'],
      \ ['ClaudeSessionBaseTag',    '',                 'Identifier'],
      \ ['ClaudeSessionDiffField',  '',                 'Special'],
      \ ['ClaudeSessionNote',       '',                 'Comment'],
      \ ]

function! claude#panel#_relink() abort
  call claude#sidebar#link_highlights(s:highlights)
endfunction

" Buffer-local syntax. Must only ever run in the panel buffer.
function! s:setup_syntax() abort
  silent! syntax clear
  let l:m = claude#sidebar#marker_class()

  " Tree nodes, identified by their indent: projects and status groups at
  " the margin, sections, directories and state-view projects below them. A
  " project's branch, when it is not the one its name implies, follows an em
  " dash.
  execute 'syntax match ClaudeSessionProject  /^' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker,ClaudeSessionBaseTag'
  " A project row ends with its baseline in brackets.
  syntax match ClaudeSessionBaseTag / \[[^]]*\]$/ contained
  execute 'syntax match ClaudeSessionWorktree /^ \{2,}' . l:m
        \ . ' .*$/ contains=ClaudeSessionMarker,ClaudeSessionBranch'
  syntax match ClaudeSessionBranch / — .*$/ contained
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
        \ contains=ClaudeSessionRoomTag
  syntax match ClaudeSessionNameClosed /.*$/ contained
        \ contains=ClaudeSessionRoomTag
  " A sub-room's sessions are drawn under their room in the state view, with
  " the sub-room named after them.
  syntax match ClaudeSessionRoomTag /\[[^]]\+\]\%( \|$\)/ contained

  " A diff row starts with the diff tree's indicator field.
  syntax match ClaudeSessionDiffField /^ \{2,}\[[^]]*\] /
  " '(not pushed)', '(no changes vs origin/main)': notes, not rows.
  syntax match ClaudeSessionNote /^ \{2,}(.*)$/

  syntax match ClaudeSessionHeader /\%1l\%(Projects\|Claude Sessions\).*/
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
        \ a:node.label, a:node.suffix, get(a:node, 'tag', ''),
        \ get(a:node, 'trail', ''))
endfunction

" A session row: '<indent><glyph> <tag><label>' with {suffix} pushed against
" the right edge, and the label fitted into whatever is left between them.
" {tag} — the agent marker — sits ahead of the label, in the fixed-width part
" of the row, so it is never the part that gets cut; the label itself is
" trimmed from the right (an opening snippet stays readable rather than a
" name's tail). The suffix is dropped rather than allowed to squeeze the
" label to nothing.
"
" a:1 — {trail}, the sub-room a session is in, follows the label as
" `[name]`. Like the tag it is never what gets cut: the label is fitted into
" what the trail leaves.
function! s:row(indent, glyph, label, suffix, tag, ...) abort
  let l:trail = a:0 > 0 && !empty(a:1) ? ' [' . a:1 . ']' : ''
  let l:width = s:width()
  let l:left  = a:indent . a:glyph . ' ' . a:tag
  let l:room  = l:width - strchars(l:left) - strchars(a:suffix)
        \       - strchars(l:trail) - 1
  if empty(a:suffix) || l:room < 4
    return l:left . claude#sidebar#fit(l:width - strchars(l:trail), l:left,
          \ a:label, 'head') . l:trail
  endif
  let l:label = claude#sidebar#fit(l:room + 1, '', a:label, 'head') . l:trail
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

" Where a session lives, in six columns: the basename of its worktree. Only
" drawn for a session that sits under no room row, which is the only case in
" which nothing else on screen says it.
function! s:where(rec) abort
  return strcharpart(fnamemodify(get(a:rec, 'worktree', ''), ':t'), 0, 6)
endfunction

" Whether the rows being drawn are running more than one agent. A panel where
" they all agree says nothing about it — which is every panel, until the day
" a second CLI is started.
function! s:mixed_providers(sessions) abort
  let l:seen = {}
  for l:rec in a:sessions
    let l:seen[claude#provider#of(l:rec)] = 1
  endfor
  return len(l:seen) > 1
endfunction

" A one-letter tag for the agent a session runs on, shown beside its name
" rather than spelled out in the suffix column — only while the panel is
" showing more than one agent.
function! s:agent_tag(rec) abort
  if !s:mixed
    return ''
  endif
  let l:provider = claude#provider#of(a:rec)
  return '[' . toupper(strcharpart(l:provider, 0, 1)) . ']'
endfunction

" The right-hand column of a session row. A session drawn under no room row
" has nothing else saying where it lives, so the row must; under a room row,
" the room has already said it.
"
" a:1 — 1 when the row sits under a room.
function! s:suffix(rec, ...) abort
  let l:parts = []
  if !(a:0 > 0 && a:1)
    let l:where = s:where(a:rec)
    if !empty(l:where)
      call add(l:parts, l:where)
    endif
  endif
  let l:age = s:age(a:rec)
  if !empty(l:age)
    call add(l:parts, l:age)
  endif
  return join(l:parts, ' · ')
endfunction

" Whether a record survives the active filter. Matching is over everything the
" row could be recognised by, not only what it happens to be showing.
function! s:matches(rec) abort
  if empty(s:filter)
    return 1
  endif
  let l:hay = join([claude#session#label(a:rec), s:where(a:rec),
        \ get(a:rec, 'branch', ''), get(a:rec, 'room', ''),
        \ claude#provider#of(a:rec)], ' ')
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
"
" a:1 — 1 when the row sits under a room row; a:2 — the sub-room it is in,
" when the room row above it is its parent room's.
function! s:add_session(lines, nodes, rec, indent, label, ...) abort
  let l:node = s:node('session', '', a:rec.id, a:indent, a:label, a:rec.status)
  let l:node.suffix = s:suffix(a:rec, a:0 > 0 && a:1)
  let l:node.tag    = s:agent_tag(a:rec)
  let l:node.trail  = a:0 > 1 ? a:2 : ''
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

" {head} cut from the right, keeping its start, so that {head}{tail} fits in
" {avail} columns; {tail} is never cut. `pedro.cordeiro/macos-f… Diff`.
function! s:shorten(head, tail, avail) abort
  let l:room = a:avail - strchars(a:tail)
  if strchars(a:head) <= l:room || l:room < 4
    return a:head . a:tail
  endif
  let l:ellipsis = claude#sidebar#ascii() ? '...' : '…'
  return strcharpart(a:head, 0, l:room - strchars(l:ellipsis)) . l:ellipsis
        \ . a:tail
endfunction

" An unselectable note, indented under the group it belongs to. A note is
" read from its start — `(no changes vs origin/pedro.co…)` — so it is cut from
" the right, and keeps its closing parenthesis.
function! s:add_note(lines, nodes, indent, text) abort
  let l:avail = s:width() - strchars(a:indent)
  let l:text  = a:text =~# ')$'
        \ ? s:shorten(a:text[: -2], ')', l:avail)
        \ : s:shorten(a:text, '', l:avail)
  call add(a:lines, a:indent . l:text)
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
    if s:is_shut(l:group.key) && empty(s:filter)
      continue
    endif

    let l:cap = l:group.status ==# 'closed' && !s:done_all
          \ ? s:done_rows() : len(l:sessions)
    let l:shown  = l:cap < len(l:sessions) ? l:sessions[0 : l:cap - 1]
          \                                : l:sessions
    call s:add_by_room(a:lines, a:nodes, l:group.key, l:shown)

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

" The rows of one status group, each under the room it is in.
"
" Rooms are ordered by their first session, and the sessions keep the group's
" own order, so a room appears where its most urgent session would have been.
" A sub-room gets no row of its own here: its sessions sit with its room,
" tagged with its name, so the answer to "what needs me" costs no third
" indent. Sessions in no room — outside any repository — sit directly under
" the group, as they always have.
function! s:add_by_room(lines, nodes, gkey, shown) abort
  let l:labels  = s:disambiguate(a:shown)
  let l:loose   = []
  let l:buckets = []
  let l:index   = {}
  let l:projs   = {}
  let l:i = 0
  for l:rec in a:shown
    let [l:project, l:room, l:sub] = claude#session#place_of(l:rec)
    if empty(l:room) || empty(l:project) || l:project[0] ==# '('
      call add(l:loose, [l:rec, l:labels[l:i]])
    else
      let l:key = l:project . '|' . l:room
      if !has_key(l:index, l:key)
        let l:index[l:key] = len(l:buckets)
        call add(l:buckets, {'project': l:project, 'room': l:room,
              \ 'items': []})
        let l:projs[l:project] = 1
      endif
      call add(l:buckets[l:index[l:key]].items, [l:rec, l:labels[l:i], l:sub])
    endif
    let l:i += 1
  endfor

  for [l:rec, l:label] in l:loose
    call s:add_session(a:lines, a:nodes, l:rec, '  ', l:label)
  endfor

  let l:mixed = len(l:projs) > 1
  for l:b in l:buckets
    let l:rec   = s:room_rec(l:b.project, l:b.room)
    let l:label = s:room_label(l:rec)
    if l:mixed
      let l:label = fnamemodify(l:b.project, ':t') . ' › ' . l:label
    endif
    let l:key = a:gkey . '|r:' . l:b.project . '|' . l:b.room
    call s:add_group(a:lines, a:nodes, 'room', l:key, '  ', l:label)
    call s:tag_room(a:nodes[-1], l:b.project, l:rec)
    if s:is_shut(l:key) && empty(s:filter)
      continue
    endif
    for [l:rec, l:label, l:sub] in l:b.items
      call s:add_session(a:lines, a:nodes, l:rec, '    ', l:label, 1, l:sub)
    endfor
  endfor
endfunction

" The record for room {id} of {project}, or a stand-in when the store no
" longer knows it.
function! s:room_rec(project, id) abort
  let l:rec = claude#room#get(a:id, a:project)
  if !empty(l:rec)
    return l:rec
  endif
  if a:id ==# 'root'
    return extend(claude#room#root(a:project), {'path': a:project})
  endif
  return {'id': a:id, 'name': a:id, 'parent': '', 'branch': '', 'path': '',
        \ 'project': a:project, 'missing': 1, 'legacy': 0}
endfunction

" A room row's text. The state view names the root checkout without its
" branch: the group row above already says what the session is doing, and a
" 35-column row has no space for both.
function! s:room_label(rec) abort
  if get(a:rec, 'root', 0)
    return a:rec.name . ' (root)'
  endif
  return claude#room#label(a:rec)
endfunction

" What a room row carries for the keys: n starts a session in it, d removes
" it, and both need to know which room and which project.
function! s:tag_room(node, project, rec) abort
  let a:node.room    = a:rec.id
  let a:node.project = a:project
  let a:node.missing = get(a:rec, 'missing', 0)
  let a:node.path    = get(a:rec, 'missing', 0) ? '' : get(a:rec, 'path', '')
endfunction

" ── the projects view ────────────────────────────────────────────────────────

function! s:git(dir, args) abort
  let l:out = systemlist('git -c core.quotepath=false -C '
        \ . shellescape(a:dir) . ' ' . a:args . ' 2>/dev/null')
  return v:shell_error == 0 ? l:out : []
endfunction

" A project row: its name, then the baseline it diffs against in brackets.
function! s:project_label(rec) abort
  let l:name = get(a:rec, 'root', 0) ? a:rec.name . ' (root)'
        \ : claude#room#label(a:rec)
  let l:base = claude#room#baseline(a:rec)
  return l:name . ' [' . (empty(l:base) ? 'no baseline' : l:base) . ']'
endfunction

" Whether {rec} — a session — runs in project {room} of repository {root}.
function! s:in_project(rec, root, room) abort
  return get(a:rec, 'project', '') ==# a:root
        \ && get(a:rec, 'room', '') ==# a:room.id
endfunction

function! s:build_projects(lines, nodes) abort
  let l:root     = claude#room#project_root()
  let l:sessions = s:keep(!empty(s:filter) ? claude#session#all()
        \                                  : claude#session#list())
  let l:claimed  = {}

  if empty(l:root)
    call s:add_note(a:lines, a:nodes, '  ', '(not a git repository)')
  else
    for l:rec in claude#room#list(l:root)
      let l:mine = filter(copy(l:sessions),
            \ {_, r -> s:in_project(r, l:root, l:rec)})
      for l:s in l:mine
        let l:claimed[l:s.id] = 1
      endfor
      call s:add_project(a:lines, a:nodes, l:rec, l:mine)
    endfor
  endif

  " Sessions in no project of this repository — another repository, outside
  " git, a worktree the plugin did not make — stay reachable here.
  let l:rest = filter(copy(l:sessions), {_, r -> !has_key(l:claimed, r.id)})
  if !empty(l:rest)
    call add(a:lines, '')
    call add(a:nodes, s:node('blank', '', '', '', '', ''))
    call s:add_group(a:lines, a:nodes, 'group', 'pe:elsewhere', '',
          \ 'Elsewhere (' . len(l:rest) . ')')
    if !s:is_shut('pe:elsewhere') || !empty(s:filter)
      call s:add_by_room(a:lines, a:nodes, 'pe:elsewhere', l:rest)
    endif
  endif
endfunction

function! s:section_key(kind, rec) abort
  return a:kind . a:rec.project . '|' . a:rec.id
endfunction

function! s:add_project(lines, nodes, rec, sessions) abort
  let l:key = s:section_key('pp:', a:rec)
  call s:add_group(a:lines, a:nodes, 'project', l:key, '',
        \ s:project_label(a:rec), 1)
  call s:tag_room(a:nodes[-1], a:rec.project, a:rec)
  if s:is_shut(l:key) && empty(s:filter)
    return
  endif

  let l:ind = '    '
  " <baseline> Diff: everything the project did since it left its baseline,
  " named after the baseline's branch. The fold key does not carry the name,
  " so moving the baseline with b keeps the section open or shut.
  let l:key  = s:section_key('x:pb:', a:rec)
  let l:base = claude#room#baseline(a:rec)
  " A long branch keeps its start and the word Diff: the end of a branch name
  " is the part least likely to tell two apart.
  call s:add_section(a:lines, a:nodes, 'diff', l:key, s:shorten(empty(l:base)
        \ ? 'Baseline' : claude#room#branch_name(a:rec.project, l:base),
        \ ' Diff', s:width() - 4), a:rec)
  if !s:is_shut(l:key)
    if empty(l:base)
      call s:add_note(a:lines, a:nodes, l:ind, '(no baseline — b to set one)')
    else
      call s:add_diff(a:lines, a:nodes, l:key, a:rec,
            \ claude#difftree#changes(a:rec.path, l:base), l:ind,
            \ '(no changes vs ' . l:base . ')')
    endif
  endif

  " Local Diff: what this checkout has that the remote branch does not.
  let l:key = s:section_key('x:pl:', a:rec)
  call s:add_section(a:lines, a:nodes, 'diff', l:key, 'Local Diff', a:rec)
  if !s:is_shut(l:key)
    let l:up = claude#room#upstream(a:rec)
    if empty(l:up)
      call s:add_note(a:lines, a:nodes, l:ind, '(not pushed)')
    else
      call s:add_diff(a:lines, a:nodes, l:key, a:rec,
            \ claude#difftree#changes(a:rec.path, l:up), l:ind,
            \ '(nothing unpushed vs ' . l:up . ')')
    endif
  endif

  " Files: the worktree itself.
  let l:key = s:section_key('x:pf:', a:rec)
  call s:add_section(a:lines, a:nodes, 'files', l:key, 'Files', a:rec)
  if !s:is_shut(l:key)
    if !isdirectory(a:rec.path)
      call s:add_note(a:lines, a:nodes, l:ind, '(worktree missing)')
    else
      let l:before = len(a:lines)
      call s:add_files(a:lines, a:nodes, a:rec.path, '', l:ind)
      if len(a:lines) == l:before
        call s:add_note(a:lines, a:nodes, l:ind, '(empty)')
      endif
    endif
  endif

  " Sessions: open by default — they are what the panel is for.
  let l:key = s:section_key('ps:', a:rec)
  call s:add_section(a:lines, a:nodes, 'sessions', l:key,
        \ 'Sessions (' . len(a:sessions) . ')', a:rec)
  if !s:is_shut(l:key) || !empty(s:filter)
    let l:labels = s:disambiguate(a:sessions)
    let l:i = 0
    for l:s in a:sessions
      call s:add_session(a:lines, a:nodes, l:s, l:ind, l:labels[l:i], 1)
      let l:i += 1
    endfor
  endif
endfunction

" A section row under a project, carrying the project for the keys.
function! s:add_section(lines, nodes, section, key, label, rec) abort
  call s:add_group(a:lines, a:nodes, 'section', a:key, '  ', a:label, 1)
  call s:tag_room(a:nodes[-1], a:rec.project, a:rec)
  let a:nodes[-1].section = a:section
endfunction

" A diff, as the diff tree draws it: directories, then files with their
" indicator field.
function! s:add_diff(lines, nodes, key, rec, files, indent, empty) abort
  if empty(a:files)
    call s:add_note(a:lines, a:nodes, a:indent, a:empty)
    return
  endif
  call s:emit_diff_dir(a:lines, a:nodes, claude#difftree#dir_tree(a:files),
        \ a:key, '', a:indent)
endfunction

function! s:emit_diff_dir(lines, nodes, dir, key, prefix, indent) abort
  for l:sub in a:dir.dirs
    let l:path = empty(a:prefix) ? l:sub.name : a:prefix . '/' . l:sub.name
    let l:dkey = 'pd:' . a:key . '|' . l:path
    call s:add_group(a:lines, a:nodes, 'dir', l:dkey, a:indent, l:sub.name)
    if !s:is_shut(l:dkey)
      call s:emit_diff_dir(a:lines, a:nodes, l:sub, a:key, l:path,
            \ a:indent . '  ')
    endif
  endfor
  for l:rec in a:dir.files
    let l:name = fnamemodify(l:rec.path, ':t')
    call add(a:lines, a:indent . claude#difftree#field(l:rec) . ' ' . l:name)
    let l:node = s:node('file', '', '', a:indent, l:name, '')
    let l:node.file = l:rec
    call add(a:nodes, l:node)
  endfor
endfunction

" ── the file tree ────────────────────────────────────────────────────────────
"
" Drawn by the panel itself rather than borrowed from NERDTree, which cannot
" be put inside another buffer. Directories are listed one level at a time as
" they are opened, from an index git builds once per worktree — so .gitignore
" is honoured — and rebuilt on R or when the Files section is opened again.

" The worktree's files, as {dir -> {'dirs': [...], 'files': [...]}} with ''
" for the top. {} when git cannot list it, which falls back to readdir().
function! s:file_index(wt) abort
  if has_key(s:findex, a:wt)
    return s:findex[a:wt]
  endif
  let l:index = {}
  let l:paths = s:git(a:wt, 'ls-files --cached --others --exclude-standard')
  if v:shell_error == 0
    let l:index[''] = {'dirs': {}, 'files': {}}
    for l:path in l:paths
      if empty(l:path) || l:path =~# '^\.vim-workspace/'
        continue
      endif
      let l:parts = split(l:path, '/')
      let l:dir = ''
      for l:part in l:parts[: -2]
        let l:index[l:dir].dirs[l:part] = 1
        let l:dir = empty(l:dir) ? l:part : l:dir . '/' . l:part
        if !has_key(l:index, l:dir)
          let l:index[l:dir] = {'dirs': {}, 'files': {}}
        endif
      endfor
      let l:index[l:dir].files[l:parts[-1]] = 1
    endfor
  endif
  let s:findex[a:wt] = l:index
  return l:index
endfunction

" [dirs, files] directly inside {rel} of worktree {wt}, each sorted.
function! s:children(wt, rel) abort
  let l:index = s:file_index(a:wt)
  if !empty(l:index)
    let l:entry = get(l:index, a:rel, {'dirs': {}, 'files': {}})
    return [sort(keys(l:entry.dirs)), sort(keys(l:entry.files))]
  endif
  let l:full = empty(a:rel) ? a:wt : a:wt . '/' . a:rel
  let l:dirs  = []
  let l:files = []
  for l:name in (exists('*readdir') ? readdir(l:full)
        \ : map(glob(l:full . '/*', 1, 1), {_, p -> fnamemodify(p, ':t')}))
    if l:name ==# '.git' || l:name ==# '.vim-workspace'
      continue
    endif
    call add(isdirectory(l:full . '/' . l:name) ? l:dirs : l:files, l:name)
  endfor
  return [sort(l:dirs), sort(l:files)]
endfunction

function! s:add_files(lines, nodes, wt, rel, indent) abort
  let [l:dirs, l:files] = s:children(a:wt, a:rel)
  for l:name in l:dirs
    let l:path = empty(a:rel) ? l:name : a:rel . '/' . l:name
    let l:key  = 'x:fd:' . a:wt . '|' . l:path
    call s:add_group(a:lines, a:nodes, 'dir', l:key, a:indent, l:name . '/')
    if !s:is_shut(l:key)
      call s:add_files(a:lines, a:nodes, a:wt, l:path, a:indent . '  ')
    endif
  endfor
  for l:name in l:files
    let l:path = empty(a:rel) ? l:name : a:rel . '/' . l:name
    call add(a:lines, a:indent . '  ' . claude#sidebar#fit(s:width(),
          \ a:indent . '  ', l:name))
    let l:node = s:node('file', '', '', a:indent, l:name, '')
    let l:node.file = {'worktree': a:wt, 'path': l:path}
    call add(a:nodes, l:node)
  endfor
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

function! s:help_lines() abort
  if s:grouping ==# 'projects'
    return [
          \ '',
          \ ' <CR>/o open   i split   s vsplit',
          \ ' t tab     N new project  m menu',
          \ ' n new session   b baseline',
          \ ' u merge baseline   D delete',
          \ ' g by status  / filter  r rename',
          \ ' d end     X purge  R refresh',
          \ ' I ' . (claude#session#show_hidden() ? 'hide' : 'show')
          \   . ' hidden',
          \ ' <Space> fold   q hide   ? help',
          \ ]
  endif
  return [
        \ '',
        \ ' <CR>/o open   i split   s vsplit',
        \ ' t tab     n new here  N new project',
        \ ' g projects  / filter  r rename',
        \ ' d end     X purge  R refresh',
        \ ' m menu    D delete project',
        \ ' I ' . (claude#session#show_hidden() ? 'hide' : 'show')
        \   . ' hidden',
        \ ' <Space> fold   q hide   ? help',
        \ ]
endfunction

function! s:build() abort
  let l:lines = []
  let l:nodes = []
  let s:mixed = s:mixed_providers(claude#session#all())

  let l:title = s:grouping ==# 'projects' ? 'Projects' : 'Claude Sessions'
  let l:count = s:header_count()
  let l:pad   = max([1, s:width() - strchars(l:title) - strchars(l:count)])
  call add(l:lines, l:title . repeat(' ', l:pad) . l:count)
  call add(l:nodes, s:node('header', '', '', '', l:title, ''))

  if s:show_help
    for l:h in s:help_lines()
      call add(l:lines, l:h)
      call add(l:nodes, s:node('help', '', '', '', l:h, ''))
    endfor
  endif

  call add(l:lines, '')
  call add(l:nodes, s:node('blank', '', '', '', '', ''))

  if s:grouping ==# 'state'
    call s:build_states(l:lines, l:nodes)
  else
    call s:build_projects(l:lines, l:nodes)
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
  let s:known = map(copy(claude#session#list()), {_, r -> r.id})

  if l:restore > 0
    call win_execute(l:win,
          \ 'call cursor(' . min([l:restore, len(l:lines)]) . ', 1)')
  endif
endfunction

" Rebuild the tree. Safe to call when the panel is not open. The file index is
" dropped too: whatever made the caller refresh may have added files.
function! claude#panel#refresh() abort
  if !claude#panel#is_open()
    return
  endif
  let s:findex = {}
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
"
" The projects view is repainted in place for another reason too: a full
" rebuild redraws every open diff and file tree, and a status change does not
" touch either.
function! s:repaint() abort
  if s:grouping ==# 'state'
    " The status *is* the row's position here: a session that starts waiting
    " moves to another group. There is no column to repaint in place.
    call s:render()
    return
  endif
  let l:nodes = getbufvar(s:bufnr, 'claude_panel_nodes', [])
  let l:ids   = map(copy(claude#session#list()), {_, r -> r.id})
  if sort(copy(l:ids)) != sort(copy(s:known))
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
  nnoremap <buffer> <silent> N       :call <SID>new_project()<CR>
  nnoremap <buffer> <silent> m       :call <SID>menu()<CR>
  nnoremap <buffer> <silent> b       :call <SID>change_base()<CR>
  nnoremap <buffer> <silent> u       :call <SID>update_base()<CR>
  nnoremap <buffer> <silent> D       :call <SID>delete_project()<CR>
  nnoremap <buffer> <silent> g       :call <SID>swap_grouping()<CR>
  nnoremap <buffer> <silent> /       :call <SID>prompt_filter()<CR>
  nnoremap <buffer> <silent> r       :call <SID>rename()<CR>
  nnoremap <buffer> <silent> d       :call <SID>end_session()<CR>
  nnoremap <buffer> <silent> X       :call <SID>purge()<CR>
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
  elseif l:node.kind ==# 'file'
    call s:open_file(l:node.file, 'here')
  elseif l:node.kind ==# 'more'
    let s:done_all = 1
    call s:render()
  elseif !empty(l:node.key)
    call s:fold()
  endif
endfunction

function! s:open(mode) abort
  let l:node = s:current_node()
  if empty(l:node)
    return
  endif
  if l:node.kind ==# 'session'
    call claude#panel#open_session(l:node.id, a:mode)
  elseif l:node.kind ==# 'file'
    call s:open_file(l:node.file, a:mode)
  endif
endfunction

" Opening a diff or a file tree reads it afresh: what an agent changed since
" the last look is the reason to look.
function! s:fold() abort
  let l:node = s:current_node()
  if empty(l:node) || empty(l:node.key)
    return
  endif
  call s:toggle_key(l:node.key)
  if l:node.kind ==# 'section' && !s:is_shut(l:node.key)
    if get(l:node, 'section', '') ==# 'files'
      silent! call remove(s:findex, l:node.path)
    elseif get(l:node, 'section', '') ==# 'diff'
      call claude#difftree#refresh()
      return
    endif
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
  let s:findex = {}
  call claude#difftree#refresh()
  call s:render()
endfunction

" Swap the top level between the projects and what sessions are doing.
function! s:swap_grouping() abort
  let s:grouping = s:grouping ==# 'state' ? 'projects' : 'state'
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

" ── the project under the cursor ─────────────────────────────────────────────

" The project the row under the cursor belongs to — the project row itself,
" any row inside it, or, in the state view, a project row and the sessions
" under it — as its record, or {} when the row is in none.
function! s:project_under_cursor() abort
  let l:nodes = get(b:, 'claude_panel_nodes', [])
  let l:i     = line('.') - 1
  while l:i >= 0 && l:i < len(l:nodes)
    let l:up = l:nodes[l:i]
    if index(['project', 'room', 'section'], l:up.kind) >= 0
          \ && !empty(get(l:up, 'room', ''))
      if get(l:up, 'missing', 0)
        return {}
      endif
      return claude#room#get(l:up.room, get(l:up, 'project', ''))
    endif
    if l:up.kind ==# 'group' || l:up.kind ==# 'header'
      break
    endif
    if l:up.kind ==# 'session' && empty(l:up.indent)
      break
    endif
    let l:i -= 1
  endwhile
  return {}
endfunction

" The project under the cursor, for a key that changes it. Only projects of
" the repository Vim is in can be changed from here; {what} names the action
" in the warning for the others.
function! s:project_for(what) abort
  let l:rec = s:project_under_cursor()
  if empty(l:rec)
    call s:warn('put the cursor on a project to ' . a:what)
    return {}
  endif
  if l:rec.project !=# claude#room#project_root()
    call s:warn(l:rec.name . ' belongs to another repository; open it there'
          \ . ' to ' . a:what)
    return {}
  endif
  return l:rec
endfunction

function! s:warn(msg) abort
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" ── sessions ─────────────────────────────────────────────────────────────────

" Which agent the row under the cursor is running, so n can start another like
" it, or '' when the row names no session.
function! s:provider_under_cursor() abort
  let l:node = s:current_node()
  if !empty(l:node) && l:node.kind ==# 'session'
    let l:rec = claude#session#get(l:node.id)
    if !empty(l:rec)
      return claude#provider#of(l:rec)
    endif
  endif
  return ''
endfunction

" n — a session in the project under the cursor. A session row starts
" another like it, in the same place on the same agent; any other row inside
" a project starts one there, asking which agent when there is more than one;
" anywhere else asks which project first (unless g:claude_session_prompt_name
" turned the questions off). Then only the name is asked for,
" and leaving it blank is still an answer — the session labels itself from
" its first message.
function! s:new() abort
  let l:opts = {'ask_name': get(g:, 'claude_session_prompt_name', 1)}
  let l:node = s:current_node()
  let l:here = claude#room#project_root()

  let l:provider = s:provider_under_cursor()
  if !empty(l:provider)
    let l:rec = claude#session#get(l:node.id)
    if !empty(get(l:rec, 'room', '')) && get(l:rec, 'project', '') ==# l:here
          \ && !empty(claude#room#get(l:rec.room))
      let l:opts.room = l:rec.room
    elseif isdirectory(get(l:rec, 'worktree', ''))
      let l:opts.cwd = l:rec.worktree
    endif
  else
    let l:proj = s:project_under_cursor()
    if !empty(l:proj)
      if l:proj.project ==# l:here
        let l:opts.room = l:proj.id
      else
        let l:opts.cwd = l:proj.path
      endif
    elseif !empty(l:here) && get(g:, 'claude_session_prompt_name', 1)
      " With the prompts turned off nothing is asked: the session goes in the
      " selected project, as it does everywhere else.
      let [l:ok, l:answer] = claude#room#ask()
      if !l:ok
        return
      endif
      let l:opts.answer = l:answer
    endif
    let [l:ok, l:provider] = get(g:, 'claude_session_prompt_name', 1)
          \ ? s:ask_provider() : [1, claude#provider#default()]
    if !l:ok
      return
    endif
  endif
  let l:opts.provider = l:provider

  call s:enter_main()
  let l:id = claude#session#spawn(l:opts)
  if !empty(l:id)
    call claude#session#touch_focus(l:id)
  endif
endfunction

" Which agent a new session should run. Returns [1, provider], or [0, ''] when
" the question was cancelled — the same contract as claude#room#ask(), so
" CTRL-C here creates nothing at all. With only one agent registered there is
" nothing worth asking.
"
" inputlist() rather than a popup: the name question follows, and it is an
" input() prompt. A popup would have to hand it to a callback.
function! s:ask_provider() abort
  let l:names = claude#provider#names()
  if len(l:names) < 2
    return [1, claude#provider#default()]
  endif
  let l:menu = ['Which agent?']
  let l:i = 1
  for l:name in l:names
    call add(l:menu, printf('%d. %s', l:i, claude#provider#label(l:name)))
    let l:i += 1
  endfor
  try
    let l:choice = inputlist(l:menu)
  catch /^Vim:Interrupt$/
    return [0, '']
  endtry
  redraw
  if l:choice < 1 || l:choice > len(l:names)
    return [0, '']
  endif
  return [1, l:names[l:choice - 1]]
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

" d — end the session under the cursor.
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

" X — purge the session under the cursor: end it and delete its transcript.
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

" ── projects ─────────────────────────────────────────────────────────────────

" N — a new project: a name, a baseline (blank for the default branch), then a
" branch and a worktree of its own. Starts no session; n does that.
function! s:new_project() abort
  let [l:ok, l:answer] = claude#room#ask_new()
  if !l:ok
    return
  endif
  let l:rec = claude#room#realise(l:answer)
  if empty(l:rec)
    return
  endif
  let s:grouping = 'projects'
  call claude#difftree#refresh()
  call s:render()
  call s:goto_project(l:rec)
  echomsg 'claude.vim: project ' . l:rec.name . ' created on ' . l:rec.branch
        \ . ' from ' . l:rec.base
endfunction

function! s:goto_project(rec) abort
  let l:key   = s:section_key('pp:', a:rec)
  let l:nodes = getbufvar(s:bufnr, 'claude_panel_nodes', [])
  let l:i = 0
  for l:node in l:nodes
    let l:i += 1
    if l:node.key ==# l:key
      let l:win = bufwinid(s:bufnr)
      if l:win != -1
        call win_execute(l:win, 'call cursor(' . l:i . ', 1)')
      endif
      return
    endif
  endfor
endfunction

" D — delete the project under the cursor: its worktree goes, its branch is
" kept. Asked twice when the worktree has uncommitted changes, which would be
" lost. The root checkout is not a project that can be deleted.
function! s:delete_project() abort
  let l:rec = s:project_for('delete it')
  if empty(l:rec)
    return
  endif
  if get(l:rec, 'root', 0)
    call s:warn('the root checkout cannot be deleted')
    return
  endif
  let l:msg = 'Delete project "' . l:rec.name . '"? Its worktree '
        \ . claude#sidebar#home_relative(l:rec.path) . ' is removed; branch '
        \ . l:rec.branch . ' is kept.'
  if confirm(l:msg, "&Yes\n&No", 2) != 1
    return
  endif
  let l:force = 0
  if claude#room#is_dirty(l:rec)
    if confirm(l:rec.name . ' has uncommitted changes. Delete anyway and'
          \ . ' lose them?', "&Yes\n&No", 2) != 1
      return
    endif
    let l:force = 1
  endif
  let l:ok = l:force ? claude#room#force_remove(l:rec.id)
        \            : claude#room#remove(l:rec.id)
  if l:ok
    silent! call remove(s:findex, l:rec.path)
    call claude#difftree#refresh()
    call s:render()
  endif
endfunction

" b — pick a new baseline for the project under the cursor, completing branch
" names. Blank goes back to the default branch.
function! s:change_base() abort
  let l:rec = s:project_for('change its baseline')
  if empty(l:rec)
    return
  endif
  try
    let l:new = input('Baseline for ' . l:rec.name . ' (blank for default): ',
          \ claude#room#baseline(l:rec),
          \ 'customlist,claude#difftree#complete_branch')
  catch /^Vim:Interrupt$/
    redraw
    return
  endtry
  redraw
  if claude#room#set_base(l:rec.id, trim(l:new), l:rec.project)
    call s:render()
  endif
endfunction

" u — fetch the project's baseline and merge it into the project's branch.
function! s:update_base() abort
  let l:rec = s:project_for('update it')
  if empty(l:rec)
    return
  endif
  let l:base = claude#room#baseline(l:rec)
  if empty(l:base)
    call s:warn(l:rec.name . ' has no baseline; b sets one')
    return
  endif
  if confirm('Fetch ' . l:base . ' and merge it into ' . l:rec.branch . '?',
        \ "&Yes\n&No", 1) != 1
    return
  endif
  call claude#room#update(l:rec.id, l:rec.project)
  let s:findex = {}
  call s:render()
endfunction

" ── the m menu ───────────────────────────────────────────────────────────────

" [hotkey, label, function] for each entry m offers on the row under the
" cursor. The hotkeys are the direct mappings, so the menu teaches them.
function! s:menu_items() abort
  let l:items = []
  let l:rec   = s:project_under_cursor()
  if !empty(l:rec)
    call add(l:items, ['n', 'New session in ' . l:rec.name, function('s:new')])
    if l:rec.project ==# claude#room#project_root()
      call add(l:items, ['b', 'Change baseline…', function('s:change_base')])
      call add(l:items, ['u', 'Update from baseline (fetch + merge)',
            \ function('s:update_base')])
      if !get(l:rec, 'root', 0)
        call add(l:items, ['D', 'Delete project…',
              \ function('s:delete_project')])
      endif
    endif
  endif
  call add(l:items, ['N', 'New project…', function('s:new_project')])
  call add(l:items, ['g', s:grouping ==# 'projects'
        \ ? 'Show sessions by status' : 'Show projects',
        \ function('s:swap_grouping')])
  call add(l:items, ['R', 'Refresh', function('s:full_refresh')])
  return l:items
endfunction

function! s:use_popup() abort
  return has('popupwin') && !get(g:, 'claude_no_popup', 0)
endfunction

" m — NERDTree's menu key: every action on the project under the cursor, each
" with the key that does it directly.
function! s:menu() abort
  let l:items  = s:menu_items()
  let l:labels = map(copy(l:items), {_, it -> '(' . it[0] . ') ' . it[1]})
  let l:rec    = s:project_under_cursor()
  let l:title  = empty(l:rec) ? ' Projects ' : ' ' . l:rec.name . ' '

  if s:use_popup()
    let l:keys = map(copy(l:items), {_, it -> it[0]})
    call popup_menu(l:labels, {
          \ 'title':    l:title,
          \ 'filter':   {id, key -> s:menu_filter(l:keys, id, key)},
          \ 'callback': {_, idx -> s:menu_pick(l:items, idx)},
          \ 'padding':  [0, 1, 0, 1],
          \ 'border':   [],
          \ })
    return
  endif

  let l:menu = [trim(l:title) . ':']
  let l:i = 1
  for l:label in l:labels
    call add(l:menu, printf('%d. %s', l:i, l:label))
    let l:i += 1
  endfor
  try
    let l:choice = inputlist(l:menu)
  catch /^Vim:Interrupt$/
    let l:choice = 0
  endtry
  redraw
  call s:menu_pick(l:items, l:choice)
endfunction

" A hotkey picks its entry at once; everything else is the usual menu.
function! s:menu_filter(keys, id, key) abort
  let l:idx = index(a:keys, a:key)
  if l:idx >= 0
    call popup_close(a:id, l:idx + 1)
    return 1
  endif
  return popup_filter_menu(a:id, a:key)
endfunction

function! s:menu_pick(items, idx) abort
  if a:idx < 1 || a:idx > len(a:items)
    return
  endif
  call call(a:items[a:idx - 1][2], [])
endfunction

" ── opening a file ───────────────────────────────────────────────────────────

" {file} is {'worktree', 'path'}. <CR> reuses the window the user was last
" working in, the way NERDTree does; the other modes split it.
function! s:open_file(file, mode) abort
  let l:full = a:file.worktree . '/' . a:file.path
  if !filereadable(l:full)
    call s:warn(a:file.path . ' no longer exists on disk')
    return
  endif
  if a:mode ==# 'here'
    let l:target = claude#sidebar#last_main_winid()
    call claude#sidebar#enter_main(l:target > 0 ? l:target : s:prev_winid)
  else
    call s:make_window(a:mode)
  endif
  execute 'edit ' . fnameescape(l:full)
endfunction

" ── revealing a file ─────────────────────────────────────────────────────────

" The project whose worktree holds {path} — the deepest, since the root
" checkout holds every project under .vim-workspace too — or {}.
function! s:project_of_file(path) abort
  let l:root = claude#room#project_of(fnamemodify(a:path, ':h'))
  if empty(l:root)
    return {}
  endif
  let l:best = {}
  for l:rec in claude#room#list(l:root)
    let l:dir = resolve(l:rec.path)
    if stridx(a:path, l:dir . '/') == 0
          \ && strlen(l:dir) > strlen(resolve(get(l:best, 'path', '')))
      let l:best = l:rec
    endif
  endfor
  return l:best
endfunction

" :ClaudeReveal — NERDTreeFind for the projects panel: open the panel on the
" projects view, unfold the project holding {path} (default: the current
" file), its Files and every directory on the way, and put the cursor on the
" file. Outside any project, NERDTreeFind does what it always did.
function! claude#panel#reveal(...) abort
  let l:path = resolve(fnamemodify(a:0 > 0 && !empty(a:1) ? a:1
        \ : expand('%'), ':p'))
  let l:rec = filereadable(l:path) ? s:project_of_file(l:path) : {}
  if empty(l:rec)
    if exists(':NERDTreeFind') == 2
      NERDTreeFind
    else
      call s:warn('this file is in no project')
    endif
    return
  endif

  let l:wt  = l:rec.path
  let l:rel = l:path[strlen(resolve(l:wt)) + 1 :]
  let s:grouping = 'projects'
  let s:filter   = ''
  silent! call remove(s:collapsed, s:section_key('pp:', l:rec))
  let s:opened[s:section_key('x:pf:', l:rec)] = 1
  let l:dir = ''
  for l:part in split(l:rel, '/')[: -2]
    let l:dir = empty(l:dir) ? l:part : l:dir . '/' . l:part
    let s:opened['x:fd:' . l:wt . '|' . l:dir] = 1
  endfor
  " Read the tree afresh: the file may be new since it was last listed.
  silent! call remove(s:findex, l:wt)

  if claude#panel#is_open()
    call win_gotoid(bufwinid(s:bufnr))
    call s:render()
  else
    call claude#panel#open()
  endif

  let l:i = 0
  for l:node in getbufvar(s:bufnr, 'claude_panel_nodes', [])
    let l:i += 1
    if l:node.kind ==# 'file' && l:node.file.worktree ==# l:wt
          \ && l:node.file.path ==# l:rel && !has_key(l:node.file, 'committed')
      call cursor(l:i, 1)
      normal! zz
      return
    endif
  endfor
  " Not listed: git ignores it. Land on the project at least.
  call s:goto_project(l:rec)
  call s:warn(l:rel . ' is not in the file tree (ignored by git?)')
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

" Which view the panel is drawing — 'projects' or 'state'. Passing a name swaps
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
  let s:grouping   = 'projects'
  let s:known      = []
  let s:findex     = {}
  let s:opened     = {}
  let s:filter     = ''
  let s:done_all   = 0
  call claude#sidebar#_reset()
endfunction
