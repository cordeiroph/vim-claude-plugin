" ── session registry ─────────────────────────────────────────────────────────
"
" A single global registry of Claude sessions, replacing the old per-tab
" model. Keyed by session id (a UUID minted here and handed to the CLI via
" --session-id), so a session is identified the same way in Vim, in Claude's
" own /resume picker and on disk in ~/.claude/projects/.
"
" A record is:
"   id           session id / transcript filename stem
"   name         user-assigned label (also passed to the CLI as --name)
"   bufnr        terminal buffer, or -1 when the session is not live here
"   cwd          working directory the session was started in
"   project      main repository root (worktrees of one repo share this)
"   worktree     worktree root
"   branch       branch checked out at spawn — recorded, never re-derived
"   created      unix time
"   last_active  unix time of the last observed terminal output change
"   last_focus   unix time the terminal window was last entered
"   origin       'live' (spawned here) or 'disk' (known only from a transcript)
"   commands     slash-command completion items for this session
"   agents       agent completion items for this session
"
" Records are never dropped when a session ends: the job dies, the record
" flips to 'closed' and stays listed so it can be resumed. Only purge()
" removes one.

let s:sessions = {}

" Directory -> {project, worktree, branch}. Git is never run twice for the
" same directory in one Vim session, and never on a panel redraw.
let s:group_cache = {}

let s:warned = {}

" ── configuration accessors ──────────────────────────────────────────────────

function! s:idle_secs() abort
  return get(g:, 'claude_panel_idle_secs', 30)
endfunction

function! s:closed_limit() abort
  return get(g:, 'claude_panel_closed_limit', 10)
endfunction

function! s:warn_once(kind, msg) abort
  if has_key(s:warned, a:kind)
    return
  endif
  let s:warned[a:kind] = 1
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" ── identifiers ──────────────────────────────────────────────────────────────

let s:seed = exists('*srand') ? srand() : []
let s:rand_counter = 0

function! s:rand_byte() abort
  if exists('*rand')
    return and(rand(s:seed), 255)
  endif
  " No rand(): mix the microsecond clock with a counter. Only needs to be
  " unique-enough for a session id, not cryptographically random.
  let s:rand_counter += 1
  let l:t = reltime()
  return and(l:t[1] + l:t[0] * 7 + s:rand_counter * 131, 255)
endfunction

" Generate a RFC-4122 version-4 UUID. The CLI validates the format.
function! claude#session#uuid() abort
  let l:b = map(range(16), {-> s:rand_byte()})
  let l:b[6] = or(and(l:b[6], 0x0f), 0x40)   " version 4
  let l:b[8] = or(and(l:b[8], 0x3f), 0x80)   " variant 1
  let l:h = map(copy(l:b), {_, v -> printf('%02x', v)})
  return join(l:h[0:3], '') . '-' . join(l:h[4:5], '') . '-'
        \ . join(l:h[6:7], '') . '-' . join(l:h[8:9], '') . '-'
        \ . join(l:h[10:15], '')
endfunction

" ── grouping ─────────────────────────────────────────────────────────────────

" Run {cmd}, returning trimmed stdout or '' when the command failed.
function! s:git(cmd) abort
  let l:out = system(a:cmd . ' 2>/dev/null')
  if v:shell_error != 0
    return ''
  endif
  return substitute(l:out, '\n\+$', '', '')
endfunction

" {project, worktree, branch} for {cwd}, memoised for the Vim session.
function! claude#session#group_of(cwd) abort
  if !has_key(s:group_cache, a:cwd)
    let s:group_cache[a:cwd] = s:derive_group(a:cwd)
  endif
  return copy(s:group_cache[a:cwd])
endfunction

function! s:derive_group(cwd) abort
  let l:none = {
        \ 'project':  '(no project)',
        \ 'worktree': a:cwd,
        \ 'branch':   '(no branch)',
        \ }
  if empty(a:cwd) || !isdirectory(a:cwd) || !executable('git')
    return l:none
  endif

  let l:pre = 'git -C ' . shellescape(a:cwd) . ' '

  " --git-common-dir is what collapses linked worktrees into one project:
  " for a worktree --git-dir points at <main>/.git/worktrees/<name> while
  " --git-common-dir points at <main>/.git.
  let l:common = s:git(l:pre . 'rev-parse --path-format=absolute --git-common-dir')
  if empty(l:common)
    " Git < 2.31 has no --path-format; resolve the relative answer by hand.
    let l:rel = s:git(l:pre . 'rev-parse --git-common-dir')
    if empty(l:rel)
      return l:none
    endif
    let l:common = l:rel[0] ==# '/' ? l:rel : simplify(a:cwd . '/' . l:rel)
  endif

  let l:project = substitute(l:common, '/\.git/\=$', '', '')
  if l:project ==# l:common
    " Nothing was stripped: a bare repository, which has no worktree to group.
    return l:none
  endif

  let l:top = s:git(l:pre . 'rev-parse --show-toplevel')

  let l:branch = s:git(l:pre . 'rev-parse --abbrev-ref HEAD')
  if empty(l:branch)
    let l:branch = '(no branch)'
  elseif l:branch ==# 'HEAD'
    let l:sha = s:git(l:pre . 'rev-parse --short=7 HEAD')
    let l:branch = '(detached: ' . (empty(l:sha) ? '?' : l:sha) . ')'
  endif

  return {
        \ 'project':  l:project,
        \ 'worktree': empty(l:top) ? a:cwd : l:top,
        \ 'branch':   l:branch,
        \ }
endfunction

" ── transcripts ──────────────────────────────────────────────────────────────

" Claude stores a project's transcripts under a slugified copy of its cwd.
function! claude#session#project_dir(cwd) abort
  return expand('~/.claude/projects/') . substitute(a:cwd, '/', '-', 'g')
endfunction

function! s:trim_snippet(text) abort
  let l:s = substitute(a:text, '[\r\n]\+', ' ', 'g')
  let l:s = substitute(l:s, '^\s\+\|\s\+$', '', 'g')
  return strcharpart(l:s, 0, 60)
endfunction

" First text block of a transcript entry's message, if any.
function! s:message_text(entry) abort
  let l:msg = get(a:entry, 'message', {})
  if type(l:msg) != v:t_dict
    return ''
  endif
  let l:content = get(l:msg, 'content', '')
  if type(l:content) == v:t_string
    return s:trim_snippet(l:content)
  elseif type(l:content) == v:t_list
    for l:block in l:content
      if type(l:block) == v:t_dict && get(l:block, 'type', '') ==# 'text'
        return s:trim_snippet(get(l:block, 'text', ''))
      endif
    endfor
  endif
  return ''
endfunction

" Read enough of a transcript to place and label it. cwd and gitBranch appear
" on every user entry, so only the head of the file is read — never the whole
" conversation.
function! s:scan_transcript(path) abort
  let l:rec = {
        \ 'id':      fnamemodify(a:path, ':t:r'),
        \ 'cwd':     '',
        \ 'branch':  '',
        \ 'snippet': '',
        \ 'created': getftime(a:path),
        \ }
  for l:line in readfile(a:path, '', 60)
    if empty(l:line)
      continue
    endif
    try
      let l:entry = json_decode(l:line)
    catch
      continue
    endtry
    if type(l:entry) != v:t_dict
      continue
    endif
    if empty(l:rec.cwd) && has_key(l:entry, 'cwd')
      let l:rec.cwd    = l:entry.cwd
      let l:rec.branch = get(l:entry, 'gitBranch', '')
    endif
    if empty(l:rec.snippet) && get(l:entry, 'type', '') ==# 'user'
      let l:rec.snippet = s:message_text(l:entry)
    endif
    if !empty(l:rec.cwd) && !empty(l:rec.snippet)
      break
    endif
  endfor
  return l:rec
endfunction

" Newest-first transcript paths for the current project, capped at the
" configured limit.
function! s:transcript_paths() abort
  let l:dir = claude#session#project_dir(getcwd())
  if !isdirectory(l:dir)
    return []
  endif
  let l:limit = s:closed_limit()
  if l:limit <= 0
    return []
  endif
  let l:paths = glob(l:dir . '/*.jsonl', 0, 1)
  call sort(l:paths, {a, b -> getftime(b) - getftime(a)})
  return l:paths[0 : l:limit - 1]
endfunction

" ── registry ─────────────────────────────────────────────────────────────────

function! claude#session#get(id) abort
  return get(s:sessions, a:id, {})
endfunction

function! claude#session#exists(id) abort
  return has_key(s:sessions, a:id)
endfunction

" Buffer numbers of every session currently live in this Vim instance.
function! claude#session#bufnrs() abort
  let l:out = []
  for l:rec in values(s:sessions)
    if l:rec.bufnr != -1 && bufexists(l:rec.bufnr)
      call add(l:out, l:rec.bufnr)
    endif
  endfor
  return l:out
endfunction

function! claude#session#by_bufnr(bufnr) abort
  for l:rec in values(s:sessions)
    if l:rec.bufnr == a:bufnr
      return l:rec
    endif
  endfor
  return {}
endfunction

" §5.1 — the status rules.
function! claude#session#status(id) abort
  if !has_key(s:sessions, a:id)
    return 'closed'
  endif
  let l:rec = s:sessions[a:id]
  " Fabricated records (tests) carry their status verbatim: there is no job
  " behind them to inspect.
  if get(l:rec, 'pinned', 0)
    return l:rec.status
  endif
  if l:rec.bufnr == -1 || !bufexists(l:rec.bufnr) || !has('terminal')
    return 'closed'
  endif
  let l:job = term_getjob(l:rec.bufnr)
  if l:job is v:null || job_status(l:job) !=# 'run'
    return 'closed'
  endif
  return (localtime() - l:rec.last_active) < s:idle_secs() ? 'active' : 'idle'
endfunction

" Fingerprint of the bottom of a terminal. Claude's spinner and its streaming
" output both touch the last lines, so this is enough to tell "working" from
" "waiting" without reading the whole screen.
function! s:term_tail(bufnr) abort
  if !has('terminal') || !bufexists(a:bufnr)
    return ''
  endif
  let l:size = term_getsize(a:bufnr)
  if type(l:size) != v:t_list || empty(l:size)
    return ''
  endif
  let l:rows = l:size[0]
  let l:acc  = []
  for l:i in range(max([1, l:rows - 4]), l:rows)
    call add(l:acc, term_getline(a:bufnr, l:i))
  endfor
  return join(l:acc, "\n")
endfunction

" Refresh live status. Returns 1 when any session changed state, so the panel
" knows whether a repaint is needed.
function! claude#session#poll() abort
  let l:changed = 0
  for l:rec in values(s:sessions)
    if get(l:rec, 'pinned', 0)
      continue
    endif
    let l:before = l:rec.status

    if l:rec.bufnr != -1
      let l:tail = s:term_tail(l:rec.bufnr)
      if l:tail !=# l:rec.term_tail
        let l:rec.term_tail   = l:tail
        let l:rec.last_active = localtime()
      endif
    endif

    let l:rec.status = claude#session#status(l:rec.id)

    " Reap: the job is gone, so drop the terminal buffer but keep the record
    " listed and resumable.
    if l:rec.status ==# 'closed' && l:rec.bufnr != -1
      let l:bufnr = l:rec.bufnr
      let l:rec.bufnr  = -1
      let l:rec.origin = 'disk'
      if bufexists(l:bufnr)
        silent! execute 'bwipeout! ' . l:bufnr
      endif
    endif

    if l:rec.status !=# l:before
      let l:changed = 1
    endif
  endfor
  return l:changed
endfunction

" Merge on-disk transcripts for the current project into the registry. A live
" record always wins over the disk record with the same id.
function! claude#session#refresh() abort
  let l:store = claude#store#load()
  for l:path in s:transcript_paths()
    let l:scan = s:scan_transcript(l:path)
    let l:id   = l:scan.id
    if has_key(s:sessions, l:id)
      continue
    endif
    let l:saved = get(l:store.sessions, l:id, {})
    let l:cwd   = !empty(l:scan.cwd) ? l:scan.cwd : get(l:saved, 'cwd', '')
    if empty(l:cwd)
      let l:group = {
            \ 'project': '(unknown)', 'worktree': '(unknown)',
            \ 'branch': '(unknown)' }
    else
      let l:group = claude#session#group_of(l:cwd)
    endif
    if !empty(l:scan.branch)
      let l:group.branch = l:scan.branch
    endif
    let l:name = get(l:saved, 'name', '')
    if empty(l:name)
      " Never named in Vim: fall back to the timestamp + first-message
      " labelling :ClaudeResume has always used.
      let l:name = strftime('%Y-%m-%d %H:%M', l:scan.created)
      if !empty(l:scan.snippet)
        let l:name .= ' — ' . l:scan.snippet
      endif
    endif
    let s:sessions[l:id] = s:make_record(l:id, l:name, -1, l:cwd, l:group,
          \ l:scan.created, 'disk')
  endfor

  " Named sessions that never got a transcript (started but never messaged)
  " exist only in the store. Bring back the ones belonging to this directory
  " so a name given yesterday is still on the panel today; opening one claims
  " its id for a fresh conversation.
  let l:cwd = getcwd()
  for [l:id, l:entry] in items(l:store.sessions)
    if has_key(s:sessions, l:id) || get(l:entry, 'cwd', '') !=# l:cwd
      continue
    endif
    let s:sessions[l:id] = s:make_record(l:id, get(l:entry, 'name', l:id), -1,
          \ l:cwd, claude#session#group_of(l:cwd),
          \ get(l:entry, 'created', localtime()), 'disk')
  endfor
endfunction

function! s:make_record(id, name, bufnr, cwd, group, created, origin) abort
  return {
        \ 'id':          a:id,
        \ 'name':        a:name,
        \ 'bufnr':       a:bufnr,
        \ 'cwd':         a:cwd,
        \ 'project':     a:group.project,
        \ 'worktree':    a:group.worktree,
        \ 'branch':      a:group.branch,
        \ 'status':      a:bufnr == -1 ? 'closed' : 'active',
        \ 'created':     a:created,
        \ 'last_active': localtime(),
        \ 'last_focus':  a:bufnr == -1 ? 0 : localtime(),
        \ 'origin':      a:origin,
        \ 'term_tail':   '',
        \ 'commands':    [],
        \ 'agents':      [],
        \ }
endfunction

" Every known session, newest and liveliest first.
function! claude#session#list() abort
  call claude#session#poll()
  let l:out = values(s:sessions)
  if !get(g:, 'claude_panel_show_closed', 1)
    let l:out = filter(copy(l:out), {_, r -> r.status !=# 'closed'})
  endif
  call sort(l:out, function('s:cmp_records'))
  return l:out
endfunction

" Live sessions before closed ones; within each, most recently touched first.
function! s:cmp_records(a, b) abort
  let l:la = a:a.status ==# 'closed' ? 1 : 0
  let l:lb = a:b.status ==# 'closed' ? 1 : 0
  if l:la != l:lb
    return l:la - l:lb
  endif
  " last_focus wins whenever it is set; a session that has never been focused
  " (a disk record) is ordered by when it was created.
  let l:ta = a:a.last_focus > 0 ? a:a.last_focus : a:a.created
  let l:tb = a:b.last_focus > 0 ? a:b.last_focus : a:b.created
  if l:ta != l:tb
    return l:tb - l:ta
  endif
  return a:a.name ==# a:b.name ? 0 : (a:a.name < a:b.name ? -1 : 1)
endfunction

" Sessions folded into Project > Worktree > Branch. The panel's only data
" source; it does no grouping of its own.
function! claude#session#tree() abort
  let l:tree  = []
  let l:pidx  = {}
  for l:rec in claude#session#list()
    if !has_key(l:pidx, l:rec.project)
      let l:pidx[l:rec.project] = len(l:tree)
      call add(l:tree, {
            \ 'label':     fnamemodify(l:rec.project, ':t'),
            \ 'path':      l:rec.project,
            \ 'key':       'p:' . l:rec.project,
            \ 'worktrees': [],
            \ 'index':     {},
            \ })
    endif
    let l:proj = l:tree[l:pidx[l:rec.project]]

    if !has_key(l:proj.index, l:rec.worktree)
      let l:proj.index[l:rec.worktree] = len(l:proj.worktrees)
      call add(l:proj.worktrees, {
            \ 'label':    l:rec.worktree,
            \ 'path':     l:rec.worktree,
            \ 'key':      'w:' . l:rec.project . '|' . l:rec.worktree,
            \ 'branches': [],
            \ 'index':    {},
            \ })
    endif
    let l:wt = l:proj.worktrees[l:proj.index[l:rec.worktree]]

    if !has_key(l:wt.index, l:rec.branch)
      let l:wt.index[l:rec.branch] = len(l:wt.branches)
      call add(l:wt.branches, {
            \ 'label':    l:rec.branch,
            \ 'key':      'b:' . l:rec.project . '|' . l:rec.worktree
            \             . '|' . l:rec.branch,
            \ 'sessions': [],
            \ })
    endif
    call add(l:wt.branches[l:wt.index[l:rec.branch]].sessions, l:rec)
  endfor
  return l:tree
endfunction

" ── CLI capabilities ─────────────────────────────────────────────────────────

" Whether the configured CLI understands --session-id and --name.
"
" The probe runs `<cmd> --help`, so it only runs when g:claude_cmd actually
" invokes the Claude binary. A stand-in command (tests use `sleep 30`) is
" never executed just to read its help.
function! claude#session#supports_flags() abort
  " An explicit override skips the probe entirely: 1 forces the flags on,
  " 0 forces them off.
  let l:override = get(g:, 'claude_session_flags', -1)
  if l:override >= 0
    return l:override
  endif
  if exists('s:flags_ok')
    return s:flags_ok
  endif
  let s:flags_ok = 0
  let l:words = split(get(g:, 'claude_cmd', 'claude'))
  if empty(l:words)
    return s:flags_ok
  endif
  if fnamemodify(l:words[0], ':t') !~# '^claude'
    return s:flags_ok
  endif
  let l:help = system(g:claude_cmd . ' --help 2>/dev/null </dev/null')
  let s:flags_ok = (l:help =~# '--session-id' && l:help =~# '--name') ? 1 : 0
  if !s:flags_ok
    call s:warn_once('flags',
          \ 'claude CLI has no --session-id/--name (needs 2.1+); '
          \ . 'session ids are adopted from transcripts instead')
  endif
  return s:flags_ok
endfunction

" Build the argument vector for the CLI.
"
" This must be a List, not a command string. :terminal and job_start() do not
" run a shell: a string command is split on whitespace with no quote handling,
" so shell-quoting an argument passes the quote characters through literally
" (--session-id '<uuid>' reaches Claude as "'<uuid>'", which it rejects as an
" invalid session id) and any name containing a space is torn into several
" arguments. The List form passes each argument through untouched.
function! s:build_argv(id, name, resume) abort
  let l:argv = split(get(g:, 'claude_cmd', 'claude'))
  if a:resume
    call extend(l:argv, ['--resume', a:id])
  elseif claude#session#supports_flags()
    call extend(l:argv, ['--session-id', a:id])
  endif
  if claude#session#supports_flags() && !empty(a:name)
    call extend(l:argv, ['--name', a:name])
  endif
  return l:argv
endfunction

" Start {argv} in the current window, returning its buffer number.
function! s:term_start(argv) abort
  return term_start(a:argv, {'curwin': 1})
endfunction

" ── naming ───────────────────────────────────────────────────────────────────

" Prompt for a session name. Returns [1, name] or [0, ''] when cancelled.
"
" Only CTRL-C cancels. In a terminal Vim <Esc> is indistinguishable from an
" empty line — inputdialog()'s cancelreturn is honoured by the GUI only — so
" an empty answer falls back to a timestamp name rather than silently
" throwing the session away.
function! s:prompt_name() abort
  if !get(g:, 'claude_session_prompt_name', 1)
    return [1, s:default_name()]
  endif
  try
    let l:answer = input('Session name: ')
  catch /^Vim:Interrupt$/
    return [0, '']
  endtry
  redraw
  return [1, empty(l:answer) ? s:default_name() : l:answer]
endfunction

function! s:default_name() abort
  return 'claude ' . strftime('%Y-%m-%d %H:%M')
endfunction

function! s:persist(rec) abort
  call claude#store#put(a:rec.id, {
        \ 'name':     a:rec.name,
        \ 'cwd':      a:rec.cwd,
        \ 'project':  a:rec.project,
        \ 'worktree': a:rec.worktree,
        \ 'branch':   a:rec.branch,
        \ 'created':  a:rec.created,
        \ })
endfunction

" ── lifecycle ────────────────────────────────────────────────────────────────

" Start a new session. Returns the session id, or '' when the user cancelled
" the name prompt or the terminal could not be opened.
"
" a:1 name         — prompts when omitted or empty
" a:2 placement    — Ex command that creates the window to spawn into.
"                    Defaults to the configured Claude split; pass '' to take
"                    over the current window (the panel does this, having
"                    already positioned itself).
function! claude#session#new(...) abort
  let l:name = a:0 > 0 ? a:1 : ''
  if empty(l:name)
    let [l:ok, l:name] = s:prompt_name()
    if !l:ok
      return ''
    endif
  endif

  if !has('terminal')
    echoerr 'claude.vim: terminal support required (Vim 8+)'
    return ''
  endif

  let l:id    = claude#session#uuid()
  let l:cwd   = getcwd()
  let l:group = claude#session#group_of(l:cwd)
  let l:known = s:known_transcripts()

  let l:place = a:0 > 1 ? a:2 : claude#split_cmd()
  if !empty(l:place)
    execute l:place
  endif
  try
    let l:bufnr = s:term_start(s:build_argv(l:id, l:name, 0))
  catch
    if !empty(l:place)
      close
    endif
    echoerr 'claude.vim: failed to start Claude: ' . v:exception
    return ''
  endtry

  let l:rec = s:make_record(l:id, l:name, l:bufnr, l:cwd, l:group,
        \ localtime(), 'live')
  let s:sessions[l:id] = l:rec

  call claude#apply_buf_options(l:id)
  call claude#input#collect_data(l:id)
  call s:persist(l:rec)

  if !claude#session#supports_flags()
    " No --session-id: discover the id the CLI chose by watching for a
    " transcript that was not there before we spawned.
    call timer_start(500, {-> s:adopt_id(l:id, l:known, 10)})
  endif

  call claude#panel#refresh()
  return l:id
endfunction

" Reopen a closed session. Returns the id, or '' on failure.
"
" When the CLI has a transcript for this id the conversation is resumed. When
" it does not — the session was started but never messaged, so Claude never
" persisted it — the same id is claimed for a fresh session instead. Either
" way the panel row, its name and its id survive; only the history differs.
"
" a:1 placement — as for claude#session#new().
function! claude#session#resume(id, ...) abort
  if !has_key(s:sessions, a:id)
    return ''
  endif
  let l:rec = s:sessions[a:id]
  if l:rec.bufnr != -1 && bufexists(l:rec.bufnr)
    return a:id
  endif
  if !has('terminal')
    echoerr 'claude.vim: terminal support required (Vim 8+)'
    return ''
  endif

  let l:resume = claude#session#has_transcript(a:id)
  let l:known  = l:resume ? {} : s:known_transcripts()

  let l:place = a:0 > 0 ? a:1 : claude#split_cmd()
  if !empty(l:place)
    execute l:place
  endif
  try
    let l:bufnr = s:term_start(s:build_argv(a:id, l:rec.name, l:resume))
  catch
    if !empty(l:place)
      close
    endif
    echoerr 'claude.vim: failed to open Claude: ' . v:exception
    return ''
  endtry

  let l:rec.bufnr       = l:bufnr
  let l:rec.status      = 'active'
  let l:rec.origin      = 'live'
  let l:rec.term_tail   = ''
  let l:rec.last_active = localtime()
  let l:rec.last_focus  = localtime()

  call claude#apply_buf_options(a:id)
  call claude#input#collect_data(a:id)

  if !l:resume && !claude#session#supports_flags()
    " Started fresh without --session-id: the CLI picked its own id, so watch
    " for the transcript and re-key the record onto it.
    call timer_start(500, {-> s:adopt_id(a:id, l:known, 10)})
  endif

  call claude#panel#refresh()
  return a:id
endfunction

function! s:known_transcripts() abort
  let l:dir = claude#session#project_dir(getcwd())
  if !isdirectory(l:dir)
    return {}
  endif
  let l:seen = {}
  for l:p in glob(l:dir . '/*.jsonl', 0, 1)
    let l:seen[fnamemodify(l:p, ':t:r')] = 1
  endfor
  return l:seen
endfunction

" Fallback for CLIs without --session-id: re-key the record once a transcript
" appears that did not exist when the session was spawned. Gives up after
" {retries} half-second attempts (~5s), leaving the provisional id in place.
function! s:adopt_id(provisional, known, retries) abort
  if !has_key(s:sessions, a:provisional)
    return
  endif
  let l:dir = claude#session#project_dir(s:sessions[a:provisional].cwd)
  for l:path in glob(l:dir . '/*.jsonl', 0, 1)
    let l:id = fnamemodify(l:path, ':t:r')
    if has_key(a:known, l:id) || has_key(s:sessions, l:id)
      continue
    endif
    let l:rec = remove(s:sessions, a:provisional)
    let l:rec.id = l:id
    let s:sessions[l:id] = l:rec
    if bufexists(l:rec.bufnr)
      call setbufvar(l:rec.bufnr, 'claude_session_id', l:id)
    endif
    call claude#store#remove(a:provisional)
    call s:persist(l:rec)
    call claude#panel#refresh()
    return
  endfor
  if a:retries > 0
    call timer_start(500, {-> s:adopt_id(a:provisional, a:known, a:retries - 1)})
  endif
endfunction

function! claude#session#rename(id, name) abort
  if !has_key(s:sessions, a:id) || empty(a:name)
    return
  endif
  let s:sessions[a:id].name = a:name
  call s:persist(s:sessions[a:id])
  call claude#panel#refresh()
endfunction

" End a session: stop its job and wipe the terminal buffer. The record stays,
" flipped to 'closed', so the conversation can be resumed later.
function! claude#session#delete(id) abort
  if !has_key(s:sessions, a:id)
    return
  endif
  let l:rec   = s:sessions[a:id]
  let l:bufnr = l:rec.bufnr
  let l:rec.bufnr  = -1
  let l:rec.status = 'closed'
  let l:rec.origin = 'disk'
  if l:bufnr != -1 && bufexists(l:bufnr)
    call claude#session#stop_job(l:bufnr)
    silent! execute 'bwipeout! ' . l:bufnr
  endif
  call claude#panel#refresh()
endfunction

" Delete the session and everything that remembers it: the record, its stored
" name, and its transcript.
function! claude#session#purge(id) abort
  if !has_key(s:sessions, a:id)
    return
  endif
  let l:cwd = s:sessions[a:id].cwd
  call claude#session#delete(a:id)
  call remove(s:sessions, a:id)
  call claude#store#remove(a:id)
  if !empty(l:cwd)
    call delete(claude#session#project_dir(l:cwd) . '/' . a:id . '.jsonl')
  endif
  call claude#panel#refresh()
endfunction

" Stop the terminal job in {bufnr} and block until it exits (up to 500 ms).
" Callers must do this before bwipeout! to avoid E947.
function! claude#session#stop_job(bufnr) abort
  if !has('terminal') || !bufexists(a:bufnr)
    return
  endif
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

" Path of a session's transcript, or '' when its cwd is unknown.
function! claude#session#transcript_path(id) abort
  let l:rec = get(s:sessions, a:id, {})
  if empty(l:rec) || empty(l:rec.cwd)
    return ''
  endif
  return claude#session#project_dir(l:rec.cwd) . '/' . a:id . '.jsonl'
endfunction

" Whether the CLI has anything on disk for this session.
"
" Claude writes a transcript lazily — only once the conversation has content —
" so a session that was started but never messaged leaves nothing behind, and
" `claude --resume <id>` rejects it with "No session found with ID". Callers
" must check this before trying to resume.
function! claude#session#has_transcript(id) abort
  let l:path = claude#session#transcript_path(a:id)
  return !empty(l:path) && filereadable(l:path)
endfunction

" §5.4 — a session that is closed here may be live in another Vim instance.
" A transcript touched in the last few seconds is the only evidence available,
" so treat that as "someone else is driving this".
function! claude#session#is_foreign_active(id) abort
  let l:rec = get(s:sessions, a:id, {})
  if empty(l:rec) || empty(l:rec.cwd)
    return 0
  endif
  let l:path = claude#session#project_dir(l:rec.cwd) . '/' . a:id . '.jsonl'
  if !filereadable(l:path)
    return 0
  endif
  return (localtime() - getftime(l:path)) < 5
endfunction

" Record that {id}'s window was entered — drives picker ordering.
function! claude#session#touch_focus(id) abort
  if has_key(s:sessions, a:id)
    let s:sessions[a:id].last_focus = localtime()
  endif
endfunction

" ── target resolution (§3.4) ─────────────────────────────────────────────────

" Live sessions, most recently focused first.
function! claude#session#live() abort
  call claude#session#poll()
  let l:live = filter(values(s:sessions), {_, r -> r.status !=# 'closed'})
  call sort(l:live, function('s:cmp_records'))
  return l:live
endfunction

" The session a command should act on when no choice is needed: the one whose
" terminal holds the cursor, or the only live session. '' when ambiguous.
function! claude#session#current() abort
  let l:here = getbufvar(bufnr('%'), 'claude_session_id', '')
  if !empty(l:here) && has_key(s:sessions, l:here)
        \ && claude#session#status(l:here) !=# 'closed'
    return l:here
  endif
  let l:live = claude#session#live()
  if len(l:live) == 1
    return l:live[0].id
  endif
  return ''
endfunction

" Resolve the session for a command, then call {Fn} with its id.
"
" Resolution is asynchronous because popup_menu() is: Fn is invoked from the
" popup's callback, or straight away when no choice is needed. Fn receives ''
" when the user cancels.
function! claude#session#target(prompt, Fn) abort
  let l:id = claude#session#current()
  if !empty(l:id)
    call a:Fn(l:id)
    return
  endif
  if empty(claude#session#live())
    call a:Fn(claude#session#new())
    return
  endif
  call claude#session#pick(a:prompt, a:Fn)
endfunction

" Present the live sessions plus a "New session" entry, then call {Fn} with
" the chosen id ('' when cancelled).
function! claude#session#pick(prompt, Fn) abort
  let l:live = claude#session#live()
  let l:ids  = map(copy(l:live), {_, r -> r.id})
  call add(l:ids, '')                  " trailing entry: new session
  let l:items = map(copy(l:live),
        \ {_, r -> claude#panel#icon(r.status) . ' ' . r.name
        \          . ' — ' . r.branch})
  call add(l:items, '+ New session…')

  if s:use_popup()
    call popup_menu(l:items, {
          \ 'title':    ' ' . a:prompt . ' ',
          \ 'callback': {_, idx -> s:picked(l:ids, idx, a:Fn)},
          \ 'filter':   'popup_filter_menu',
          \ 'padding':  [0, 1, 0, 1],
          \ 'border':   [],
          \ })
    return
  endif

  let l:menu = [a:prompt . ':']
  let l:i = 1
  for l:item in l:items
    call add(l:menu, printf('%d. %s', l:i, l:item))
    let l:i += 1
  endfor
  call s:picked(l:ids, inputlist(l:menu), a:Fn)
endfunction

" popup_menu() reports a 1-based index, or -1/0 when dismissed.
function! s:picked(ids, idx, Fn) abort
  redraw
  if a:idx < 1 || a:idx > len(a:ids)
    call a:Fn('')
    return
  endif
  let l:id = a:ids[a:idx - 1]
  call a:Fn(empty(l:id) ? claude#session#new() : l:id)
endfunction

" g:claude_no_popup forces the inputlist() path (used by the tests, and by
" anyone whose terminal renders popups badly).
function! s:use_popup() abort
  return has('popupwin') && !get(g:, 'claude_no_popup', 0)
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

" Drop all registry state. Does not touch jobs — callers clean those up.
function! claude#session#_reset() abort
  let s:sessions    = {}
  let s:group_cache = {}
  let s:warned      = {}
  unlet! s:flags_ok
endfunction

" The argument vector that would be handed to the CLI. Test seam.
function! claude#session#_argv(id, name, resume) abort
  return s:build_argv(a:id, a:name, a:resume)
endfunction

" Insert a fabricated record, so panel rendering and grouping can be tested
" without spawning a process.
function! claude#session#_inject(rec) abort
  let l:group = {
        \ 'project':  get(a:rec, 'project',  '(no project)'),
        \ 'worktree': get(a:rec, 'worktree', '/tmp'),
        \ 'branch':   get(a:rec, 'branch',   '(no branch)'),
        \ }
  let l:full = s:make_record(
        \ get(a:rec, 'id', claude#session#uuid()),
        \ get(a:rec, 'name', 'unnamed'),
        \ get(a:rec, 'bufnr', -1),
        \ get(a:rec, 'cwd', '/tmp'),
        \ l:group,
        \ get(a:rec, 'created', localtime()),
        \ get(a:rec, 'origin', 'disk'))
  if has_key(a:rec, 'status')
    let l:full.status = a:rec.status
    let l:full.pinned = 1
  endif
  let l:full.last_focus = get(a:rec, 'last_focus', l:full.last_focus)
  let s:sessions[l:full.id] = l:full
  return l:full.id
endfunction
