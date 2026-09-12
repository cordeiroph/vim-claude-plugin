" ── provider registry ────────────────────────────────────────────────────────
"
" A provider is one coding-agent CLI: how to launch it, where it keeps its
" conversations on disk, and what its terminal says while it works. The
" registry itself knows none of that. Each CLI lives in
" autoload/claude/provider/<name>.vim and is sourced the first time it is asked
" for, so a session running only Claude never loads the others.
"
" A module must export claude#provider#<name>#spec(); every other function is
" optional. A hook that is not implemented is not an error — claude#provider#call()
" answers with the caller's default instead, which is how a CLI with no
" live-holder registry, or no in-session model switch, is supported without
" pretending it has one.
"
" The hooks, and what answering nothing means:
"
"   argv({spec})                  the launch vector       -> split(spec.cmd)
"   fork_argv({spec})             the fork-retry vector    -> no fork retry
"   project_dir({cwd})            where conversations live -> ''
"   transcript_path({id}, {cwd})  one conversation's file  -> '' (never resumes)
"   ids({cwd})                    ids on disk, as a dict   -> {}
"   scan({path})                  read one conversation    -> {}
"   sessions({cwds})              every conversation here  -> []
"   holder_pid({id})              pid holding {id} open    -> 0 (no lock check)
"   refusal_pat()                 "already in use" text    -> no fork retry
"   model_text({model})           what /model looks like   -> no model switch
"   completion({cwd})             slash commands & agents  -> file completion

" Providers shipped with the plugin, in the order pickers offer them.
let s:BUILTIN = ['claude']

" name -> 1 once its module has been sourced, 0 when there is no such module.
let s:loaded = {}

let s:warned = {}

function! s:warn_once(kind, msg) abort
  if has_key(s:warned, a:kind)
    return
  endif
  let s:warned[a:kind] = 1
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" Source {name}'s module by referencing its spec(), and remember whether there
" was one. exists('*...') does not trigger autoload, so this has to be asked
" first, before any hook can be tested for.
function! s:ensure(name) abort
  if has_key(s:loaded, a:name)
    return s:loaded[a:name]
  endif
  let s:loaded[a:name] = 0
  if a:name !~# '^\w\+$'
    return 0
  endif
  try
    call call('claude#provider#' . a:name . '#spec', [])
    let s:loaded[a:name] = 1
  catch /E117/
  endtry
  return s:loaded[a:name]
endfunction

" {name} when it names a provider that exists, else 'claude'. Every entry
" point resolves through here, so a typo in a config or a store entry written
" by a future build degrades to the default instead of failing a spawn.
function! s:resolve(name) abort
  if s:ensure(a:name)
    return a:name
  endif
  call s:warn_once('provider-' . a:name,
        \ 'unknown provider ' . string(a:name) . '; using claude')
  return 'claude'
endfunction

" Whether {name} is a provider this build knows.
function! claude#provider#exists(name) abort
  return index(s:BUILTIN, a:name) != -1 && s:ensure(a:name)
endfunction

" The provider a new session runs on unless something says otherwise.
function! claude#provider#default() abort
  let l:name = get(g:, 'claude_provider', 'claude')
  if !claude#provider#exists(l:name)
    call s:warn_once('default-' . l:name,
          \ 'g:claude_provider names no provider (' . string(l:name)
          \ . '); using claude')
    return 'claude'
  endif
  return l:name
endfunction

" Every registered provider, the default first so the muscle-memory answer to
" a picker is always 1.
function! claude#provider#names() abort
  let l:default = claude#provider#default()
  let l:names   = [l:default]
  for l:name in s:BUILTIN
    if l:name !=# l:default && claude#provider#exists(l:name)
      call add(l:names, l:name)
    endif
  endfor
  return l:names
endfunction

" {name}'s description: the module's spec() with the user's overrides from
" g:claude_providers merged over it.
"
" Deliberately not cached. A spec reads globals the user (and the test suite)
" changes at runtime — g:claude_cmd is the obvious one — and building a small
" dictionary costs nothing next to what every caller does with it.
function! claude#provider#get(name) abort
  let l:name = s:resolve(a:name)
  let l:spec = call('claude#provider#' . l:name . '#spec', [])
  let l:over = get(get(g:, 'claude_providers', {}), l:name, {})
  if type(l:over) != v:t_dict || empty(l:over)
    return l:spec
  endif
  " caps is merged key by key, so overriding one capability does not silently
  " drop the others.
  let l:caps = extend(copy(get(l:spec, 'caps', {})), get(l:over, 'caps', {}))
  let l:spec = extend(copy(l:spec), l:over)
  let l:spec.caps = l:caps
  return l:spec
endfunction

" What a picker or a panel row calls {name}.
function! claude#provider#label(name) abort
  return get(claude#provider#get(a:name), 'label', a:name)
endfunction

" One capability of {name}, or {default} when its spec does not mention it.
function! claude#provider#cap(name, cap, default) abort
  return get(get(claude#provider#get(a:name), 'caps', {}), a:cap, a:default)
endfunction

" A record's provider. Records and store entries written before providers
" existed carry no field, and every one of them is Claude.
function! claude#provider#of(rec) abort
  return s:resolve(get(a:rec, 'provider', 'claude'))
endfunction

" Whether {name} implements hook {fn}.
function! claude#provider#has(name, fn) abort
  let l:name = s:resolve(a:name)
  return exists('*claude#provider#' . l:name . '#' . a:fn)
endfunction

" Call {name}'s {fn} with {args}, or return {default} when it has none.
" This is the only way the rest of the plugin reaches a provider.
function! claude#provider#call(name, fn, args, default) abort
  let l:name = s:resolve(a:name)
  if !exists('*claude#provider#' . l:name . '#' . a:fn)
    return a:default
  endif
  return call('claude#provider#' . l:name . '#' . a:fn, a:args)
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

" Forget which modules have been sourced and which warnings have been given.
function! claude#provider#_reset() abort
  let s:loaded = {}
  let s:warned = {}
endfunction
