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
"   named        1 when the user typed the name; 0 when they left the prompt
"                blank and Claude names the conversation itself
"   snippet      first thing that was asked of the session, from its
"                transcript — what an unnamed session is labelled with
"   workspace    id of the workspace (git worktree) the session runs in, or ''
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

" Finished sessions nobody named, and finished sessions nobody has touched for
" days, are hidden the way NERDTree hides dotfiles: still in the registry, just
" not listed until the panel's I key asks for them. See is_buried().
let s:show_hidden = 0

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

" Days after which a finished session is buried. 0 buries none of them.
function! s:stale_days() abort
  return get(g:, 'claude_panel_stale_days', 2)
endfunction

" What the bottom of a Claude terminal looks like while it is working, and
" while it is waiting for an answer. Both are patterns because they track
" another program's output, which is not ours to promise: a pattern that stops
" matching costs the state, never a wrong answer.
function! s:working_pat() abort
  return get(g:, 'claude_panel_working_pat', 'esc to interrupt')
endfunction

function! s:waiting_pat() abort
  return get(g:, 'claude_panel_waiting_pat',
        \ '\%(^\|\n\)\s*❯\=\s*1\.\s\|Do you want\|(y/n)')
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

" Forget every memoised {project, worktree, branch} and re-derive them for
" every loaded session, persisting the ones that changed.
"
" group_of() only ever asks git once per cwd for the life of the process, so
" a directory queried too early (mid `git worktree add`, before its .git
" link settles) stays wrong until now. Live sessions are worse off still:
" refresh() never revisits a cwd already in s:sessions, so a bad group baked
" in at spawn time is otherwise permanent until Vim restarts.
function! claude#session#regroup() abort
  let s:group_cache = {}
  for l:rec in values(s:sessions)
    let l:group = claude#session#group_of(l:rec.cwd)
    if l:rec.project ==# l:group.project
          \ && l:rec.worktree ==# l:group.worktree
          \ && l:rec.branch ==# l:group.branch
      continue
    endif
    let l:rec.project  = l:group.project
    let l:rec.worktree = l:group.worktree
    let l:rec.branch   = l:group.branch
    call s:persist(l:rec)
  endfor
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

" Transcript directories worth scanning: the one Vim is in, plus every
" workspace of this repository. Claude files a transcript under the directory
" the session ran in, so a workspace session's conversations live under its
" own worktree and are invisible from the main checkout otherwise.
function! s:project_dirs() abort
  let l:seen = {}
  let l:here = claude#session#project_dir(getcwd())
  if isdirectory(l:here)
    let l:seen[l:here] = 1
  endif
  for l:ws in claude#workspace#list()
    let l:dir = claude#session#project_dir(l:ws.path)
    if isdirectory(l:dir)
      let l:seen[l:dir] = 1
    endif
  endfor
  return keys(l:seen)
endfunction

" Newest-first transcript paths for the current project, capped at the
" configured limit. The cap is across the project, not per directory.
function! s:transcript_paths() abort
  let l:limit = s:closed_limit()
  if l:limit <= 0
    return []
  endif
  let l:paths = []
  for l:dir in s:project_dirs()
    call extend(l:paths, glob(l:dir . '/*.jsonl', 0, 1))
  endfor
  if empty(l:paths)
    return []
  endif
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

" What the bottom of the terminal says the session is doing.
"
" Claude prints its own state down there: a spinner footer while it works, a
" numbered list while it waits for an answer. s:term_tail() already captures
" those rows on every poll, so reading them costs one regex over a string the
" poll has in hand.
"
" '' means "cannot tell" — the caller falls back to the idle timer, which is
" what every build before this one used on its own. Working is tested first:
" the spinner is only on screen while Claude is not waiting for anything.
function! s:classify(tail) abort
  if empty(a:tail)
    return ''
  endif
  if a:tail =~# s:working_pat()
    return 'active'
  endif
  if a:tail =~# s:waiting_pat()
    return 'waiting'
  endif
  return ''
endfunction

" §5.1 — the status rules.
"
"   closed   no job behind it
"   waiting  the terminal is showing a question
"   active   the terminal is working, or produced output just now
"   idle     running, and none of the above
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
  " The tail is whatever poll() last saw. Reading it again here would double
  " the terminal reads for no new information.
  let l:said = s:classify(get(l:rec, 'term_tail', ''))
  if !empty(l:said)
    return l:said
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

" Give an unnamed session something to be called.
"
" A live session has no transcript when it is spawned, so there is nothing to
" label it with until Claude writes the first message. The file is re-read only
" when it has changed since the last look, and not at all once a snippet has
" been found or a name has been typed.
function! s:adopt_snippet(rec) abort
  if !empty(get(a:rec, 'snippet', '')) || !empty(get(a:rec, 'name', ''))
    return
  endif
  let l:path = claude#session#transcript_path(a:rec.id)
  if empty(l:path) || !filereadable(l:path)
    return
  endif
  let l:ftime = getftime(l:path)
  if l:ftime == get(a:rec, 'scan_ftime', 0)
    return
  endif
  let a:rec.scan_ftime = l:ftime
  let a:rec.snippet    = s:scan_transcript(l:path).snippet
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

    call s:adopt_snippet(l:rec)
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
    " A session Claude started on its own was never named here. It keeps an
    " empty name and is labelled from its first message instead — a name
    " nobody typed is not a name, and a timestamp is not a label.
    let l:named = s:was_named(l:saved)
    let l:name  = l:named ? get(l:saved, 'name', '') : ''
    let l:rec   = s:make_record(l:id, l:name, -1, l:cwd, l:group,
          \ l:scan.created, 'disk', l:named,
          \ get(l:saved, 'workspace', ''))
    let l:rec.snippet    = l:scan.snippet
    let l:rec.scan_ftime = getftime(l:path)
    let s:sessions[l:id] = l:rec
  endfor

  " Named sessions that never got a transcript (started but never messaged)
  " exist only in the store. Bring back the ones belonging to this project so
  " a name given yesterday is still on the panel today; opening one claims its
  " id for a fresh conversation.
  for [l:id, l:entry] in items(l:store.sessions)
    if has_key(s:sessions, l:id) || !s:belongs_here(l:entry)
      continue
    endif
    let l:cwd = get(l:entry, 'cwd', '')
    let s:sessions[l:id] = s:make_record(l:id, get(l:entry, 'name', l:id), -1,
          \ l:cwd, claude#session#group_of(l:cwd),
          \ get(l:entry, 'created', localtime()), 'disk',
          \ s:was_named(l:entry), get(l:entry, 'workspace', ''))
  endfor
endfunction

" Whether a stored entry belongs to the project Vim is in.
"
" The directory alone is not enough: a session given a workspace ran in its own
" worktree, so matching cwd would lose it the moment Vim starts anywhere else
" in the repository — which is every time you open it in the main checkout.
" The project root is what every worktree of one repository shares.
function! s:belongs_here(entry) abort
  if get(a:entry, 'cwd', '') ==# getcwd()
    return 1
  endif
  let l:project = get(a:entry, 'project', '')
  if empty(l:project) || l:project ==# '(no project)'
    " Written before the project was recorded, or outside a repository: the
    " directory is all there is to go on.
    return 0
  endif
  return l:project ==# claude#session#group_of(getcwd()).project
endfunction

function! s:make_record(id, name, bufnr, cwd, group, created, origin,
      \ named, workspace) abort
  return {
        \ 'id':          a:id,
        \ 'name':        a:name,
        \ 'named':       a:named,
        \ 'snippet':     '',
        \ 'scan_ftime':  0,
        \ 'workspace':   a:workspace,
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

" Whether unnamed sessions are being listed.
function! claude#session#show_hidden() abort
  return s:show_hidden
endfunction

" Flip that, the way NERDTree's I flips dotfiles. Returns the new state.
function! claude#session#toggle_hidden() abort
  let s:show_hidden = !s:show_hidden
  return s:show_hidden
endfunction

" Whether a record belongs to the tail nobody wants to look at: a session that
" has finished, and that either nobody named or nobody has touched for days.
"
" A live session is never buried, whatever it is called. One that is waiting
" for an answer is the last thing to hide, and since it is labelled from its
" first message it is readable without a name.
function! claude#session#is_buried(rec) abort
  if get(a:rec, 'status', 'closed') !=# 'closed'
    return 0
  endif
  if !get(a:rec, 'named', 1)
    return 1
  endif
  let l:days = s:stale_days()
  if l:days <= 0
    return 0
  endif
  let l:seen = get(a:rec, 'last_focus', 0) > 0
        \ ? a:rec.last_focus : get(a:rec, 'created', 0)
  return (localtime() - l:seen) > l:days * 86400
endfunction

" Every known session, newest and liveliest first — the whole registry, with
" nothing hidden. For callers that are not the panel and do their own
" filtering: the resume picker and the diff tree's branch list.
function! claude#session#all() abort
  call claude#session#poll()
  let l:out = values(s:sessions)
  call sort(l:out, function('s:cmp_records'))
  return l:out
endfunction

" The same list, with the buried tail left out unless it has been asked for.
function! claude#session#list() abort
  let l:out = claude#session#all()
  if !s:show_hidden
    let l:out = filter(copy(l:out), {_, r -> !claude#session#is_buried(r)})
  endif
  if !get(g:, 'claude_panel_show_closed', 1)
    let l:out = filter(copy(l:out), {_, r -> r.status !=# 'closed'})
  endif
  return l:out
endfunction

" How many records the hide rule is keeping out of the list right now.
function! claude#session#buried_count() abort
  if s:show_hidden
    return 0
  endif
  return len(filter(values(s:sessions),
        \ {_, r -> claude#session#is_buried(r)}))
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

" The state groups, in the order the panel draws them: what a session is doing
" rather than where it lives. The state view's only data source, as tree() is
" the place view's.
"
" Done is listed even when it is empty, as long as the registry holds a
" finished session — including one the hide rule is keeping out of the list, so
" that the tail is never invisible.
let s:GROUPS = [
      \ ['waiting', 'Needs you', 'st:waiting'],
      \ ['active',  'Working',   'st:working'],
      \ ['idle',    'Idle',      'st:idle'],
      \ ['closed',  'Done',      'st:done'],
      \ ]

" a:1 — 1 to include the buried tail, which is what the panel's filter does:
" a row asked for by name is not a row to hide.
function! claude#session#groups(...) abort
  let l:all = a:0 > 0 && a:1
  let l:by  = {}
  for [l:status, l:label, l:key] in s:GROUPS
    let l:by[l:status] = []
  endfor

  for l:rec in (l:all ? claude#session#all() : claude#session#list())
    let l:status = has_key(l:by, l:rec.status) ? l:rec.status : 'idle'
    call add(l:by[l:status], l:rec)
  endfor

  let l:buried = l:all ? 0 : claude#session#buried_count()
  let l:out    = []
  for [l:status, l:label, l:key] in s:GROUPS
    let l:count = len(l:by[l:status])
    if l:status ==# 'closed'
      if l:count == 0 && l:buried == 0
        continue
      endif
    elseif l:count == 0
      continue
    endif
    call add(l:out, {
          \ 'key':      l:key,
          \ 'label':    l:label,
          \ 'status':   l:status,
          \ 'sessions': l:by[l:status],
          \ 'buried':   l:status ==# 'closed' ? l:buried : 0,
          \ })
  endfor
  return l:out
endfunction

" Sessions folded into Project > Worktree > Branch. The place view's data
" source; it does no grouping of its own.
"
" a:1 — 1 to include the buried tail, as for groups().
function! claude#session#tree(...) abort
  let l:all   = a:0 > 0 && a:1
  let l:tree  = []
  let l:pidx  = {}
  for l:rec in (l:all ? claude#session#all() : claude#session#list())
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

" Start {argv} in the current window, returning its buffer number. {cwd} is
" the directory the job runs in — a workspace's worktree, or '' for wherever
" Vim already is.
function! s:term_start(argv, cwd) abort
  if empty(a:cwd) || !isdirectory(a:cwd) || a:cwd ==# getcwd()
    return term_start(a:argv, {'curwin': 1})
  endif
  try
    return term_start(a:argv, {'curwin': 1, 'cwd': a:cwd})
  catch /E475\|E118\|E731/
    " Vim before 8.0.1685 has no cwd option for term_start(); the job
    " inherits the window's directory instead.
    execute 'lcd ' . fnameescape(a:cwd)
    return term_start(a:argv, {'curwin': 1})
  endtry
endfunction

" Where a session should be spawned: its workspace when it still has one,
" else the directory it was started in.
function! s:spawn_dir(rec) abort
  let l:id = get(a:rec, 'workspace', '')
  if empty(l:id)
    return a:rec.cwd
  endif
  let l:ws = claude#workspace#get(l:id)
  if empty(l:ws)
    call s:warn_once('workspace-gone-' . l:id,
          \ 'workspace ' . l:id . ' is gone; opening in ' . a:rec.cwd)
    return a:rec.cwd
  endif
  return l:ws.path
endfunction

" ── naming ───────────────────────────────────────────────────────────────────

" Prompt for the branch to give the session a workspace on. Returns
" [1, branch] — an empty branch meaning "no workspace" — or [0, ''] when the
" user pressed CTRL-C.
"
" Completion is the diff tree's, so the same local and remote branches are
" offered here as by :ClaudeDiffBase. A name that matches nothing is still
" accepted: claude#workspace#create() branches it off HEAD.
function! s:prompt_branch() abort
  try
    let l:answer = input('Branch (blank for no workspace): ', '',
          \ 'customlist,claude#difftree#complete_branch')
  catch /^Vim:Interrupt$/
    return [0, '']
  endtry
  redraw
  return [1, trim(l:answer)]
endfunction

" Prompt for a session name. Returns [1, name] or [0, ''] when cancelled.
"
" Only CTRL-C cancels. In a terminal Vim <Esc> is indistinguishable from an
" empty line — inputdialog()'s cancelreturn is honoured by the GUI only — so
" an empty answer is taken at face value: the session goes unnamed and Claude
" names the conversation itself.
function! s:prompt_name() abort
  try
    let l:answer = input('Session name: ')
  catch /^Vim:Interrupt$/
    return [0, '']
  endtry
  redraw
  return [1, trim(l:answer)]
endfunction

" Names earlier versions minted for a session whose name prompt was left
" empty: 'claude ' plus the time. Nobody chose one, so they are not names.
let s:AUTO_NAME = '^claude \d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}$'

" Whether a stored entry was named by the user.
"
" An auto-generated timestamp is never a name, whatever the record claims:
" those were minted when the prompt was skipped or left blank, which is the
" same answer that leaves a session nameless today. Otherwise the flag decides,
" and entries written before it existed fall back to having a name at all.
function! s:was_named(entry) abort
  let l:name = get(a:entry, 'name', '')
  if l:name =~# s:AUTO_NAME
    return 0
  endif
  if has_key(a:entry, 'named')
    return a:entry.named
  endif
  return !empty(l:name)
endfunction

" What the panel and the pickers show for a record.
"
" Only 11 of the 130 sessions on this machine carry a name a human typed, so a
" name is the exception and not the identity. What was asked of a session
" first is a better label than its id, and it is already read from the
" transcript to place the record.
function! claude#session#label(rec) abort
  if !empty(get(a:rec, 'name', ''))
    return a:rec.name
  endif
  if !empty(get(a:rec, 'snippet', ''))
    return a:rec.snippet
  endif
  return '(unnamed ' . strpart(a:rec.id, 0, 8) . ')'
endfunction

function! s:persist(rec) abort
  call claude#store#put(a:rec.id, {
        \ 'name':      a:rec.name,
        \ 'named':     a:rec.named,
        \ 'workspace': a:rec.workspace,
        \ 'cwd':       a:rec.cwd,
        \ 'project':   a:rec.project,
        \ 'worktree':  a:rec.worktree,
        \ 'branch':    a:rec.branch,
        \ 'created':   a:rec.created,
        \ })
endfunction

" ── lifecycle ────────────────────────────────────────────────────────────────

" Start a new session. Returns the session id, or '' when the user cancelled
" a prompt or the terminal could not be opened.
"
" a:1 name         — skips both prompts when given
" a:2 placement    — Ex command that creates the window to spawn into.
"                    Defaults to the configured Claude split; pass '' to take
"                    over the current window (the panel does this, having
"                    already positioned itself).
function! claude#session#new(...) abort
  let l:opts = {'name': a:0 > 0 ? a:1 : ''}
  if a:0 > 1
    let l:opts.placement = a:2
  endif
  " With the prompts turned off there is nothing to name the session after, so
  " it is left nameless and Claude names the conversation itself — the same
  " answer as leaving the prompt blank.
  let l:opts.prompt = empty(l:opts.name)
        \ && get(g:, 'claude_session_prompt_name', 1)
  return claude#session#spawn(l:opts)
endfunction

" The one way a session is started. Every key, command and picker goes through
" here; claude#session#new() is the shape this had before the panel needed to
" create a session without asking anything.
"
" opts:
"   prompt     1 asks for a branch and then a name before anything is created
"   ask_name   1 asks for a name only — the panel's n key, which reads the
"              workspace off the row under the cursor rather than asking
"   name       session name; '' leaves it unnamed and it labels itself from
"              its first message instead
"   branch     branch to give the session a workspace on; '' for none
"   workspace  id of an existing workspace to run in — what the panel's n key
"              passes. Ignored when a branch is given, which creates one
"   cwd        directory to run in when there is no workspace to name: a
"              worktree the plugin did not create, so there is no id for it
"   placement  Ex command creating the window to spawn into; '' takes over the
"              current window. Absent means the configured Claude split
"
" With prompting on, the two answers decide where the session lives:
"
"   branch + name    a workspace called <name> on <branch>
"   branch           a workspace named after the branch, uniquified
"   name             no workspace; the selected one, or the current directory
"   neither          the same, and the session goes unnamed
function! claude#session#spawn(opts) abort
  let l:name   = get(a:opts, 'name', '')
  let l:named  = !empty(l:name)
  let l:branch = get(a:opts, 'branch', '')

  if get(a:opts, 'prompt', 0)
    let [l:ok, l:branch] = s:prompt_branch()
    if !l:ok
      return ''
    endif
  endif
  if get(a:opts, 'prompt', 0) || get(a:opts, 'ask_name', 0)
    let [l:ok, l:name] = s:prompt_name()
    if !l:ok
      return ''
    endif
    let l:named = !empty(l:name)
  endif

  if !has('terminal')
    echoerr 'claude.vim: terminal support required (Vim 8+)'
    return ''
  endif

  " A workspace record with an empty id is the main checkout: somewhere to run,
  " but not a workspace to belong to.
  let l:ws = {}
  if !empty(l:branch)
    let l:ws = claude#workspace#create(l:branch, l:name)
  elseif !empty(get(a:opts, 'workspace', ''))
    " Asked for by id: an existing workspace, so nothing is created and the
    " session is not named after it — it was not the user's answer to a
    " question, it was where the cursor happened to be.
    let l:ws = claude#workspace#get(a:opts.workspace)
  endif
  if !empty(l:ws) && !empty(l:branch) && !l:named
    " No name was typed, so the workspace's — the branch's, uniquified —
    " becomes the session's too.
    let l:name  = l:ws.name
    let l:named = 1
  endif

  let l:id  = claude#session#uuid()
  let l:cwd = get(a:opts, 'cwd', '')
  if !empty(l:ws)
    let l:cwd = l:ws.path
  elseif empty(l:cwd) || !isdirectory(l:cwd)
    let l:cwd = claude#workspace#cwd()
  endif
  let l:group = claude#session#group_of(l:cwd)
  let l:known = s:known_transcripts(l:cwd)

  let l:place = has_key(a:opts, 'placement')
        \ ? a:opts.placement : claude#split_cmd()
  if !empty(l:place)
    execute l:place
  endif
  try
    let l:bufnr = s:term_start(s:build_argv(l:id, l:name, 0), l:cwd)
  catch
    if !empty(l:place)
      close
    endif
    echoerr 'claude.vim: failed to start Claude: ' . v:exception
    return ''
  endtry

  let l:rec = s:make_record(l:id, l:name, l:bufnr, l:cwd, l:group,
        \ localtime(), 'live', l:named, empty(l:ws) ? '' : l:ws.id)
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

" Where the CLI keeps its live registry, one JSON file per process it has
" running (`~/.claude/sessions/<pid>.json`), each naming the sessionId that
" process holds open. This is entirely a CLI concern — the plugin runs no
" daemon of its own — but a terminal force-closed instead of let Claude exit
" cleanly can leave one of these behind, and the CLI then refuses to resume
" that session as "already in use" even though nothing is really using it.
function! s:sessions_dir() abort
  return get(g:, 'claude_sessions_dir', expand('~/.claude/sessions'))
endfunction

" pid of the CLI process still holding {id} open, or 0 when the registry
" names none, or names one that is no longer actually alive.
function! s:holder_pid(id) abort
  let l:dir = s:sessions_dir()
  if !isdirectory(l:dir)
    return 0
  endif
  for l:path in glob(l:dir . '/*.json', 0, 1)
    let l:pid = str2nr(fnamemodify(l:path, ':t:r'))
    if l:pid <= 0 || l:pid == getpid()
      continue
    endif
    let l:body = join(readfile(l:path), "\n")
    if l:body !~# '"sessionId"\s*:\s*"' . a:id . '"'
      continue
    endif
    call system('kill -0 ' . l:pid . ' 2>/dev/null')
    if v:shell_error == 0
      return l:pid
    endif
  endfor
  return 0
endfunction

" Before resuming {id}: if the CLI's own registry still names a live process
" holding it, that is almost always the ghost of a terminal that got closed
" out from under Claude rather than a session genuinely in use elsewhere —
" ask to kill it so the resume that follows does not just fail with "session
" already in use". Returns 1 to proceed, 0 to abort the resume.
function! s:preflight_resume(id) abort
  let l:pid = s:holder_pid(a:id)
  if l:pid == 0
    return 1
  endif
  let l:msg = 'Session ' . strpart(a:id, 0, 8) . '... is still held by process '
        \ . l:pid . " (likely a terminal that was closed\nwithout letting "
        \ . "Claude exit). Kill it and resume here?"
  if confirm(l:msg, "&Kill and resume\n&Cancel", 2) != 1
    return 0
  endif
  call system('kill ' . l:pid)
  " Give it a moment to actually release the lock before the CLI is asked
  " to resume onto it.
  sleep 300m
  return 1
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
  if l:resume && !s:preflight_resume(a:id)
    return ''
  endif
  let l:dir    = s:spawn_dir(l:rec)
  let l:known  = l:resume ? {} : s:known_transcripts(l:dir)
  " Taken even for a genuine resume, only used if it turns out to be one the
  " CLI refuses — see s:retry_as_fork().
  let l:before = l:resume ? s:known_transcripts(l:dir) : {}

  let l:place = a:0 > 0 ? a:1 : claude#split_cmd()
  if !empty(l:place)
    execute l:place
  endif
  try
    let l:bufnr = s:term_start(s:build_argv(a:id, l:rec.name, l:resume), l:dir)
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
  elseif l:resume
    " s:preflight_resume() already ruled out an orphaned process holding this
    " id; whatever is left is a lock the CLI itself tracks in a way nothing
    " local can see. Watch for that specific refusal and route around it.
    call timer_start(400, {-> s:check_resumed(a:id, l:bufnr, l:dir, l:before, 8)})
  endif

  call claude#panel#refresh()
  return a:id
endfunction

" The CLI's own text for the refusal s:preflight_resume() cannot see coming
" (no local process or registry entry ever names it — it is tracked some
" other way inside the CLI). Matched case-insensitively against the whole
" scrollback, not just the last line, since it is the only line printed
" before the process exits.
let s:ALREADY_IN_USE_PAT = 'already in use'

" A resume whose job has already died with that refusal sitting in its
" scrollback hit a lock s:preflight_resume() could not see or clear. Waits up
" to {retries} * 300ms for the job to either keep running (success — nothing
" to do) or die with that specific message before giving up and leaving
" whatever is on screen alone.
function! s:check_resumed(id, bufnr, dir, before, retries) abort
  if !has_key(s:sessions, a:id) || !bufexists(a:bufnr)
    return
  endif
  let l:job = term_getjob(a:bufnr)
  if l:job isnot v:null && job_status(l:job) ==# 'run'
    if a:retries > 0
      call timer_start(300,
            \ {-> s:check_resumed(a:id, a:bufnr, a:dir, a:before, a:retries - 1)})
    endif
    return
  endif
  if join(getbufline(a:bufnr, 1, '$'), "\n") !~? s:ALREADY_IN_USE_PAT
    return
  endif
  call s:retry_as_fork(a:id, a:bufnr, a:dir, a:before)
endfunction

" Continue {old_id}'s conversation under a fresh id instead — --fork-session
" copies its history forward rather than resuming the locked id directly, so
" whatever s:check_resumed() caught never has a say. The dead terminal is
" replaced in place so the session keeps its window; once the CLI's new
" transcript appears the record is re-keyed onto it and the now-superseded
" original (transcript and store entry both) is dropped, so it does not also
" linger in the panel as an unrelated, unnamed "disk" session.
function! s:retry_as_fork(old_id, bufnr, dir, before) abort
  if !has_key(s:sessions, a:old_id)
    return
  endif
  let l:rec = s:sessions[a:old_id]
  call claude#session#stop_job(a:bufnr)
  let l:win = bufwinid(a:bufnr)
  if l:win != -1
    call win_gotoid(l:win)
  endif
  silent! execute 'bwipeout! ' . a:bufnr

  let l:argv = split(get(g:, 'claude_cmd', 'claude'))
  call extend(l:argv, ['--resume', a:old_id, '--fork-session'])
  if claude#session#supports_flags() && !empty(l:rec.name)
    call extend(l:argv, ['--name', l:rec.name])
  endif
  try
    let l:bufnr = s:term_start(l:argv, a:dir)
  catch
    echoerr 'claude.vim: failed to fork past a stuck resume: ' . v:exception
    return
  endtry

  let l:rec.bufnr       = l:bufnr
  let l:rec.status      = 'active'
  let l:rec.origin      = 'live'
  let l:rec.term_tail   = ''
  let l:rec.last_active = localtime()
  let l:rec.last_focus  = localtime()
  call claude#apply_buf_options(a:old_id)
  call claude#input#collect_data(a:old_id)
  call claude#panel#refresh()

  call timer_start(500, {-> s:adopt_forked_id(a:old_id, a:dir, a:before, 10)})
endfunction

" Once the fork's own transcript shows up, move the record onto its id and
" erase the id it replaced — the store entry and the original transcript
" file both, so a later refresh() does not adopt that file as a second,
" nameless session. Gives up silently after {retries}: the record stays
" under the old id, which is exactly what happened before this existed.
function! s:adopt_forked_id(old_id, dir, before, retries) abort
  if !has_key(s:sessions, a:old_id)
    return
  endif
  let l:dir = claude#session#project_dir(a:dir)
  for l:path in glob(l:dir . '/*.jsonl', 0, 1)
    let l:id = fnamemodify(l:path, ':t:r')
    if l:id ==# a:old_id || has_key(a:before, l:id) || has_key(s:sessions, l:id)
      continue
    endif
    let l:rec = remove(s:sessions, a:old_id)
    let l:rec.id = l:id
    let s:sessions[l:id] = l:rec
    if bufexists(l:rec.bufnr)
      call setbufvar(l:rec.bufnr, 'claude_session_id', l:id)
    endif
    call s:persist(l:rec)
    call claude#store#remove(a:old_id)
    call delete(l:dir . '/' . a:old_id . '.jsonl')
    call claude#panel#refresh()
    return
  endfor
  if a:retries > 0
    call timer_start(500,
          \ {-> s:adopt_forked_id(a:old_id, a:dir, a:before, a:retries - 1)})
  endif
endfunction

" Transcript ids already in {cwd}'s directory. Taken before a session is
" spawned so the one it goes on to write can be told apart; it must be read
" from the directory that session will actually run in, which for a workspace
" session is not the one Vim is in.
function! s:known_transcripts(cwd) abort
  let l:dir = claude#session#project_dir(a:cwd)
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
  let s:sessions[a:id].name  = a:name
  " Naming a session is what un-hides it.
  let s:sessions[a:id].named = 1
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

" Live sessions, most recently focused first. Unnamed ones count: they are
" hidden from the panel's list, not from the session count or the pickers.
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
        \ {_, r -> claude#panel#icon(r.status) . ' '
        \          . claude#session#label(r) . ' — ' . r.branch})
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
  let s:show_hidden = 0
  unlet! s:flags_ok
endfunction

" The argument vector that would be handed to the CLI. Test seam.
function! claude#session#_argv(id, name, resume) abort
  return s:build_argv(a:id, a:name, a:resume)
endfunction

" What the bottom of a terminal would be read as. Test seam.
function! claude#session#_classify(tail) abort
  return s:classify(a:tail)
endfunction

" pid of the process the CLI's own registry says still holds {id} open, or 0.
" Test seam — reads g:claude_sessions_dir rather than ~/.claude/sessions.
function! claude#session#_holder_pid(id) abort
  return s:holder_pid(a:id)
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
        \ get(a:rec, 'origin', 'disk'),
        \ get(a:rec, 'named', 1),
        \ get(a:rec, 'workspace', ''))
  if has_key(a:rec, 'status')
    let l:full.status = a:rec.status
    let l:full.pinned = 1
  endif
  let l:full.snippet    = get(a:rec, 'snippet', '')
  let l:full.term_tail  = get(a:rec, 'term_tail', '')
  let l:full.last_focus = get(a:rec, 'last_focus', l:full.last_focus)
  let s:sessions[l:full.id] = l:full
  return l:full.id
endfunction
