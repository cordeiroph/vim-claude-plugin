" ── session name store ───────────────────────────────────────────────────────
"
" Persists session *naming and grouping* metadata to a JSON file so names
" survive a Vim restart. Runtime state (buffer numbers, jobs, status) is never
" written here — see autoload/claude/session.vim for the live registry.
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

" An empty, well-formed store.
function! s:empty() abort
  return {'version': s:VERSION, 'sessions': {}}
endfunction

" Read the store from disk. Always returns a usable dict — a missing file, a
" corrupt file or a future schema never raises.
function! claude#store#load() abort
  let s:read_only = v:false
  let l:path = claude#store#path()

  if !filereadable(l:path)
    return s:empty()
  endif

  let l:raw = join(readfile(l:path), "\n")
  try
    let l:data = json_decode(l:raw)
  catch
    " Never overwrite unreadable data silently: keep a copy and start fresh.
    let l:bak = l:path . '.bak'
    call rename(l:path, l:bak)
    call s:warn_once('corrupt',
          \ 'session store was corrupt; moved to ' . l:bak)
    return s:empty()
  endtry

  if type(l:data) != v:t_dict || type(get(l:data, 'sessions', 0)) != v:t_dict
    let l:bak = l:path . '.bak'
    call rename(l:path, l:bak)
    call s:warn_once('corrupt',
          \ 'session store was malformed; moved to ' . l:bak)
    return s:empty()
  endif

  if get(l:data, 'version', s:VERSION) > s:VERSION
    " Written by a newer plugin. Reading is safe; writing would drop fields
    " this build knows nothing about.
    let s:read_only = v:true
    call s:warn_once('future',
          \ 'session store uses a newer format; running read-only')
  endif

  return l:data
endfunction

" Write {data} to disk atomically. Returns 1 on success, 0 on failure.
" A failure is warned about once and is never fatal: the caller keeps its
" in-memory registry and simply loses persistence for this Vim session.
function! claude#store#save(data) abort
  if s:read_only
    return 0
  endif

  let l:path = claude#store#path()
  let l:dir  = fnamemodify(l:path, ':h')
  if !isdirectory(l:dir)
    try
      call mkdir(l:dir, 'p')
    catch
      call s:warn_once('write',
            \ 'cannot create ' . l:dir . '; session names are in-memory only')
      return 0
    endtry
  endif

  let a:data.version = s:VERSION

  " Write to a sibling temp file and rename over the target, so a crash
  " mid-write cannot leave a truncated store behind.
  let l:tmp = l:path . '.tmp'
  try
    if writefile([json_encode(a:data)], l:tmp) != 0
      throw 'writefile failed'
    endif
    if rename(l:tmp, l:path) != 0
      throw 'rename failed'
    endif
  catch
    call delete(l:tmp)
    call s:warn_once('write',
          \ 'session store not writable (' . l:path
          \ . '); names are in-memory only')
    return 0
  endtry

  return 1
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
