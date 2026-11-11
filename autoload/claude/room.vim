" ── projects ─────────────────────────────────────────────────────────────────
"
" A project is a git worktree that sessions belong to: its own checkout, on a
" branch named after it, inside the repository at
" .vim-workspace/<project>/<repo>/, and diffed against a baseline branch. The
" repository's main checkout is a project too, with the reserved id 'root':
" materialised on every list, never stored, its branch read live. See
" doc/design/projects.md.
"
" Projects were called rooms, and rooms could hold sub-rooms. Sub-rooms are
" gone: a stored one is read as a top-level project of its own, keeping its id
" and its directory, so nothing on disk moves. The internal API keeps the
" claude#room# prefix so sessions and stores written by older builds still
" resolve.
"
" A record is:
"   id       'root' or '<project>' (a migrated sub-room keeps '<room>/<sub>')
"   name     display name
"   parent   always '' — kept so older stores and callers still read
"   branch   branch checked out in the worktree
"   base     the baseline: what the project diffs against and merges from;
"            '' = the repository's default branch
"   path     absolute worktree directory
"   project  main repository root, shared by every worktree of one repo
"   created  unix time
"   order    creation sequence within the repository, which breaks a tie
"            between two projects made in the same second
"   legacy   1 for a migrated workspace living outside .vim-workspace
"   missing  always 0 — kept for callers that still test it
"
" Records live in their own JSON store keyed by repository root. Which project
" is *selected* is deliberately not persisted: it is a property of this Vim
" session, like the diff tree's session-wide base.
"
" This module is git and bookkeeping only — no terminal, no panel rendering —
" so it can be tested against a fixture repository (test/room_*.vader).

" Room id selected with <leader>cw. Empty means the root checkout.
let s:current = ''

" directory -> main repository root. Git is never run twice for one directory.
let s:root_cache = {}

" project -> [time read, branch], for the root checkout's live branch. The
" panel asks on every redraw, and the answer only changes when the user
" switches branches, so it is re-read at most every few seconds.
let s:branch_cache = {}

" The room store as last read, and the file stamp it was read at.
let s:data  = {}
let s:stamp = ''

let s:warned = {}

" ── git ──────────────────────────────────────────────────────────────────────

function! s:git(dir, args) abort
  if empty(a:dir)
    return []
  endif
  let l:out = systemlist('git -C ' . shellescape(a:dir) . ' '
        \ . a:args . ' 2>/dev/null')
  return v:shell_error == 0 ? l:out : []
endfunction

" Run git in {dir} for its exit status alone.
function! s:git_ok(dir, args) abort
  call system('git -C ' . shellescape(a:dir) . ' ' . a:args . ' 2>/dev/null')
  return v:shell_error == 0
endfunction

" Run git in {dir} keeping stderr: [ok, message]. Used for the commands whose
" failure the user has to be told about verbatim.
"
" a:1 — 1 for a command that may reach the network. It must fail rather than
" wait on a credential prompt nobody can see, so prompting is switched off,
" and so is ssh's own unless the user configured an ssh command themselves.
function! s:git_run(dir, args, ...) abort
  let l:env = ''
  if a:0 > 0 && a:1
    let l:env = 'env GIT_TERMINAL_PROMPT=0 '
    if empty($GIT_SSH_COMMAND)
      let l:env .= 'GIT_SSH_COMMAND=' . shellescape('ssh -o BatchMode=yes') . ' '
    endif
  endif
  let l:out = system(l:env . 'git -C ' . shellescape(a:dir) . ' '
        \ . a:args . ' 2>&1')
  let l:msg = substitute(l:out, '\n\+$', '', '')
  let l:msg = substitute(l:msg, '\n', '; ', 'g')
  return [v:shell_error == 0, l:msg]
endfunction

function! s:ref_exists(root, ref) abort
  return s:git_ok(a:root, 'rev-parse --verify --quiet '
        \ . shellescape(a:ref . '^{commit}'))
endfunction

" Warnings here answer a key the user just pressed, so they are never
" suppressed the way the background warn-once messages are.
function! s:warn(msg) abort
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

function! s:warn_once(kind, msg) abort
  if has_key(s:warned, a:kind)
    return
  endif
  let s:warned[a:kind] = 1
  call s:warn(a:msg)
endfunction

" ── the repository ───────────────────────────────────────────────────────────

" The main repository root of the directory Vim is in — the checkout that owns
" .git as a real directory, which every linked worktree shares. '' outside a
" repository, and for a bare one, which has no worktree to hang a room off.
function! claude#room#project_root() abort
  return claude#room#project_of(getcwd())
endfunction

" The main repository root of {dir}. --git-common-dir is what collapses linked
" worktrees into one project; the derivation matches claude#session#group_of()
" so a room and the session spawned in it agree on which project they are in.
function! claude#room#project_of(dir) abort
  if !has_key(s:root_cache, a:dir)
    let s:root_cache[a:dir] = s:derive_root(a:dir)
  endif
  return s:root_cache[a:dir]
endfunction

function! s:derive_root(cwd) abort
  if empty(a:cwd) || !isdirectory(a:cwd) || !executable('git')
    return ''
  endif
  let l:out = s:git(a:cwd, 'rev-parse --path-format=absolute --git-common-dir')
  if empty(l:out)
    " Git < 2.31 has no --path-format; resolve the relative answer by hand.
    let l:rel = s:git(a:cwd, 'rev-parse --git-common-dir')
    if empty(l:rel)
      return ''
    endif
    let l:common = l:rel[0][0] ==# '/'
          \ ? l:rel[0] : simplify(a:cwd . '/' . l:rel[0])
  else
    let l:common = l:out[0]
  endif
  let l:root = substitute(l:common, '/\.git/\=$', '', '')
  " Nothing stripped: a bare repository.
  return l:root ==# l:common ? '' : l:root
endfunction

" What the repository calls its trunk, as {remote, branch}: the remote is
" origin, or the only remote when there is exactly one; the branch is what
" that remote's HEAD points at, else main, else master. Either may be ''.
"
" The diff tree's default base is this same answer, so a room and the diff
" tree never disagree about what "main" means.
function! claude#room#default_branch(root) abort
  let l:out = {'remote': '', 'branch': ''}
  if empty(a:root)
    return l:out
  endif
  let l:remotes = s:git(a:root, 'remote')
  if index(l:remotes, 'origin') >= 0
    let l:out.remote = 'origin'
  elseif len(l:remotes) == 1
    let l:out.remote = l:remotes[0]
  endif

  " origin/HEAD is looked for even with no origin configured: a clone whose
  " remote was removed still says what its trunk was.
  let l:named = empty(l:out.remote) ? 'origin' : l:out.remote
  let l:head  = s:git(a:root, 'symbolic-ref --short refs/remotes/'
        \ . l:named . '/HEAD')
  if !empty(l:head)
    let l:out.branch = substitute(l:head[0],
          \ '^' . escape(l:named, '\.*$^~[]') . '/', '', '')
    return l:out
  endif
  for l:cand in ['main', 'master']
    if s:ref_exists(a:root, l:cand) || (!empty(l:out.remote)
          \ && s:ref_exists(a:root, l:out.remote . '/' . l:cand))
      let l:out.branch = l:cand
      return l:out
    endif
  endfor
  return l:out
endfunction

" ── the store ────────────────────────────────────────────────────────────────

" The store, re-read only when the file changed under us. The panel asks for
" rooms on every redraw; parsing the JSON each time would be most of its cost.
function! s:load() abort
  let l:path = claude#store#room_path()
  if !filereadable(l:path)
    call s:migrate(l:path)
  endif
  let l:stamp = l:path . '|' . getftime(l:path) . '|' . getfsize(l:path)
  if l:stamp !=# s:stamp
    let s:data  = claude#store#load_at(l:path, 'rooms', 'room store')
    let s:stamp = l:stamp
  endif
  return deepcopy(s:data)
endfunction

function! s:save(data) abort
  let l:ok = claude#store#save_at(claude#store#room_path(), a:data,
        \ 'room store')
  let s:stamp = ''
  return l:ok
endfunction

" The first time the room store is missing, the workspace store it replaces
" is turned into one: every workspace becomes a top-level room where it
" already is. The workspace store itself is left alone, so going back to a
" build without rooms loses nothing.
function! s:migrate(path) abort
  let l:old = claude#store#workspace_path()
  if !filereadable(l:old)
    return
  endif
  let l:src   = claude#store#load_at(l:old, 'workspaces', 'workspace store')
  let l:rooms = {}
  for [l:proj, l:recs] in items(l:src.workspaces)
    if type(l:recs) != v:t_dict
      continue
    endif
    let l:rooms[l:proj] = {}
    for [l:id, l:rec] in items(l:recs)
      if type(l:rec) != v:t_dict
        continue
      endif
      let l:new = s:slug(l:id)
      let l:rooms[l:proj][l:new] = {
            \ 'id':      l:new,
            \ 'name':    get(l:rec, 'name', l:new),
            \ 'parent':  '',
            \ 'branch':  get(l:rec, 'branch', ''),
            \ 'base':    '',
            \ 'path':    get(l:rec, 'path', ''),
            \ 'project': l:proj,
            \ 'created': get(l:rec, 'created', 0),
            \ 'legacy':  1,
            \ }
    endfor
  endfor
  call claude#store#save_at(a:path, {'rooms': l:rooms}, 'room store')
endfunction

" A sub-room written by an older build is flattened into a project of its own:
" same id, same directory, named '<room>-<sub>' so it reads apart from its
" former room.
function! s:normalise(id, rec) abort
  let l:name   = get(a:rec, 'name', matchstr(a:id, '[^/]*$'))
  let l:parent = get(a:rec, 'parent', '')
  if !empty(l:parent) && l:name !~# '^' . escape(l:parent, '\.*$^~[]') . '-'
    let l:name = l:parent . '-' . l:name
  endif
  return {
        \ 'id':      a:id,
        \ 'name':    l:name,
        \ 'parent':  '',
        \ 'branch':  get(a:rec, 'branch', ''),
        \ 'base':    get(a:rec, 'base', ''),
        \ 'path':    get(a:rec, 'path', ''),
        \ 'project': get(a:rec, 'project', ''),
        \ 'created': get(a:rec, 'created', 0),
        \ 'order':   get(a:rec, 'order', 0),
        \ 'legacy':  get(a:rec, 'legacy', 0),
        \ 'missing': 0,
        \ }
endfunction

" What is written for a record: everything but the runtime-only fields.
function! s:stored(rec) abort
  let l:out = copy(a:rec)
  silent! call remove(l:out, 'missing')
  silent! call remove(l:out, 'root')
  return l:out
endfunction

function! s:put(rec) abort
  let l:data = s:load()
  if !has_key(l:data.rooms, a:rec.project)
    let l:data.rooms[a:rec.project] = {}
  endif
  let l:data.rooms[a:rec.project][a:rec.id] = s:stored(a:rec)
  return s:save(l:data)
endfunction

function! s:drop(rec) abort
  let l:data = s:load()
  if has_key(l:data.rooms, a:rec.project)
        \ && has_key(l:data.rooms[a:rec.project], a:rec.id)
    call remove(l:data.rooms[a:rec.project], a:rec.id)
    call s:save(l:data)
  endif
endfunction

" ── listing ──────────────────────────────────────────────────────────────────

" The root checkout of {project} (default: the one Vim is in) as a room.
function! claude#room#root(...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  if empty(l:root)
    return {}
  endif
  return {
        \ 'id':      'root',
        \ 'name':    fnamemodify(l:root, ':t'),
        \ 'parent':  '',
        \ 'branch':  s:live_branch(l:root),
        \ 'base':    '',
        \ 'path':    l:root,
        \ 'project': l:root,
        \ 'created': 0,
        \ 'legacy':  0,
        \ 'missing': 0,
        \ 'root':    1,
        \ }
endfunction

function! s:live_branch(root) abort
  let l:hit = get(s:branch_cache, a:root, [])
  if !empty(l:hit) && localtime() - l:hit[0] < 5
    return l:hit[1]
  endif
  let l:branch = ''
  if isdirectory(a:root)
    let l:out = s:git(a:root, 'rev-parse --abbrev-ref HEAD')
    let l:branch = empty(l:out) ? '' : (l:out[0] ==# 'HEAD'
          \ ? '(detached)' : l:out[0])
  endif
  let s:branch_cache[a:root] = [localtime(), l:branch]
  return l:branch
endfunction

function! s:cmp(a, b) abort
  if a:a.created != a:b.created
    return a:a.created - a:b.created
  endif
  if a:a.order != a:b.order
    return a:a.order - a:b.order
  endif
  return a:a.name ==# a:b.name ? 0 : (a:a.name < a:b.name ? -1 : 1)
endfunction

" Every project of {root} but the root checkout, oldest first, so a new
" project lands at the bottom of the list rather than reshuffling it.
"
" A project removed behind our back (`git worktree remove`, or an rm -rf)
" leaves a record pointing at nothing, so the list prunes those and writes the
" survivors back.
function! s:rooms(root) abort
  let l:data = s:load()
  let l:mine = get(l:data.rooms, a:root, {})
  let l:kept  = []
  let l:stale = 0
  for l:id in keys(l:mine)
    if type(l:mine[l:id]) != v:t_dict
      continue
    endif
    let l:rec = s:normalise(l:id, l:mine[l:id])
    if isdirectory(l:rec.path)
      call add(l:kept, l:rec)
    else
      let l:stale = 1
    endif
  endfor

  if l:stale
    let l:keep = {}
    for l:rec in l:kept
      let l:keep[l:rec.id] = s:stored(l:rec)
    endfor
    let l:data.rooms[a:root] = l:keep
    call s:save(l:data)
  endif
  return sort(l:kept, function('s:cmp'))
endfunction

" Every project of {repo} (default: the one Vim is in), the root checkout
" first.
function! claude#room#list(...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  if empty(l:root)
    return []
  endif
  let l:out = isdirectory(l:root) ? [claude#room#root(l:root)] : []
  return extend(l:out, s:rooms(l:root))
endfunction

" One room of {project}, or {} when it is unknown or gone.
function! claude#room#get(id, ...) abort
  if empty(a:id)
    return {}
  endif
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  if a:id ==# 'root'
    return isdirectory(l:root) ? claude#room#root(l:root) : {}
  endif
  if empty(l:root)
    return {}
  endif
  for l:rec in s:rooms(l:root)
    if l:rec.id ==# a:id
      return l:rec
    endif
  endfor
  return {}
endfunction

" Sub-rooms are gone; kept so older callers get the honest answer.
function! claude#room#children(id, ...) abort
  return []
endfunction

" The id of the room whose worktree is {path}, or ''.
function! claude#room#of_path(path, ...) abort
  if empty(a:path)
    return ''
  endif
  let l:root = a:0 > 0 && !empty(a:1) ? a:1
        \ : claude#room#project_of(a:path)
  let l:want = resolve(a:path)
  for l:rec in claude#room#list(l:root)
    if !l:rec.missing && resolve(l:rec.path) ==# l:want
      return l:rec.id
    endif
  endfor
  return ''
endfunction

" The base recorded for the room on {branch}, or '' when no room holds it or
" the room keeps the default. What the diff tree compares that branch against
" when the user has set no base of their own.
function! claude#room#base_of_branch(branch, ...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  if empty(a:branch) || empty(l:root)
    return ''
  endif
  for l:rec in s:rooms(l:root)
    if l:rec.branch ==# a:branch
      return l:rec.base
    endif
  endfor
  return ''
endfunction

" The room a session runs in, or {}.
function! claude#room#for_session(id) abort
  let l:rec = claude#session#get(a:id)
  return empty(l:rec) ? {}
        \ : claude#room#get(get(l:rec, 'room', ''), get(l:rec, 'project', ''))
endfunction

" How a project is named in the pickers and the panel.
"
"   root      claude.vim (root) — main
"   project   panel, or panel — feature/x when the branch is not the one the
"             project was given (panel, or room/panel for an older one)
"   gone      panel — (missing)
function! claude#room#label(rec) abort
  if empty(a:rec)
    return ''
  endif
  if get(a:rec, 'root', 0)
    return a:rec.name . ' (root)'
          \ . (empty(a:rec.branch) ? '' : ' — ' . a:rec.branch)
  endif
  if get(a:rec, 'missing', 0)
    return a:rec.name . ' — (missing)'
  endif
  if !empty(a:rec.branch) && a:rec.branch !=# s:branch_for(a:rec.name)
        \ && a:rec.branch !=# 'room/' . a:rec.name
    return a:rec.name . ' — ' . a:rec.branch
  endif
  return a:rec.name
endfunction

" ── naming and placement ─────────────────────────────────────────────────────

" A name that is safe as a directory and as part of a ref. Runs of dashes
" collapse to one: `--` is what joins a room to its sub-room in a branch name
" (room/<room>--<sub>), so a room called a--b could otherwise take the branch
" of room a's sub-room b.
function! s:slug(text) abort
  let l:s = substitute(a:text, '[^A-Za-z0-9._-]\+', '-', 'g')
  let l:s = substitute(l:s, '-\{2,}', '-', 'g')
  let l:s = substitute(l:s, '\.\{2,}', '.', 'g')
  let l:s = substitute(l:s, '\.lock$', '', '')
  return substitute(l:s, '^[-.]\+\|[-.]\+$', '', 'g')
endfunction

" Where rooms live, as configured: g:claude_room_dir, else the deprecated
" g:claude_workspace_dir, else .vim-workspace. A relative value is inside the
" project; an absolute one is outside it.
function! claude#room#dir() abort
  let l:dir = get(g:, 'claude_room_dir', '')
  if empty(l:dir)
    let l:old = get(g:, 'claude_workspace_dir', '')
    if !empty(l:old)
      call s:warn_once('workspace-dir', 'g:claude_workspace_dir is deprecated;'
            \ . ' set g:claude_room_dir instead')
      return l:old
    endif
    return '.vim-workspace'
  endif
  return l:dir
endfunction

function! s:is_absolute(dir) abort
  return a:dir =~# '^[/~$]'
endfunction

" The directory every room of {root} goes under.
function! s:base_dir(root) abort
  let l:dir = claude#room#dir()
  if s:is_absolute(l:dir)
    return substitute(expand(l:dir), '/\+$', '', '') . '/'
          \ . fnamemodify(a:root, ':t')
  endif
  return a:root . '/' . substitute(l:dir, '/\+$', '', '')
endfunction

" The worktree directory: <base>/<project>/<repo>. The worktree sits one level
" down so the checkout keeps the repository's own name, which is what tools
" that name things after their directory show.
function! s:dir_for(root, name) abort
  return s:base_dir(a:root) . '/' . a:name . '/' . fnamemodify(a:root, ':t')
endfunction

" A project's branch is named after it, behind g:claude_project_branch_prefix
" when one is set (e.g. 'feature/').
function! s:branch_for(name) abort
  return get(g:, 'claude_project_branch_prefix', '') . a:name
endfunction

function! s:taken(root, name) abort
  if a:name ==# 'root'
    return 1
  endif
  let l:data = s:load()
  if has_key(get(l:data.rooms, a:root, {}), a:name)
    return 1
  endif
  let l:dir = s:dir_for(a:root, a:name)
  if isdirectory(l:dir) || filereadable(l:dir)
    return 1
  endif
  " An existing branch is somebody's work: a new project takes a fresh name
  " rather than silently checking that out.
  return s:git_ok(a:root, 'show-ref --verify --quiet '
        \ . shellescape('refs/heads/' . s:branch_for(a:name)))
endfunction

" {base}, or base-1, base-2, … until no project, directory or branch holds it.
"
" a:1 is ignored (it was the parent room); a:2 the repository root.
function! claude#room#unique_name(base, ...) abort
  let l:root = a:0 > 1 && !empty(a:2) ? a:2 : claude#room#project_root()
  let l:base = s:slug(a:base)
  if empty(l:base)
    let l:base = 'project'
  endif
  if !s:taken(l:root, l:base)
    return l:base
  endif
  let l:n = 1
  while s:taken(l:root, l:base . '-' . l:n)
    let l:n += 1
  endwhile
  return l:base . '-' . l:n
endfunction

" Keep the room directory out of git status, ripgrep and friends by listing it
" in .git/info/exclude — local to this clone, never committed, so the
" project's own .gitignore is not touched. Nothing to do when rooms live
" outside the project.
function! claude#room#ensure_excluded(root) abort
  let l:dir = claude#room#dir()
  if s:is_absolute(l:dir)
    return
  endif
  let l:out = s:git(a:root, 'rev-parse --git-path info/exclude')
  if empty(l:out)
    return
  endif
  let l:path  = l:out[0][0] ==# '/' ? l:out[0] : a:root . '/' . l:out[0]
  let l:entry = '/' . substitute(l:dir, '^\./\|/\+$', '', 'g') . '/'
  let l:lines = filereadable(l:path) ? readfile(l:path) : []
  if index(l:lines, l:entry) >= 0
    return
  endif
  try
    call mkdir(fnamemodify(l:path, ':h'), 'p')
    call writefile(l:lines + [l:entry], l:path)
  catch
    call s:warn('could not add ' . l:entry . ' to ' . l:path
          \ . '; git status will list it')
  endtry
endfunction

" ── creating ─────────────────────────────────────────────────────────────────

" The ref a new room is cut from when no base is named: the default branch as
" the remote has it right now. Fetches first (g:claude_room_fetch), and falls
" back — with a warning naming the ref — to the last fetched remote branch,
" then to the local one. '' when there is nothing to cut from.
function! s:latest(root) abort
  let l:def = claude#room#default_branch(a:root)
  if empty(l:def.branch)
    return ''
  endif
  let l:failed = ''
  if !empty(l:def.remote)
    let l:ref = l:def.remote . '/' . l:def.branch
    if get(g:, 'claude_room_fetch', 1)
      let [l:ok, l:msg] = s:git_run(a:root, 'fetch --quiet '
            \ . shellescape(l:def.remote) . ' '
            \ . shellescape(l:def.branch), 1)
      if l:ok
        return l:ref
      endif
      let l:failed = 'git fetch failed (' . l:msg . '); '
    endif
    if s:ref_exists(a:root, 'refs/remotes/' . l:ref)
      if !empty(l:failed)
        call s:warn(l:failed . 'cutting the project from ' . l:ref
              \ . ' as last fetched')
      endif
      return l:ref
    endif
  endif
  if s:ref_exists(a:root, 'refs/heads/' . l:def.branch)
    if !empty(l:failed)
      call s:warn(l:failed . 'cutting the project from local ' . l:def.branch)
    endif
    return l:def.branch
  endif
  return ''
endfunction

" A new project named {name} with baseline {base}: a branch named after the
" project, cut from the baseline, checked out in a worktree of its own. A
" blank {base} means the default branch as the remote has it now (fetched
" first, see s:latest()) — origin/main on most repositories.
function! claude#room#create(name, base) abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    call s:warn('not inside a git repository; no project created')
    return {}
  endif

  let l:base = trim(a:base)
  if empty(l:base)
    let l:start = s:latest(l:root)
    if empty(l:start)
      call s:warn('no default branch found; name a baseline for the project')
      return {}
    endif
  else
    if !s:ref_exists(l:root, l:base)
      call s:warn('unknown baseline: ' . l:base . '; no project created')
      return {}
    endif
    let l:start = l:base
  endif

  let l:name = claude#room#unique_name(a:name, '', l:root)
  return s:add(l:root, l:name, l:start)
endfunction

function! s:add(root, name, start) abort
  let l:dir    = s:dir_for(a:root, a:name)
  let l:branch = s:branch_for(a:name)
  let l:holder = fnamemodify(l:dir, ':h')
  try
    call mkdir(l:holder, 'p')
  catch
    call s:warn('cannot create ' . l:holder . '; no project created')
    return {}
  endtry
  " Before the worktree exists, so git status never shows it even once.
  call claude#room#ensure_excluded(a:root)

  " --no-track: cut from a remote branch, the new branch would otherwise take
  " it as its upstream, and a `git push` would push to the baseline.
  let [l:ok, l:msg] = s:git_run(a:root, 'worktree add --no-track -b '
        \ . shellescape(l:branch) . ' ' . shellescape(l:dir) . ' '
        \ . shellescape(a:start))
  if !l:ok
    call delete(l:holder, 'd')
    call s:warn('git worktree add failed: ' . l:msg)
    return {}
  endif

  let l:rec = {
        \ 'id':      a:name,
        \ 'name':    a:name,
        \ 'parent':  '',
        \ 'branch':  l:branch,
        \ 'base':    a:start,
        \ 'path':    l:dir,
        \ 'project': a:root,
        \ 'created': localtime(),
        \ 'order':   s:next_order(a:root),
        \ 'legacy':  0,
        \ }
  call s:put(l:rec)
  return s:normalise(l:rec.id, l:rec)
endfunction

function! s:next_order(root) abort
  let l:max = 0
  for l:rec in values(get(s:load().rooms, a:root, {}))
    let l:max = max([l:max, get(l:rec, 'order', 0)])
  endfor
  return l:max + 1
endfunction

" Whether {rec}'s worktree has uncommitted changes.
function! claude#room#is_dirty(rec) abort
  return !empty(get(a:rec, 'path', '')) && isdirectory(a:rec.path)
        \ && !empty(s:git(a:rec.path, 'status --porcelain'))
endfunction

" ── removing ─────────────────────────────────────────────────────────────────

" Remove {id}'s worktree. The branch is kept: deleting a project never loses
" a commit.
function! s:remove(id, force) abort
  let l:rec = claude#room#get(a:id)
  if empty(l:rec) || get(l:rec, 'root', 0)
    return 0
  endif

  if isdirectory(l:rec.path)
    let l:args = 'worktree remove ' . (a:force ? '--force ' : '')
          \ . shellescape(l:rec.path)
    let [l:ok, l:msg] = s:git_run(l:rec.project, l:args)
    if !l:ok
      call s:warn('git worktree remove failed: ' . l:msg)
      return 0
    endif
  endif
  call s:drop(l:rec)

  " The directory holding the worktree, left empty now. delete(.., 'd') only
  " ever removes an empty directory, so nothing else in it is ever touched.
  if !l:rec.legacy
    call delete(fnamemodify(l:rec.path, ':h'), 'd')
  endif
  if s:current ==# l:rec.id
    let s:current = ''
  endif
  return 1
endfunction

" Remove {id}'s worktree with `git worktree remove`. Fails, leaving the
" record untouched, when the worktree has uncommitted changes or is locked.
function! claude#room#remove(id) abort
  return s:remove(a:id, 0)
endfunction

" Remove {id}'s worktree with `git worktree remove --force`, discarding any
" uncommitted changes.
function! claude#room#force_remove(id) abort
  return s:remove(a:id, 1)
endfunction

" ── baseline ─────────────────────────────────────────────────────────────────

function! s:remotes(root) abort
  return s:git(a:root, 'remote')
endfunction

" [remote, branch] when {ref} names a remote-tracking branch, else ['', ref].
function! s:split_remote(root, ref) abort
  for l:remote in s:remotes(a:root)
    if stridx(a:ref, l:remote . '/') == 0
      return [l:remote, a:ref[len(l:remote) + 1 :]]
    endif
  endfor
  return ['', a:ref]
endfunction

" {ref} without its remote: origin/main is main. Only a configured remote of
" {root} is stripped, so a local feature/x keeps its whole name.
function! claude#room#branch_name(root, ref) abort
  return s:split_remote(a:root, a:ref)[1]
endfunction

" What {rec}'s baseline is as the user set it: the project's own base, the
" diff tree's setting for the root checkout's branch, else the default branch
" — origin/main on most repositories.
function! s:base_setting(rec) abort
  let l:base = get(a:rec, 'root', 0)
        \ ? claude#difftree#base_for(a:rec.branch) : get(a:rec, 'base', '')
  if !empty(l:base)
    return l:base
  endif
  let l:def = claude#room#default_branch(a:rec.project)
  if empty(l:def.branch)
    return ''
  endif
  return empty(l:def.remote) ? l:def.branch : l:def.remote . '/' . l:def.branch
endfunction

" The ref {rec} diffs against and merges from. A baseline named by its local
" branch is read off the remote when the remote has it — the baseline is what
" the work will land on, and that is the remote's copy — and only falls back
" to the local branch when there is no remote one. '' when nothing resolves.
function! claude#room#baseline(rec) abort
  if empty(a:rec)
    return ''
  endif
  let l:base = s:base_setting(a:rec)
  if empty(l:base)
    return ''
  endif
  let l:root = a:rec.project
  let [l:remote, l:_] = s:split_remote(l:root, l:base)
  if empty(l:remote) && stridx(l:base, 'refs/') != 0
    let l:def = claude#room#default_branch(l:root)
    let l:name = empty(l:def.remote) ? 'origin' : l:def.remote
    if s:ref_exists(l:root, 'refs/remotes/' . l:name . '/' . l:base)
      return l:name . '/' . l:base
    endif
  endif
  return l:base
endfunction

" What {rec}'s local work is compared with: the branch's upstream when it has
" one, else the remote's branch of the same name. '' when the branch was never
" pushed.
function! claude#room#upstream(rec) abort
  if empty(a:rec) || empty(a:rec.branch) || a:rec.branch[0] ==# '('
    return ''
  endif
  let l:dir = isdirectory(a:rec.path) ? a:rec.path : a:rec.project
  let l:up = s:git(l:dir, 'rev-parse --abbrev-ref '
        \ . shellescape(a:rec.branch . '@{upstream}'))
  if !empty(l:up)
    return l:up[0]
  endif
  let l:def  = claude#room#default_branch(a:rec.project)
  let l:name = empty(l:def.remote) ? 'origin' : l:def.remote
  return s:ref_exists(l:dir, 'refs/remotes/' . l:name . '/' . a:rec.branch)
        \ ? l:name . '/' . a:rec.branch : ''
endfunction

" Make {base} {id}'s baseline. The root checkout keeps its baseline where the
" diff tree does, as that branch's base; a project keeps it on its record, and
" any diff-tree override on its branch is cleared so the two never disagree.
function! claude#room#set_base(id, base, ...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  let l:rec  = claude#room#get(a:id, l:root)
  if empty(l:rec)
    call s:warn('unknown project: ' . a:id)
    return 0
  endif
  let l:base = trim(a:base)
  if !empty(l:base) && !s:ref_exists(l:root, l:base)
    call s:warn('unknown baseline: ' . l:base . '; baseline unchanged')
    return 0
  endif
  if get(l:rec, 'root', 0)
    call claude#difftree#set_branch_base(l:rec.branch, l:base)
    return 1
  endif
  let l:rec.base = l:base
  call s:put(l:rec)
  if claude#difftree#has_own_base(l:rec.branch)
    call claude#difftree#set_branch_base(l:rec.branch, '')
  else
    call claude#difftree#refresh()
  endif
  return 1
endfunction

" u — bring {id} up to date with its baseline: fetch the baseline from its
" remote, then merge it into the project's branch. Refused on a worktree with
" uncommitted changes, which a merge could not be undone from cleanly. A merge
" that stops on conflicts is left in progress for the user to resolve.
" Returns 1 when the branch now contains the baseline.
function! claude#room#update(id, ...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  let l:rec  = claude#room#get(a:id, l:root)
  if empty(l:rec) || !isdirectory(l:rec.path)
    call s:warn('unknown project: ' . a:id)
    return 0
  endif
  let l:base = claude#room#baseline(l:rec)
  if empty(l:base)
    call s:warn(l:rec.name . ' has no baseline to update from')
    return 0
  endif
  if claude#room#is_dirty(l:rec)
    call s:warn(l:rec.name . ' has uncommitted changes; commit or stash them'
          \ . ' before updating from ' . l:base)
    return 0
  endif

  let [l:remote, l:branch] = s:split_remote(l:root, l:base)
  if !empty(l:remote)
    let [l:ok, l:msg] = s:git_run(l:rec.path, 'fetch --quiet '
          \ . shellescape(l:remote) . ' ' . shellescape(l:branch), 1)
    if !l:ok
      call s:warn('git fetch failed (' . l:msg . '); merging ' . l:base
            \ . ' as last fetched')
    endif
  endif

  let [l:ok, l:msg] = s:git_run(l:rec.path, 'merge --no-edit '
        \ . shellescape(l:base))
  call claude#difftree#refresh()
  if l:ok
    echomsg 'claude.vim: ' . l:rec.name . ' is up to date with ' . l:base
    return 1
  endif
  let l:conflicts = s:git(l:rec.path, 'diff --name-only --diff-filter=U')
  if empty(l:conflicts)
    call s:warn('git merge ' . l:base . ' failed: ' . l:msg)
  else
    call s:warn('merging ' . l:base . ' into ' . l:rec.name . ' stopped on '
          \ . len(l:conflicts) . ' conflicted file'
          \ . (len(l:conflicts) == 1 ? '' : 's') . '; resolve them and commit')
  endif
  return 0
endfunction

" ── the selected room ────────────────────────────────────────────────────────

" The room new sessions run in when nothing else says where: the selected one,
" else the root checkout. {} outside a repository.
function! claude#room#current() abort
  if !empty(s:current)
    let l:rec = claude#room#get(s:current)
    if !empty(l:rec) && !l:rec.missing
      return l:rec
    endif
  endif
  return claude#room#root()
endfunction

" Select {id} ('' or 'root' for the root checkout). Returns 1 when it took
" effect.
function! claude#room#set_current(id) abort
  if empty(a:id) || a:id ==# 'root'
    let s:current = ''
    return 1
  endif
  let l:rec = claude#room#get(a:id)
  if empty(l:rec) || l:rec.missing
    return 0
  endif
  let s:current = a:id
  return 1
endfunction

" The directory a session with nowhere else to go is spawned in.
function! claude#room#cwd() abort
  let l:rec = claude#room#current()
  return empty(l:rec) || !isdirectory(l:rec.path) ? getcwd() : l:rec.path
endfunction

" ── asking where a new session goes ──────────────────────────────────────────

function! s:input(prompt, ...) abort
  try
    let l:answer = a:0 > 0 ? input(a:prompt, '', a:1) : input(a:prompt)
  catch /^Vim:Interrupt$/
    return [0, '']
  endtry
  redraw
  return [1, trim(l:answer)]
endfunction

function! s:inputlist(menu) abort
  try
    let l:choice = inputlist(a:menu)
  catch /^Vim:Interrupt$/
    return [0, 0]
  endtry
  redraw
  return [1, l:choice]
endfunction

" Which project a new session goes in, asked as one menu. Returns [1, answer]
" or [0, {}] when the user pressed CTRL-C. The answer is one of
"
"   {'room': id}                          an existing project ('' outside git)
"   {'new': 'room', 'name': n, 'base': b} a project to create
"
" Nothing is created here: the caller creates the project only once every
" question has been answered, so cancelling a later one leaves nothing behind.
"
" inputlist() rather than a popup, because the questions after this one are
" input() prompts and a popup would hand the rest of the chain to a callback.
" Only CTRL-C cancels; a blank answer keeps the selected project, the cheap
" path for the common case of another session in the same place.
function! claude#room#ask() abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    return [1, {'room': ''}]
  endif
  let l:cur = get(claude#room#current(), 'id', 'root')

  let l:items   = []
  let l:answers = []
  for l:rec in claude#room#list(l:root)
    call add(l:items, (l:rec.id ==# l:cur ? '* ' : '  ')
          \ . claude#room#label(l:rec) . (l:rec.legacy ? '  (legacy)' : ''))
    call add(l:answers, {'room': l:rec.id})
  endfor
  call add(l:items, '  + New project…')
  call add(l:answers, {'new': 'room'})

  let l:menu = ['Project for the new session (blank keeps *):']
  let l:i = 1
  for l:item in l:items
    call add(l:menu, printf('%d. %s', l:i, l:item))
    let l:i += 1
  endfor
  let [l:ok, l:choice] = s:inputlist(l:menu)
  if !l:ok
    return [0, {}]
  endif
  if l:choice < 1 || l:choice > len(l:answers)
    return [1, {'room': l:cur}]
  endif

  let l:pick = l:answers[l:choice - 1]
  return has_key(l:pick, 'room') ? [1, l:pick] : claude#room#ask_new()
endfunction

" The two questions a new project needs: its name, and its baseline — with
" branch completion, blank for the default branch as the remote has it.
" Returns [1, {'new': 'room', 'name': n, 'base': b}] or [0, {}].
function! claude#room#ask_new() abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    call s:warn('not inside a git repository')
    return [0, {}]
  endif
  let [l:ok, l:name] = s:input('Project name: ')
  if !l:ok
    return [0, {}]
  endif
  if empty(s:slug(l:name))
    call s:warn('a project needs a name; nothing created')
    return [0, {}]
  endif
  let l:def = claude#room#default_branch(l:root)
  let l:shown = empty(l:def.branch) ? 'default'
        \ : (empty(l:def.remote) ? '' : l:def.remote . '/') . l:def.branch
  let [l:ok, l:base] = s:input('Baseline (blank for ' . l:shown . '): ',
        \ 'customlist,claude#difftree#complete_branch')
  if !l:ok
    return [0, {}]
  endif
  if empty(l:base) && empty(l:def.branch)
    call s:warn('no default branch found; name a baseline for the project')
    return [0, {}]
  endif
  if !empty(l:base) && !s:ref_exists(l:root, l:base)
    call s:warn('unknown baseline: ' . l:base . '; nothing created')
    return [0, {}]
  endif
  return [1, {'new': 'room', 'name': l:name, 'base': l:base}]
endfunction

" The project an answer from claude#room#ask() means, creating it when the
" answer asked for a new one. {} when there is none — outside a repository, or
" after a creation failure that has already been reported.
function! claude#room#realise(answer) abort
  if has_key(a:answer, 'room')
    return claude#room#get(a:answer.room)
  endif
  if get(a:answer, 'new', '') ==# 'room'
    return claude#room#create(a:answer.name, get(a:answer, 'base', ''))
  endif
  return {}
endfunction

" The answer a `project:` prefix on :ClaudeNew/:PiNew stands for, in the shape
" claude#room#ask() returns, so claude#room#realise() takes it from there.
" `root` is the root checkout; a project that exists is used as it is; a name
" that does not is a new project with the default baseline. {} when the text
" names nothing that can be made.
function! claude#room#answer_for(text) abort
  let l:text = trim(a:text)
  " A migrated sub-room keeps its '<room>/<sub>' id, and is still found by it.
  let l:id = join(map(split(l:text, '/', 1), {_, p -> s:slug(p)}), '/')
  if l:id ==# 'root' || !empty(claude#room#get(l:id))
    return {'room': l:id}
  endif
  if !empty(s:slug(l:text)) && l:text !~# '/'
    return {'new': 'room', 'name': l:text, 'base': ''}
  endif
  call s:warn('no project to make from "' . l:text . '"')
  return {}
endfunction

" ── the picker ───────────────────────────────────────────────────────────────

" g:claude_no_popup forces the inputlist() path, as it does for the session
" picker.
function! s:use_popup() abort
  return has('popupwin') && !get(g:, 'claude_no_popup', 0)
endfunction

" :ClaudeProjects — choose the project to work in. Selecting one re-roots NERDTree
" onto it, so the file tree shows that checkout and nothing else.
function! claude#room#pick() abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    call s:warn('not inside a git repository')
    return
  endif

  let l:cur   = get(claude#room#current(), 'id', 'root')
  let l:ids   = []
  let l:items = []
  for l:rec in claude#room#list(l:root)
    call add(l:ids, l:rec.id)
    call add(l:items, (l:rec.id ==# l:cur ? '* ' : '  ')
          \ . claude#room#label(l:rec))
  endfor

  if s:use_popup()
    call popup_menu(l:items, {
          \ 'title':    ' Projects ',
          \ 'callback': {_, idx -> s:picked(l:ids, idx)},
          \ 'filter':   'popup_filter_menu',
          \ 'padding':  [0, 1, 0, 1],
          \ 'border':   [],
          \ })
    return
  endif

  let l:menu = ['Project:']
  let l:i = 1
  for l:item in l:items
    call add(l:menu, printf('%d. %s', l:i, l:item))
    let l:i += 1
  endfor
  call s:picked(l:ids, inputlist(l:menu))
endfunction

" popup_menu() reports a 1-based index, or -1/0 when dismissed.
function! s:picked(ids, idx) abort
  redraw
  if a:idx < 1 || a:idx > len(a:ids)
    return
  endif
  call claude#room#select(a:ids[a:idx - 1])
endfunction

" Make {id} the current room and point NERDTree at it. '' or 'root' selects
" the root checkout again.
function! claude#room#select(id) abort
  if !claude#room#set_current(a:id)
    call s:warn('unknown project: ' . a:id)
    return
  endif
  let l:rec = claude#room#current()
  call s:reroot(empty(l:rec) ? '' : l:rec.path)
endfunction

" Re-root NERDTree onto {dir} without disturbing the sidebar column or the
" window the user was in.
function! s:reroot(dir) abort
  if !claude#sidebar#nerdtree_available()
    call s:warn('NERDTree is not installed; project selected anyway')
    return
  endif
  if empty(a:dir) || !isdirectory(a:dir)
    return
  endif
  let l:cur = win_getid()
  try
    execute 'NERDTree ' . fnameescape(a:dir)
  catch
    call s:warn('could not re-root NERDTree: ' . v:exception)
  finally
    call claude#sidebar#stack()
    if win_id2win(l:cur) > 0 && win_getid() != l:cur
      call win_gotoid(l:cur)
    endif
    " Re-root the tab too, so :Git and friends see this room's repo instead
    " of whatever the tab happened to be in before.
    execute 'tcd ' . fnameescape(a:dir)
  endtry
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

function! claude#room#_reset() abort
  let s:current      = ''
  let s:root_cache   = {}
  let s:branch_cache = {}
  let s:data         = {}
  let s:stamp        = ''
  let s:warned       = {}
endfunction
