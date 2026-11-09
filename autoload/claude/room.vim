" ── rooms ────────────────────────────────────────────────────────────────────
"
" A room is a git worktree that sessions belong to: its own checkout, on its
" own branch, inside the project at .vim-workspace/<room>/<project>/. A room
" may hold sub-rooms, each a worktree of its own cut from the room's branch,
" at .vim-workspace/<room>/<sub>/<project>/. The project's main checkout is a
" room too, with the reserved id 'root': materialised on every list, never
" stored, its branch read live. See doc/design/rooms.md.
"
" A record is:
"   id       'root', '<room>' or '<room>/<sub>' — unique per project
"   name     display name: the last segment of the id
"   parent   '' for a room, the room's id for a sub-room
"   branch   branch checked out in the worktree
"   base     what the diff tree compares the branch against; '' = the default
"   path     absolute worktree directory
"   project  main repository root, shared by every worktree of one repo
"   created  unix time
"   order    creation sequence within the project, which breaks a tie
"            between two rooms made in the same second
"   legacy   1 for a migrated workspace living outside .vim-workspace
"   missing  1 (never stored) for a room whose directory is gone but whose
"            sub-rooms are still there
"
" Records live in their own JSON store keyed by repository root. Which room is
" *selected* is deliberately not persisted: it is a property of this Vim
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

function! s:normalise(id, rec) abort
  return {
        \ 'id':      a:id,
        \ 'name':    get(a:rec, 'name', matchstr(a:id, '[^/]*$')),
        \ 'parent':  get(a:rec, 'parent', ''),
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

" Every room of {root} but the root checkout: each room followed by its
" sub-rooms, oldest first, so a new room lands at the bottom of the list
" rather than reshuffling it.
"
" A room removed behind our back (`git worktree remove`, or an rm -rf) leaves
" a record pointing at nothing, so the list prunes those and writes the
" survivors back. The one exception is a room whose sub-rooms are still there:
" it is kept, marked missing, so they still have a parent to be listed under.
function! s:rooms(root) abort
  let l:data = s:load()
  let l:mine = get(l:data.rooms, a:root, {})
  let l:recs = []
  for l:id in keys(l:mine)
    if type(l:mine[l:id]) == v:t_dict
      call add(l:recs, s:normalise(l:id, l:mine[l:id]))
    endif
  endfor

  let l:alive = {}
  for l:rec in l:recs
    if isdirectory(l:rec.path)
      let l:alive[l:rec.id] = 1
    endif
  endfor

  let l:kept  = []
  let l:stale = 0
  for l:rec in l:recs
    if has_key(l:alive, l:rec.id)
      call add(l:kept, l:rec)
    elseif empty(l:rec.parent) && !empty(filter(copy(l:recs),
          \ {_, r -> r.parent ==# l:rec.id && has_key(l:alive, r.id)}))
      let l:rec.missing = 1
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

  let l:tops = sort(filter(copy(l:kept), {_, r -> empty(r.parent)}),
        \ function('s:cmp'))
  let l:ids  = {}
  for l:top in l:tops
    let l:ids[l:top.id] = 1
  endfor
  " A sub-room whose room record was deleted outright still needs a parent row.
  for l:sub in l:kept
    if !empty(l:sub.parent) && !has_key(l:ids, l:sub.parent)
      let l:ids[l:sub.parent] = 1
      call add(l:tops, extend(s:normalise(l:sub.parent, {'project': a:root}),
            \ {'missing': 1}))
    endif
  endfor

  let l:out = []
  for l:top in l:tops
    call add(l:out, l:top)
    call extend(l:out, sort(filter(copy(l:kept),
          \ {_, r -> r.parent ==# l:top.id}), function('s:cmp')))
  endfor
  return l:out
endfunction

" Every room of {project} (default: the one Vim is in): the root checkout
" first, then each room followed by its sub-rooms.
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

" A room's sub-rooms.
function! claude#room#children(id, ...) abort
  let l:root = a:0 > 0 && !empty(a:1) ? a:1 : claude#room#project_root()
  if empty(l:root) || empty(a:id) || a:id ==# 'root'
    return []
  endif
  return filter(s:rooms(l:root), {_, r -> r.parent ==# a:id})
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

" How a room is named in the pickers and the panel.
"
"   root      claude.vim (root) — main
"   room      panel, or panel — feature/x when the branch is not room/panel
"   sub-room  icons
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
  if empty(a:rec.parent) && !empty(a:rec.branch)
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

" The worktree directory: <base>/<room>/<project> or <base>/<room>/<sub>/<project>.
" The worktree sits one level down so a room's sub-rooms are its siblings, not
" untracked directories inside its checkout.
function! s:dir_for(root, parent, name) abort
  return s:base_dir(a:root) . '/'
        \ . (empty(a:parent) ? a:name : a:parent . '/' . a:name)
        \ . '/' . fnamemodify(a:root, ':t')
endfunction

" room/<room> or room/<room>--<sub>. Not room/<room>/<sub>: git cannot hold
" both refs/heads/room/a and refs/heads/room/a/b, a ref being a file.
function! s:branch_for(parent, name) abort
  return 'room/' . (empty(a:parent) ? a:name : a:parent . '--' . a:name)
endfunction

function! s:taken(root, parent, name) abort
  if empty(a:parent) && a:name ==# 'root'
    return 1
  endif
  let l:id = empty(a:parent) ? a:name : a:parent . '/' . a:name
  let l:data = s:load()
  if has_key(get(l:data.rooms, a:root, {}), l:id)
    return 1
  endif
  let l:dir = s:dir_for(a:root, a:parent, a:name)
  if isdirectory(l:dir) || filereadable(l:dir)
    return 1
  endif
  " A leftover branch from a removed room is somebody's earlier work: a new
  " room takes a fresh name rather than silently checking that out.
  return s:git_ok(a:root, 'show-ref --verify --quiet '
        \ . shellescape('refs/heads/' . s:branch_for(a:parent, a:name)))
endfunction

" {base}, or base-1, base-2, … until no room, directory or branch holds it.
"
" a:1 parent room id ('' for a room), a:2 project root.
function! claude#room#unique_name(base, ...) abort
  let l:parent = a:0 > 0 ? a:1 : ''
  let l:root   = a:0 > 1 && !empty(a:2) ? a:2 : claude#room#project_root()
  let l:base   = s:slug(a:base)
  if empty(l:base)
    let l:base = empty(l:parent) ? 'room' : 'sub'
  endif
  if !s:taken(l:root, l:parent, l:base)
    return l:base
  endif
  let l:n = 1
  while s:taken(l:root, l:parent, l:base . '-' . l:n)
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
        call s:warn(l:failed . 'cutting the room from ' . l:ref
              \ . ' as last fetched')
      endif
      return l:ref
    endif
  endif
  if s:ref_exists(a:root, 'refs/heads/' . l:def.branch)
    if !empty(l:failed)
      call s:warn(l:failed . 'cutting the room from local ' . l:def.branch)
    endif
    return l:def.branch
  endif
  return ''
endfunction

" A new room named {name}, cut from {base} — or, when {base} is blank, from the
" latest default branch. The room diffs against what it was cut from. Returns
" the record, or {} when nothing was created; every failure is reported to the
" user and none is fatal to the caller.
function! claude#room#create(name, base) abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    call s:warn('not inside a git repository; no room created')
    return {}
  endif

  let l:base = trim(a:base)
  if empty(l:base)
    let l:start = s:latest(l:root)
    if empty(l:start)
      call s:warn('no default branch found; name a base branch for the room')
      return {}
    endif
  else
    if !s:ref_exists(l:root, l:base)
      call s:warn('unknown base branch: ' . l:base . '; no room created')
      return {}
    endif
    let l:start = l:base
  endif

  let l:name = claude#room#unique_name(a:name, '', l:root)
  return s:add(l:root, '', l:name, l:start)
endfunction

" A new sub-room of room {parent}, named {name}, cut from the room's branch
" tip and diffing against that branch. Uncommitted work in the room is not
" carried over: a worktree is a checkout of a commit.
function! claude#room#create_sub(parent, name) abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    call s:warn('not inside a git repository; no sub-room created')
    return {}
  endif
  let l:room = claude#room#get(a:parent, l:root)
  if empty(l:room) || get(l:room, 'root', 0) || !empty(l:room.parent)
        \ || l:room.missing
    call s:warn('sub-rooms belong to a room, and ' . a:parent
          \ . ' is not one; no sub-room created')
    return {}
  endif
  let l:name = claude#room#unique_name(a:name, l:room.id, l:root)
  return s:add(l:root, l:room.id, l:name, l:room.branch)
endfunction

function! s:add(root, parent, name, start) abort
  let l:dir    = s:dir_for(a:root, a:parent, a:name)
  let l:branch = s:branch_for(a:parent, a:name)
  let l:holder = fnamemodify(l:dir, ':h')
  try
    call mkdir(l:holder, 'p')
  catch
    call s:warn('cannot create ' . l:holder . '; no room created')
    return {}
  endtry
  " Before the worktree exists, so git status never shows it even once.
  call claude#room#ensure_excluded(a:root)

  " --no-track: cut from a remote branch, the new branch would otherwise take
  " it as its upstream, and a `git pull` in the room would pull main into it.
  let [l:ok, l:msg] = s:git_run(a:root, 'worktree add --no-track -b '
        \ . shellescape(l:branch) . ' ' . shellescape(l:dir) . ' '
        \ . shellescape(a:start))
  if !l:ok
    call delete(l:holder, 'd')
    call s:warn('git worktree add failed: ' . l:msg)
    return {}
  endif

  let l:rec = {
        \ 'id':      empty(a:parent) ? a:name : a:parent . '/' . a:name,
        \ 'name':    a:name,
        \ 'parent':  a:parent,
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

" Remove {id}'s worktree. The branch is kept: removing a room never loses a
" commit. A room with sub-rooms is refused rather than removed with them, so
" one key never discards several agents' uncommitted work.
function! s:remove(id, force) abort
  let l:rec = claude#room#get(a:id)
  if empty(l:rec) || get(l:rec, 'root', 0)
    return 0
  endif
  let l:subs = claude#room#children(l:rec.id)
  if !empty(l:subs)
    call s:warn(l:rec.name . ' has ' . len(l:subs) . ' sub-room'
          \ . (len(l:subs) == 1 ? '' : 's') . '; remove them first')
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
  " ever removes an empty directory, so a sub-room's sibling is never touched.
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

" Which room a new session goes in, asked as one menu. Returns [1, answer] or
" [0, {}] when the user pressed CTRL-C. The answer is one of
"
"   {'room': id}                          an existing room ('' outside git)
"   {'new': 'room', 'name': n, 'base': b} a room to create
"   {'new': 'sub', 'parent': id, 'name': n}
"
" Nothing is created here: the caller creates the room only once every
" question has been answered, so cancelling a later one leaves nothing behind.
"
" inputlist() rather than a popup, because the questions after this one are
" input() prompts and a popup would hand the rest of the chain to a callback.
" Only CTRL-C cancels; a blank answer keeps the selected room, the cheap path
" for the common case of another session in the same place.
function! claude#room#ask() abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    return [1, {'room': ''}]
  endif
  let l:cur = get(claude#room#current(), 'id', 'root')

  let l:items   = []
  let l:answers = []
  let l:has_rooms = 0
  for l:rec in claude#room#list(l:root)
    if l:rec.missing
      continue
    endif
    if !get(l:rec, 'root', 0) && empty(l:rec.parent)
      let l:has_rooms = 1
    endif
    call add(l:items, (l:rec.id ==# l:cur ? '* ' : '  ')
          \ . (empty(l:rec.parent) ? '' : '  ') . claude#room#label(l:rec)
          \ . (l:rec.legacy ? '  (legacy)' : ''))
    call add(l:answers, {'room': l:rec.id})
  endfor
  call add(l:items, '  + New room…')
  call add(l:answers, {'new': 'room'})
  if l:has_rooms
    call add(l:items, '  + New sub-room…')
    call add(l:answers, {'new': 'sub'})
  endif

  let l:menu = ['Room for the new session (blank keeps *):']
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
  if has_key(l:pick, 'room')
    return [1, l:pick]
  endif
  return l:pick.new ==# 'room' ? s:ask_room(l:root) : s:ask_sub(l:root, l:cur)
endfunction

function! s:ask_room(root) abort
  let [l:ok, l:name] = s:input('Room name: ')
  if !l:ok
    return [0, {}]
  endif
  if empty(s:slug(l:name))
    call s:warn('a room needs a name; nothing created')
    return [0, {}]
  endif
  let l:def = claude#room#default_branch(a:root).branch
  let [l:ok, l:base] = s:input('Base branch (blank for latest '
        \ . (empty(l:def) ? 'default' : l:def) . '): ',
        \ 'customlist,claude#difftree#complete_branch')
  if !l:ok
    return [0, {}]
  endif
  if empty(l:base) && empty(l:def)
    call s:warn('no default branch found; name a base branch for the room')
    return [0, {}]
  endif
  if !empty(l:base) && !s:ref_exists(a:root, l:base)
    call s:warn('unknown base branch: ' . l:base . '; nothing created')
    return [0, {}]
  endif
  return [1, {'new': 'room', 'name': l:name, 'base': l:base}]
endfunction

" The parent is the selected room — or the room the selected sub-room is in —
" and is only asked for when nothing is selected.
function! s:ask_sub(root, cur) abort
  let l:parent = matchstr(a:cur, '^[^/]*')
  if l:parent ==# 'root' || empty(claude#room#get(l:parent, a:root))
    let l:tops = filter(claude#room#list(a:root), {_, r ->
          \ !get(r, 'root', 0) && empty(r.parent) && !r.missing})
    let l:menu = ['Sub-room of which room?']
    let l:i = 1
    for l:rec in l:tops
      call add(l:menu, printf('%d. %s', l:i, claude#room#label(l:rec)))
      let l:i += 1
    endfor
    let [l:ok, l:choice] = s:inputlist(l:menu)
    if !l:ok || l:choice < 1 || l:choice > len(l:tops)
      return [0, {}]
    endif
    let l:parent = l:tops[l:choice - 1].id
  endif

  let l:room = claude#room#get(l:parent, a:root)
  if claude#room#is_dirty(l:room)
    call s:warn(l:room.branch . ' has uncommitted changes;'
          \ . ' the sub-room starts from its last commit')
  endif
  let [l:ok, l:name] = s:input('Sub-room name (in ' . l:room.name . '): ')
  if !l:ok
    return [0, {}]
  endif
  if empty(s:slug(l:name))
    call s:warn('a sub-room needs a name; nothing created')
    return [0, {}]
  endif
  return [1, {'new': 'sub', 'parent': l:parent, 'name': l:name}]
endfunction

" The room an answer from claude#room#ask() means, creating it when the answer
" asked for a new one. {} when there is none — outside a repository, or after
" a creation failure that has already been reported.
function! claude#room#realise(answer) abort
  if has_key(a:answer, 'room')
    return claude#room#get(a:answer.room)
  endif
  if get(a:answer, 'new', '') ==# 'room'
    return claude#room#create(a:answer.name, get(a:answer, 'base', ''))
  endif
  if get(a:answer, 'new', '') ==# 'sub'
    return claude#room#create_sub(a:answer.parent, a:answer.name)
  endif
  return {}
endfunction

" The answer a `room:` prefix on :ClaudeNew/:PiNew stands for, in the shape
" claude#room#ask() returns, so claude#room#realise() takes it from there.
" `root` is the root checkout; a room or sub-room that exists is used as it
" is; `name` that does not is a new room cut from the default branch, and
" `room/name` a new sub-room of a room that does exist. {} when the text
" names nothing that can be made — a sub-room of an unknown room, or a name
" with nothing left after slugging.
function! claude#room#answer_for(text) abort
  let l:text = trim(a:text)
  let l:id   = join(map(split(l:text, '/', 1), {_, p -> s:slug(p)}), '/')
  if l:id ==# 'root' || !empty(claude#room#get(l:id))
    return {'room': l:id}
  endif
  let l:parts = split(l:id, '/', 1)
  if len(l:parts) == 1 && !empty(l:parts[0])
    return {'new': 'room', 'name': l:text, 'base': ''}
  endif
  if len(l:parts) == 2 && !empty(l:parts[1])
    let l:parent = claude#room#get(l:parts[0])
    if !empty(l:parent) && empty(l:parent.parent) && !get(l:parent, 'root', 0)
      return {'new': 'sub', 'parent': l:parent.id,
            \ 'name': split(l:text, '/', 1)[1]}
    endif
  endif
  call s:warn('no room to make from "' . l:text . '"'
        \ . (len(l:parts) == 2 ? ': ' . l:parts[0] . ' is not a room' : ''))
  return {}
endfunction

" ── the picker ───────────────────────────────────────────────────────────────

" g:claude_no_popup forces the inputlist() path, as it does for the session
" picker.
function! s:use_popup() abort
  return has('popupwin') && !get(g:, 'claude_no_popup', 0)
endfunction

" :ClaudeRooms — choose the room to work in. Selecting one re-roots NERDTree
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
    if l:rec.missing
      continue
    endif
    call add(l:ids, l:rec.id)
    call add(l:items, (l:rec.id ==# l:cur ? '* ' : '  ')
          \ . (empty(l:rec.parent) ? '' : '  ') . claude#room#label(l:rec))
  endfor

  if s:use_popup()
    call popup_menu(l:items, {
          \ 'title':    ' Rooms ',
          \ 'callback': {_, idx -> s:picked(l:ids, idx)},
          \ 'filter':   'popup_filter_menu',
          \ 'padding':  [0, 1, 0, 1],
          \ 'border':   [],
          \ })
    return
  endif

  let l:menu = ['Room:']
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
    call s:warn('unknown room: ' . a:id)
    return
  endif
  let l:rec = claude#room#current()
  call s:reroot(empty(l:rec) ? '' : l:rec.path)
endfunction

" Re-root NERDTree onto {dir} without disturbing the sidebar column or the
" window the user was in.
function! s:reroot(dir) abort
  if !claude#sidebar#nerdtree_available()
    call s:warn('NERDTree is not installed; room selected anyway')
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
