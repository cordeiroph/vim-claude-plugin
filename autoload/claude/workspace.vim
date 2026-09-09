" ── git worktree workspaces ──────────────────────────────────────────────────
"
" A workspace is a git worktree that a Claude session owns: its own checkout
" of one branch, so two sessions can work on two branches at once without
" fighting over a single directory.
"
" A record is:
"   id       key within the repository (the name; unique per project)
"   name     display name
"   branch   branch checked out in the worktree
"   path     absolute worktree directory
"   project  main repository root, shared by every worktree of one repo
"   created  unix time
"
" Records live in their own JSON store keyed by repository root, exactly as
" the per-branch diff bases do, so the same workspace name in two repositories
" stays separate. Which workspace is *selected* is deliberately not persisted:
" it is a property of this Vim session, like the diff tree's session-wide base.
"
" This module is git and bookkeeping only — no terminal, no panel rendering —
" so it can be tested against a fixture repository (test/workspace_*.vader).

" Workspace id selected with <leader>cw. Empty means the main checkout.
let s:current = ''

" cwd -> main repository root. Git is never run twice for one directory.
let s:root_cache = {}

" ── git ──────────────────────────────────────────────────────────────────────

" Run git in {dir}, returning its lines, or [] when the command failed.
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

" Run git in {dir} keeping stderr: [ok, message]. Used for the one command
" whose failure the user has to be told about verbatim.
function! s:git_run(dir, args) abort
  let l:out = system('git -C ' . shellescape(a:dir) . ' ' . a:args . ' 2>&1')
  let l:msg = substitute(l:out, '\n\+$', '', '')
  let l:msg = substitute(l:msg, '\n', '; ', 'g')
  return [v:shell_error == 0, l:msg]
endfunction

" Warnings here answer a key the user just pressed, so they are never
" suppressed the way the background warn-once messages are.
function! s:warn(msg) abort
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" ── the repository ───────────────────────────────────────────────────────────

" The main repository root — the checkout that owns .git as a real directory,
" which every linked worktree shares. '' outside a repository, and for a bare
" one, which has no worktree to hang a workspace off.
"
" --git-common-dir is what collapses linked worktrees into one project; the
" derivation matches claude#session#group_of() so a workspace and the session
" spawned in it agree on which project they belong to.
function! claude#workspace#project_root() abort
  let l:cwd = getcwd()
  if !has_key(s:root_cache, l:cwd)
    let s:root_cache[l:cwd] = s:derive_root(l:cwd)
  endif
  return s:root_cache[l:cwd]
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

" Worktrees of {root}, from the porcelain format — plain `git worktree list`
" output is not meant to be machine-read.
function! s:worktrees(root) abort
  let l:out  = []
  let l:path = ''
  for l:line in s:git(a:root, 'worktree list --porcelain')
    if l:line =~# '^worktree '
      let l:path = l:line[9:]
    elseif l:line =~# '^branch '
      call add(l:out, {'path': l:path,
            \ 'branch': substitute(l:line[7:], '^refs/heads/', '', '')})
    endif
  endfor
  return l:out
endfunction

" Where {branch} is already checked out, or '' when it is free. Git allows a
" branch in one worktree only, so this is the check that turns an unhelpful
" `git worktree add` error into a sentence.
function! s:checkout_of(root, branch) abort
  for l:wt in s:worktrees(a:root)
    if l:wt.branch ==# a:branch
      return l:wt.path
    endif
  endfor
  return ''
endfunction

" ── the store ────────────────────────────────────────────────────────────────

function! s:load() abort
  return claude#store#load_at(claude#store#workspace_path(),
        \ 'workspaces', 'workspace store')
endfunction

function! s:save(data) abort
  return claude#store#save_at(claude#store#workspace_path(),
        \ a:data, 'workspace store')
endfunction

" Fill in the fields a record written by an older build may not have.
function! s:normalise(id, rec) abort
  return {
        \ 'id':      a:id,
        \ 'name':    get(a:rec, 'name', a:id),
        \ 'branch':  get(a:rec, 'branch', ''),
        \ 'path':    get(a:rec, 'path', ''),
        \ 'project': get(a:rec, 'project', ''),
        \ 'created': get(a:rec, 'created', 0),
        \ }
endfunction

" Every workspace of the current repository, newest first.
"
" A worktree removed behind our back (`git worktree remove`, or an rm -rf)
" leaves a record pointing at nothing, so the list prunes those and writes the
" survivors back rather than offering a directory that is gone.
function! claude#workspace#list() abort
  let l:root = claude#workspace#project_root()
  if empty(l:root)
    return []
  endif

  let l:data  = s:load()
  let l:mine  = get(l:data.workspaces, l:root, {})
  let l:out   = []
  let l:stale = 0
  for l:id in keys(l:mine)
    let l:rec = s:normalise(l:id, l:mine[l:id])
    if !isdirectory(l:rec.path)
      let l:stale = 1
      continue
    endif
    call add(l:out, l:rec)
  endfor

  if l:stale
    let l:kept = {}
    for l:rec in l:out
      let l:kept[l:rec.id] = l:rec
    endfor
    let l:data.workspaces[l:root] = l:kept
    call s:save(l:data)
  endif

  call sort(l:out, function('s:cmp'))
  return l:out
endfunction

function! s:cmp(a, b) abort
  if a:a.created != a:b.created
    return a:b.created - a:a.created
  endif
  return a:a.name ==# a:b.name ? 0 : (a:a.name < a:b.name ? -1 : 1)
endfunction

" One workspace of the current repository, or {} when it is unknown or gone.
function! claude#workspace#get(id) abort
  if empty(a:id)
    return {}
  endif
  for l:rec in claude#workspace#list()
    if l:rec.id ==# a:id
      return l:rec
    endif
  endfor
  return {}
endfunction

" The workspace a session was spawned in, or {}.
function! claude#workspace#for_session(id) abort
  let l:rec = claude#session#get(a:id)
  return empty(l:rec) ? {} : claude#workspace#get(get(l:rec, 'workspace', ''))
endfunction

function! s:put(rec) abort
  let l:data = s:load()
  if !has_key(l:data.workspaces, a:rec.project)
    let l:data.workspaces[a:rec.project] = {}
  endif
  let l:data.workspaces[a:rec.project][a:rec.id] = a:rec
  return s:save(l:data)
endfunction

" ── naming and placement ─────────────────────────────────────────────────────

" A name that can also be a directory: branch names carry slashes, which would
" otherwise nest the worktree inside a directory tree of its own.
function! s:slug(text) abort
  let l:s = substitute(a:text, '[/\\ :]\+', '-', 'g')
  return substitute(l:s, '^-\+\|-\+$', '', 'g')
endfunction

" {base}, or base-1, base-2, … until nothing in this repository holds it.
function! claude#workspace#unique_name(base) abort
  let l:base = s:slug(a:base)
  if empty(l:base)
    let l:base = 'workspace'
  endif
  let l:taken = {}
  for l:rec in claude#workspace#list()
    let l:taken[l:rec.name] = 1
  endfor
  if !has_key(l:taken, l:base)
    return l:base
  endif
  let l:n = 1
  while has_key(l:taken, l:base . '-' . l:n)
    let l:n += 1
  endwhile
  return l:base . '-' . l:n
endfunction

" Where a workspace directory goes: under g:claude_workspace_dir when it is
" set, else beside the main checkout as <repo>-<name>, which keeps every
" worktree of one project together in one parent directory.
function! s:dir_for(root, name) abort
  let l:base = get(g:, 'claude_workspace_dir', '')
  if !empty(l:base)
    return substitute(expand(l:base), '/\+$', '', '') . '/' . a:name
  endif
  return fnamemodify(a:root, ':h') . '/' . fnamemodify(a:root, ':t')
        \ . '-' . a:name
endfunction

" ── creating one ─────────────────────────────────────────────────────────────

" What {branch} means, as {local, remote, mode}:
"
"   'local'  an existing local branch, checked out as it is
"   'track'  a remote-only branch, which gets a local tracking branch
"   'new'    an unknown name, branched off the current HEAD
"
" Typing `origin/foo` when `foo` already exists locally resolves to that local
" branch rather than to a second one: the remote-tracking ref and the branch
" following it are the same line of work.
function! s:resolve_branch(root, branch) abort
  if s:is_local(a:root, a:branch)
    return {'local': a:branch, 'remote': '', 'mode': 'local'}
  endif

  let [l:local, l:remote] = s:remote_branch(a:root, a:branch)
  if !empty(l:remote)
    return s:is_local(a:root, l:local)
          \ ? {'local': l:local, 'remote': '', 'mode': 'local'}
          \ : {'local': l:local, 'remote': l:remote, 'mode': 'track'}
  endif

  return {'local': a:branch, 'remote': '', 'mode': 'new'}
endfunction

function! s:is_local(root, branch) abort
  return s:git_ok(a:root, 'show-ref --verify --quiet refs/heads/'
        \ . shellescape(a:branch))
endfunction

" The `git worktree add` arguments for a resolved branch.
function! s:add_args(ref, dir) abort
  let l:quoted = shellescape(a:dir)
  if a:ref.mode ==# 'local'
    return 'worktree add ' . l:quoted . ' ' . shellescape(a:ref.local)
  endif
  if a:ref.mode ==# 'track'
    return 'worktree add --track -b ' . shellescape(a:ref.local)
          \ . ' ' . l:quoted . ' ' . shellescape(a:ref.remote)
  endif
  return 'worktree add -b ' . shellescape(a:ref.local) . ' ' . l:quoted
endfunction

" [local, remote] for a branch that only exists on a remote. {branch} may be
" written either way — `foo` when exactly one remote has it, or `origin/foo` —
" and ['', ''] comes back when it is not a remote branch at all.
function! s:remote_branch(root, branch) abort
  let l:refs = s:git(a:root,
        \ "for-each-ref --format='%(refname:short)' refs/remotes")
  if index(l:refs, a:branch) != -1
    " origin/foo -> the local branch is foo.
    return [substitute(a:branch, '^[^/]\+/', '', ''), a:branch]
  endif
  let l:hits = filter(copy(l:refs),
        \ {_, r -> r =~# '^[^/]\+/' . escape(a:branch, '\.*$^~[]') . '$'})
  " Ambiguous across remotes: let the caller branch off HEAD instead of
  " guessing which remote was meant.
  return len(l:hits) == 1 ? [a:branch, l:hits[0]] : ['', '']
endfunction

" The checkout {branch} already has, as something a session can be started in.
"
" A branch lives in one worktree only, so asking for one that already has a
" checkout is not a mistake to refuse — it is a request to work there. Three
" answers are possible:
"
"   the workspace that already describes that directory, unchanged;
"   a new record adopting a worktree made outside the plugin, so it is listed
"     and selectable like any other;
"   a directory-only record with an empty id for the main checkout, which is
"     where the session runs but is not a workspace and is never persisted.
function! s:existing(root, branch, where) abort
  let l:where = resolve(a:where)
  for l:rec in claude#workspace#list()
    if resolve(l:rec.path) ==# l:where
      return l:rec
    endif
  endfor

  if l:where ==# resolve(a:root)
    return {'id': '', 'name': a:branch, 'branch': a:branch,
          \ 'path': a:root, 'project': a:root, 'created': localtime()}
  endif

  let l:name = claude#workspace#unique_name(a:branch)
  let l:rec = {
        \ 'id':      l:name,
        \ 'name':    l:name,
        \ 'branch':  a:branch,
        \ 'path':    a:where,
        \ 'project': a:root,
        \ 'created': localtime(),
        \ }
  call s:put(l:rec)
  call s:warn('adopted the existing worktree at ' . a:where
        \ . ' as workspace ' . l:rec.name)
  return l:rec
endfunction

" A workspace on {branch}, named {name} (the branch when blank).
"
" Usually that means creating a worktree; when the branch already has one,
" s:existing() hands back the checkout it lives in instead. Returns the
" record, or {} when there is nowhere to run — every failure is reported to
" the user and none of them is fatal to the caller.
function! claude#workspace#create(branch, name) abort
  let l:branch = trim(a:branch)
  if empty(l:branch)
    return {}
  endif

  let l:root = claude#workspace#project_root()
  if empty(l:root)
    call s:warn('not inside a git worktree; no workspace created')
    return {}
  endif

  let l:ref   = s:resolve_branch(l:root, l:branch)
  let l:where = s:checkout_of(l:root, l:ref.local)
  if !empty(l:where)
    return s:existing(l:root, l:ref.local, l:where)
  endif

  let l:name = claude#workspace#unique_name(
        \ empty(a:name) ? l:ref.local : a:name)
  let l:dir  = s:dir_for(l:root, l:name)
  if isdirectory(l:dir) || filereadable(l:dir)
    call s:warn(l:dir . ' already exists; no workspace created')
    return {}
  endif

  let l:parent = fnamemodify(l:dir, ':h')
  if !isdirectory(l:parent)
    try
      call mkdir(l:parent, 'p')
    catch
      call s:warn('cannot create ' . l:parent . '; no workspace created')
      return {}
    endtry
  endif

  let [l:ok, l:msg] = s:git_run(l:root, s:add_args(l:ref, l:dir))
  if !l:ok
    call s:warn('git worktree add failed: ' . l:msg)
    return {}
  endif

  let l:rec = {
        \ 'id':      l:name,
        \ 'name':    l:name,
        \ 'branch':  l:ref.local,
        \ 'path':    l:dir,
        \ 'project': l:root,
        \ 'created': localtime(),
        \ }
  call s:put(l:rec)
  return l:rec
endfunction

" ── removing one ─────────────────────────────────────────────────────────────

function! s:remove(id, force) abort
  let l:rec = claude#workspace#get(a:id)
  if empty(l:rec)
    return 0
  endif

  let l:args = 'worktree remove ' . (a:force ? '--force ' : '')
        \ . shellescape(l:rec.path)
  let [l:ok, l:msg] = s:git_run(l:rec.project, l:args)
  if !l:ok
    call s:warn('git worktree remove failed: ' . l:msg)
    return 0
  endif

  let l:data = s:load()
  if has_key(l:data.workspaces, l:rec.project)
        \ && has_key(l:data.workspaces[l:rec.project], l:rec.id)
    call remove(l:data.workspaces[l:rec.project], l:rec.id)
    call s:save(l:data)
  endif

  if s:current ==# l:rec.id
    let s:current = ''
  endif
  return 1
endfunction

" Remove {id}'s worktree with `git worktree remove`. Fails, leaving the
" record untouched, when the worktree has uncommitted changes or is locked.
function! claude#workspace#remove(id) abort
  return s:remove(a:id, 0)
endfunction

" Remove {id}'s worktree with `git worktree remove --force`, discarding any
" uncommitted changes.
function! claude#workspace#force_remove(id) abort
  return s:remove(a:id, 1)
endfunction

" ── the selected workspace ───────────────────────────────────────────────────

" The workspace new sessions run in when they are given no branch of their
" own. {} means the main checkout.
function! claude#workspace#current() abort
  return claude#workspace#get(s:current)
endfunction

" Select {id} ('' for the main checkout). Returns 1 when it took effect.
function! claude#workspace#set_current(id) abort
  if empty(a:id)
    let s:current = ''
    return 1
  endif
  if empty(claude#workspace#get(a:id))
    return 0
  endif
  let s:current = a:id
  return 1
endfunction

" The directory a branch-less session should be spawned in.
function! claude#workspace#cwd() abort
  let l:ws = claude#workspace#current()
  return empty(l:ws) ? getcwd() : l:ws.path
endfunction

" ── the picker ───────────────────────────────────────────────────────────────

" g:claude_no_popup forces the inputlist() path, as it does for the session
" picker.
function! s:use_popup() abort
  return has('popupwin') && !get(g:, 'claude_no_popup', 0)
endfunction

" :ClaudeWorkspaces — choose the workspace to work in. Selecting one re-roots
" NERDTree onto it, so the file tree shows that checkout and nothing else.
function! claude#workspace#pick() abort
  let l:root = claude#workspace#project_root()
  if empty(l:root)
    call s:warn('not inside a git worktree')
    return
  endif

  let l:list  = claude#workspace#list()
  let l:ids   = ['']
  let l:items = ['  ' . fnamemodify(l:root, ':t') . ' (main checkout)']
  for l:rec in l:list
    call add(l:ids, l:rec.id)
    call add(l:items, (l:rec.id ==# s:current ? '* ' : '  ') . l:rec.name
          \ . ' — ' . l:rec.branch
          \ . ' — ' . claude#sidebar#home_relative(l:rec.path))
  endfor

  if s:use_popup()
    call popup_menu(l:items, {
          \ 'title':    ' Workspaces ',
          \ 'callback': {_, idx -> s:picked(l:ids, idx)},
          \ 'filter':   'popup_filter_menu',
          \ 'padding':  [0, 1, 0, 1],
          \ 'border':   [],
          \ })
    return
  endif

  let l:menu = ['Workspace:']
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
  call claude#workspace#select(a:ids[a:idx - 1])
endfunction

" Make {id} the current workspace and point NERDTree at it. '' selects the
" main checkout again.
function! claude#workspace#select(id) abort
  if !claude#workspace#set_current(a:id)
    call s:warn('unknown workspace: ' . a:id)
    return
  endif
  let l:ws  = claude#workspace#current()
  let l:dir = empty(l:ws) ? claude#workspace#project_root() : l:ws.path
  call s:reroot(l:dir)
endfunction

" Re-root NERDTree onto {dir} without disturbing the sidebar column or the
" window the user was in.
function! s:reroot(dir) abort
  if !claude#sidebar#nerdtree_available()
    call s:warn('NERDTree is not installed; workspace selected anyway')
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
  endtry
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

function! claude#workspace#_reset() abort
  let s:current    = ''
  let s:root_cache = {}
endfunction
