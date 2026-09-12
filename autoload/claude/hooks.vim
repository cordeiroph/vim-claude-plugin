" ── session-panel hook installation ──────────────────────────────────────────
"
" |:SessionPanelHookSetup| puts the bundled status writers into the folder Vim
" is sitting in: the Claude Code hook handler plus its entry in
" .claude/settings.local.json, and the Pi extension that needs no settings at
" all. The reader in autoload/claude/session.vim is untouched by any of this —
" it still reads nothing until g:claude_panel_hook_state is set.
"
" This is the one place the plugin writes another program's configuration, and
" only ever after being asked to, only under getcwd(), and never under $HOME.
" Everything here is therefore written to be safe to run twice: a copy that is
" already correct is left alone, a settings file that already registers the
" handler is not rewritten at all, and anything unreadable is refused rather
" than replaced.
"
" Both writers are copied out of examples/, where each one is a symlink to the
" copy this repository runs on its own sessions, so what gets installed and
" what gets dogfooded cannot drift apart.

" Plugin root, resolved while this script is sourced: inside a function
" <sfile> is the function name.
"   <root>/autoload/claude/hooks.vim  :h:h:h  ->  <root>
let s:plugin_root = expand('<sfile>:p:h:h:h')

" What each provider installs. 'perm' is the mode the copy lands with: Claude
" runs its writer as a command, so that one has to be executable; Pi imports
" its extension, so that one does not.
let s:FILES = {
      \ 'claude': {
      \   'src':  'examples/hooks/claude-vim-status.mjs',
      \   'dst':  '.claude/hooks/claude-vim-status.mjs',
      \   'perm': 'rwxr-xr-x',
      \ },
      \ 'pi': {
      \   'src':  'examples/pi/claude-vim-status.ts',
      \   'dst':  '.pi/extensions/claude-vim-status.ts',
      \   'perm': 'rw-r--r--',
      \ },
      \ }

" The hook registrations merged into a project's settings, and the file they
" are merged into.
let s:CLAUDE_EXAMPLE  = 'examples/hooks/settings.example.json'
let s:CLAUDE_SETTINGS = '.claude/settings.local.json'

" ── reporting ────────────────────────────────────────────────────────────────
"
" An installer that says nothing is indistinguishable from one that did
" nothing, so every step appends its line and the command echoes the lot. A
" refusal is a line like any other: one provider failing must not stop the
" other from being installed.

function! s:say(report, line) abort
  call add(a:report.lines, {'text': a:line, 'bad': 0})
endfunction

function! s:refuse(report, line) abort
  call add(a:report.lines, {'text': a:line, 'bad': 1})
  let a:report.ok = 0
endfunction

" The report as plain strings, which is all a test or a caller wants.
function! claude#hooks#_texts(report) abort
  return map(copy(a:report.lines), 'v:val.text')
endfunction

" ── file copying ─────────────────────────────────────────────────────────────

" Read {path} as bytes. readfile() follows symlinks, which is what makes
" copying out of examples/ copy the file each link points at.
function! s:bytes(path) abort
  return readfile(a:path, 'b')
endfunction

" Copy {src} over {dst}, reporting what it did. An identical copy is left
" alone so a re-run is a no-op; a copy that differs — an older plugin's, or
" one the user edited — is kept as .bak rather than silently discarded.
function! s:copy(src, dst, perm, report) abort
  if !filereadable(a:src)
    call s:refuse(a:report, 'missing from the plugin: ' . a:src)
    return 0
  endif

  let l:want = s:bytes(a:src)
  if filereadable(a:dst) && s:bytes(a:dst) ==# l:want
    " setfperm is still worth doing: a copy can survive a checkout that
    " dropped its executable bit.
    call setfperm(a:dst, a:perm)
    call s:say(a:report, 'already installed: ' . a:dst)
    return 1
  endif

  let l:dir = fnamemodify(a:dst, ':h')
  if !isdirectory(l:dir)
    try
      call mkdir(l:dir, 'p', 0700)
    catch
      call s:refuse(a:report, 'cannot create ' . l:dir)
      return 0
    endtry
  endif

  let l:existed = filereadable(a:dst)
  if l:existed
    let l:bak = a:dst . '.bak'
    if rename(a:dst, l:bak) != 0
      call s:refuse(a:report, 'cannot move the old copy aside: ' . a:dst)
      return 0
    endif
    call s:say(a:report, 'kept the old copy as ' . l:bak)
  endif

  if writefile(l:want, a:dst, 'b') != 0
    call s:refuse(a:report, 'cannot write ' . a:dst)
    return 0
  endif
  call setfperm(a:dst, a:perm)
  call s:say(a:report, (l:existed ? 'updated: ' : 'installed: ') . a:dst)
  return 1
endfunction

" ── JSON ─────────────────────────────────────────────────────────────────────

" Decode {path} as a JSON object. Returns [status, dict], where status is
" 'ok', 'missing', or 'bad' for anything that is not decodable as one.
function! s:read_json(path) abort
  if !filereadable(a:path)
    return ['missing', {}]
  endif
  try
    let l:data = json_decode(join(readfile(a:path), "\n"))
  catch
    return ['bad', {}]
  endtry
  if type(l:data) != v:t_dict
    return ['bad', {}]
  endif
  return ['ok', l:data]
endfunction

" Write {data} to {path} atomically, through a sibling temp file, so a crash
" mid-write cannot leave a truncated settings file behind. Deliberately not
" claude#store#save_at(), which stamps its own schema version into whatever it
" writes; that key has no business in another program's configuration.
function! s:write_json(path, data) abort
  let l:tmp = a:path . '.tmp'
  if writefile([json_encode(a:data)], l:tmp) != 0
    return 0
  endif
  if rename(l:tmp, a:path) != 0
    call delete(l:tmp)
    return 0
  endif
  return 1
endfunction

" ── the Claude settings merge ────────────────────────────────────────────────

" Every command string {block} registers, so a handler already present can be
" recognised however the rest of the block is shaped.
function! s:commands_of(block) abort
  let l:cmds = []
  if type(a:block) != v:t_dict
    return l:cmds
  endif
  for l:hook in s:list(get(a:block, 'hooks', []))
    if type(l:hook) != v:t_dict
      continue
    endif
    if type(get(l:hook, 'command', 0)) == v:t_string
      call add(l:cmds, l:hook.command)
    endif
  endfor
  return l:cmds
endfunction

function! s:list(value) abort
  return type(a:value) == v:t_list ? a:value : []
endfunction

" Is any of {cmds} already registered among {blocks}? Matching on the command
" alone is what makes a second run add nothing: the handler is the thing that
" must not be registered twice, whatever matcher or timeout sits around it.
function! s:registered(blocks, cmds) abort
  for l:block in s:list(a:blocks)
    for l:cmd in s:commands_of(l:block)
      if index(a:cmds, l:cmd) >= 0
        return 1
      endif
    endfor
  endfor
  return 0
endfunction

" Merge the example's hook blocks into <dir>/.claude/settings.local.json,
" keeping every key and every handler already there.
function! s:merge_settings(dir, report) abort
  let l:example_path = s:plugin_root . '/' . s:CLAUDE_EXAMPLE
  let [l:status, l:example] = s:read_json(l:example_path)
  if l:status !=# 'ok'
    call s:refuse(a:report, 'cannot read the plugin''s ' . s:CLAUDE_EXAMPLE)
    return 0
  endif

  let l:path = a:dir . '/' . s:CLAUDE_SETTINGS
  let [l:status, l:settings] = s:read_json(l:path)
  if l:status ==# 'bad'
    " Someone else's configuration that this cannot parse is not something to
    " overwrite: a hooks block is not worth losing permissions or env over.
    call s:refuse(a:report,
          \ 'refused: ' . l:path . ' is not readable JSON; merge it by hand')
    return 0
  endif

  if type(get(l:settings, 'hooks', {})) != v:t_dict
    call s:refuse(a:report,
          \ 'refused: "hooks" in ' . l:path . ' is not an object')
    return 0
  endif
  let l:hooks = get(l:settings, 'hooks', {})

  let l:added = 0
  for l:event in sort(keys(get(l:example, 'hooks', {})))
    let l:existing = s:list(get(l:hooks, l:event, []))
    for l:block in s:list(l:example.hooks[l:event])
      let l:cmds = s:commands_of(l:block)
      if empty(l:cmds) || s:registered(l:existing, l:cmds)
        continue
      endif
      call add(l:existing, l:block)
      let l:added += 1
    endfor
    if !empty(l:existing)
      let l:hooks[l:event] = l:existing
    endif
  endfor

  if l:added == 0
    " Nothing to add means nothing to write: not rewriting the file is the
    " cheapest possible guarantee that a second run changes nothing.
    call s:say(a:report, 'already registered in ' . l:path)
    return 1
  endif

  let l:settings.hooks = l:hooks
  let l:dir = fnamemodify(l:path, ':h')
  if !isdirectory(l:dir)
    try
      call mkdir(l:dir, 'p', 0700)
    catch
      call s:refuse(a:report, 'cannot create ' . l:dir)
      return 0
    endtry
  endif
  if !s:write_json(l:path, l:settings)
    call s:refuse(a:report, 'cannot write ' . l:path)
    return 0
  endif
  call s:say(a:report, printf('registered %d hook%s in %s',
        \ l:added, l:added == 1 ? '' : 's', l:path))
  return 1
endfunction

" ── per-provider installation ────────────────────────────────────────────────

function! s:install(provider, dir, report) abort
  let l:file = s:FILES[a:provider]
  call s:copy(s:plugin_root . '/' . l:file.src,
        \ a:dir . '/' . l:file.dst, l:file.perm, a:report)
  if a:provider ==# 'claude'
    call s:merge_settings(a:dir, a:report)
  else
    " Pi needs no registration: it loads .pi/extensions/*.ts by itself, once
    " the project is trusted.
    call s:say(a:report, 'pi loads it once this project is trusted')
  endif
endfunction

" ── the command ──────────────────────────────────────────────────────────────

" Which providers {args} asks for. An empty argument means every provider
" something is bundled for; anything unrecognised is an error, reported
" without writing a thing.
function! s:providers(args, report) abort
  let l:want = split(a:args)
  if empty(l:want)
    return filter(claude#provider#names(), 'has_key(s:FILES, v:val)')
  endif
  let l:names = []
  for l:name in l:want
    if !has_key(s:FILES, l:name)
      call s:refuse(a:report, 'no bundled hooks for "' . l:name
            \ . '"; try ' . join(sort(keys(s:FILES)), ' or '))
      return []
    endif
    if index(l:names, l:name) < 0
      call add(l:names, l:name)
    endif
  endfor
  return l:names
endfunction

" Install into {dir} rather than getcwd(), so the tests can drive this
" without installing anything into the folder they run in.
function! claude#hooks#_setup_in(dir, args) abort
  let l:report = {'ok': 1, 'lines': []}
  let l:names = s:providers(a:args, l:report)
  for l:name in l:names
    call s:say(l:report, '— ' . claude#provider#label(l:name))
    call s:install(l:name, a:dir, l:report)
  endfor

  if !empty(l:names) && !get(g:, 'claude_panel_hook_state', 0)
    " The records are written from now on whatever Vim thinks; they are simply
    " read by nobody until this is set.
    call s:say(l:report,
          \ 'the panel ignores the records until your vimrc sets '
          \ . 'g:claude_panel_hook_state = 1')
  endif
  return l:report
endfunction

function! claude#hooks#setup(args) abort
  let l:dir = getcwd()
  let l:report = claude#hooks#_setup_in(l:dir, a:args)

  echo 'claude.vim: session-panel hooks in ' . l:dir
  for l:line in l:report.lines
    if l:line.bad
      echohl WarningMsg
    endif
    echo '  ' . l:line.text
    echohl None
  endfor
  return l:report.ok
endfunction

function! claude#hooks#complete(arglead, cmdline, cursorpos) abort
  let l:names = filter(claude#provider#names(), 'has_key(s:FILES, v:val)')
  return filter(l:names, 'stridx(v:val, a:arglead) == 0')
endfunction
