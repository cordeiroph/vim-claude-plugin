" ── JSON stores ──────────────────────────────────────────────────────────────
"
" Persists small dictionaries to JSON so they survive a Vim restart. Three of
" them exist: session naming and grouping metadata (see
" autoload/claude/session.vim), per-branch diff bases (see
" autoload/claude/difftree.vim), and the git worktrees a session can be given
" to work in (see autoload/claude/workspace.vim). Runtime state — buffer
" numbers, jobs, status — is never written here.
"
" The *_at() functions take a path and a payload key so the stores share one
" implementation of the awkward parts: atomic write, corruption recovery,
" schema-version refusal and graceful degradation when the file cannot be
" written. claude#store#load()/save() are the session-store wrappers.
"
" This module is deliberately pure I/O: no terminal, no jobs, no git. That
" makes it testable in isolation (test/store.vader).

" Plugin root, resolved once while this script is being sourced. Inside a
" function <sfile> expands to the function name, so it must be captured here.
"   <root>/autoload/claude/store.vim  :h:h:h  ->  <root>
let s:plugin_root = expand('<sfile>:p:h:h:h')

" Schema version this build writes. A store carrying a *higher* version was
" written by a newer plugin, so we read it but refuse to write it back.
let s:VERSION = 1

" Warnings are echoed at most once per Vim session, keyed by kind.
let s:warned = {}

" Set when the loaded store came from a future schema version.
let s:read_only = v:false

" Path of the store file. g:claude_session_store wins when set; otherwise the
" file lives inside the plugin directory, which keeps the plugin
" self-contained at the cost of being wiped by a plugin reinstall.
function! claude#store#path() abort
  let l:override = get(g:, 'claude_session_store', '')
  if !empty(l:override)
    return expand(l:override)
  endif
  return s:plugin_root . '/data/sessions.json'
endfunction

" Path of the per-branch diff base store, with the same override-or-plugin-dir
" rule and the same reinstall caveat.
function! claude#store#difftree_path() abort
  let l:override = get(g:, 'claude_difftree_store', '')
  if !empty(l:override)
    return expand(l:override)
  endif
  return s:plugin_root . '/data/difftree.json'
endfunction

" Path of the workspace store, following the same rule again
" (g:claude_workspace_store, else the plugin's data directory).
function! claude#store#workspace_path() abort
  let l:override = get(g:, 'claude_workspace_store', '')
  if !empty(l:override)
    return expand(l:override)
  endif
  return s:plugin_root . '/data/workspaces.json'
endfunction

" Echo {msg} as a warning the first time {kind} is seen in this Vim session.
function! s:warn_once(kind, msg) abort
  if has_key(s:warned, a:kind)
    return
  endif
  let s:warned[a:kind] = 1
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" An empty, well-formed store holding {key}.
function! s:empty(key) abort
  return {'version': s:VERSION, a:key: {}}
endfunction

" Read a store from disk. Always returns a usable dict — a missing file, a
" corrupt file or a future schema never raises.
"
" {key} is the payload key ("sessions", "bases", "workspaces"); {what} names
" the store in warnings.
function! claude#store#load_at(path, key, what) abort
  let s:read_only = v:false

  if !filereadable(a:path)
    return s:empty(a:key)
  endif

  let l:raw = join(readfile(a:path), "\n")
  try
    let l:data = json_decode(l:raw)
  catch
    " Never overwrite unreadable data silently: keep a copy and start fresh.
    let l:bak = a:path . '.bak'
    call rename(a:path, l:bak)
    call s:warn_once('corrupt-' . a:key,
          \ a:what . ' was corrupt; moved to ' . l:bak)
    return s:empty(a:key)
  endtry

  if type(l:data) != v:t_dict || type(get(l:data, a:key, 0)) != v:t_dict
    let l:bak = a:path . '.bak'
    call rename(a:path, l:bak)
    call s:warn_once('corrupt-' . a:key,
          \ a:what . ' was malformed; moved to ' . l:bak)
    return s:empty(a:key)
  endif

  if get(l:data, 'version', s:VERSION) > s:VERSION
    " Written by a newer plugin. Reading is safe; writing would drop fields
    " this build knows nothing about.
    let s:read_only = v:true
    call s:warn_once('future-' . a:key,
          \ a:what . ' uses a newer format; running read-only')
  endif

  return l:data
endfunction

" Write {data} to {path} atomically. Returns 1 on success, 0 on failure.
" A failure is warned about once and is never fatal: the caller keeps its
" in-memory state and simply loses persistence for this Vim session.
function! claude#store#save_at(path, data, what) abort
  if s:read_only
    return 0
  endif

  let l:dir = fnamemodify(a:path, ':h')
  if !isdirectory(l:dir)
    try
      call mkdir(l:dir, 'p')
    catch
      call s:warn_once('write-' . a:path,
            \ 'cannot create ' . l:dir . '; ' . a:what . ' is in-memory only')
      return 0
    endtry
  endif

  let a:data.version = s:VERSION

  " Write to a sibling temp file and rename over the target, so a crash
  " mid-write cannot leave a truncated store behind.
  let l:tmp = a:path . '.tmp'
  try
    if writefile([json_encode(a:data)], l:tmp) != 0
      throw 'writefile failed'
    endif
    if rename(l:tmp, a:path) != 0
      throw 'rename failed'
    endif
  catch
    call delete(l:tmp)
    call s:warn_once('write-' . a:path,
          \ a:what . ' not writable (' . a:path . '); in-memory only')
    return 0
  endtry

  return 1
endfunction

" ── the session name store ───────────────────────────────────────────────────

function! claude#store#load() abort
  return claude#store#load_at(claude#store#path(), 'sessions', 'session store')
endfunction

function! claude#store#save(data) abort
  return claude#store#save_at(claude#store#path(), a:data, 'session store')
endfunction

" Merge {entry} for {id} into the store and write it back. The file is
" re-read first so a concurrent Vim instance's names are not clobbered
" (last-writer-wins per key, not per file).
function! claude#store#put(id, entry) abort
  let l:data = claude#store#load()
  let l:data.sessions[a:id] = a:entry
  return claude#store#save(l:data)
endfunction

" Remove {id} from the store and write it back.
function! claude#store#remove(id) abort
  let l:data = claude#store#load()
  if has_key(l:data.sessions, a:id)
    call remove(l:data.sessions, a:id)
  endif
  return claude#store#save(l:data)
endfunction

" True when the loaded store came from a newer plugin and must not be written.
function! claude#store#is_read_only() abort
  return s:read_only
endfunction

" Clear warn-once state and the read-only flag. Test seam.
function! claude#store#_reset() abort
  let s:warned    = {}
  let s:read_only = v:false
endfunction
