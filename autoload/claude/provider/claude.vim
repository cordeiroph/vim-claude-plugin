" ── the Claude provider ──────────────────────────────────────────────────────
"
" Claude Code, the CLI this plugin was written against. Everything here was
" inline in autoload/claude/session.vim and autoload/claude/input.vim until the
" registry existed; the globals it reads keep exactly the meanings they always
" had, as this provider's settings rather than the plugin's:
"
"   g:claude_cmd                 what to run
"   g:claude_models              what :ClaudeModel offers
"   g:claude_panel_working_pat   what the terminal says while it works
"   g:claude_panel_waiting_pat   what it says while it waits for you
"   g:claude_session_flags       override for the --session-id/--name probe
"   g:claude_sessions_dir        the CLI's live-holder registry

let s:MODELS = [
      \ 'claude-opus-4-7',
      \ 'claude-sonnet-4-6',
      \ 'claude-haiku-4-5-20251001',
      \ ]

let s:WAITING = '\%(^\|\n\)\s*❯\=\s*1\.\s\|Do you want\|(y/n)'

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

function! claude#provider#claude#spec() abort
  let l:flags = claude#provider#claude#supports_flags()
  return {
        \ 'name':        'claude',
        \ 'label':       'Claude',
        \ 'cmd':         get(g:, 'claude_cmd', 'claude'),
        \ 'models':      get(g:, 'claude_models', s:MODELS),
        \ 'working_pat': get(g:, 'claude_panel_working_pat', 'esc to interrupt'),
        \ 'waiting_pat': get(g:, 'claude_panel_waiting_pat', s:WAITING),
        \ 'caps':        {'preassign_id': l:flags, 'name_flag': l:flags},
        \ }
endfunction

" ── capabilities ─────────────────────────────────────────────────────────────

" Whether the configured CLI understands --session-id and --name.
"
" The probe runs `<cmd> --help`, so it only runs when g:claude_cmd actually
" invokes the Claude binary. A stand-in command (tests use `sleep 30`) is
" never executed just to read its help.
function! claude#provider#claude#supports_flags() abort
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
  let l:cmd   = get(g:, 'claude_cmd', 'claude')
  let l:words = split(l:cmd)
  if empty(l:words)
    return s:flags_ok
  endif
  if fnamemodify(l:words[0], ':t') !~# '^claude'
    return s:flags_ok
  endif
  let l:help = system(l:cmd . ' --help 2>/dev/null </dev/null')
  let s:flags_ok = (l:help =~# '--session-id' && l:help =~# '--name') ? 1 : 0
  if !s:flags_ok
    call s:warn_once('flags',
          \ 'claude CLI has no --session-id/--name (needs 2.1+); '
          \ . 'session ids are adopted from transcripts instead')
  endif
  return s:flags_ok
endfunction

" ── launching ────────────────────────────────────────────────────────────────

" {spec} is {'id', 'name', 'resume'}. The result is a List, never a string:
" :terminal and job_start() run no shell, so a string command is split on
" whitespace with no quote handling and a name containing a space would be
" torn into several arguments.
function! claude#provider#claude#argv(spec) abort
  let l:argv  = split(get(claude#provider#get('claude'), 'cmd', 'claude'))
  let l:flags = claude#provider#claude#supports_flags()
  if get(a:spec, 'resume', 0)
    call extend(l:argv, ['--resume', a:spec.id])
  elseif l:flags
    call extend(l:argv, ['--session-id', a:spec.id])
  endif
  if l:flags && !empty(get(a:spec, 'name', ''))
    call extend(l:argv, ['--name', a:spec.name])
  endif
  return l:argv
endfunction

" Continue {spec.id}'s conversation under a fresh id: --fork-session copies its
" history forward rather than resuming an id the CLI has refused.
function! claude#provider#claude#fork_argv(spec) abort
  let l:argv = split(get(claude#provider#get('claude'), 'cmd', 'claude'))
  call extend(l:argv, ['--resume', a:spec.id, '--fork-session'])
  if claude#provider#claude#supports_flags() && !empty(get(a:spec, 'name', ''))
    call extend(l:argv, ['--name', a:spec.name])
  endif
  return l:argv
endfunction

" The refusal the lock check cannot see coming — no local process or registry
" entry ever names it, the CLI tracks it some other way.
function! claude#provider#claude#refusal_pat() abort
  return 'already in use'
endfunction

" What :ClaudeModel sends to switch model mid-session.
function! claude#provider#claude#model_text(model) abort
  return '/model ' . a:model
endfunction

" ── transcripts ──────────────────────────────────────────────────────────────

" Claude stores a project's transcripts under a slugified copy of its cwd:
" every character that is not a letter or digit becomes a '-', not just the
" path separator — a cwd with a dot or underscore in it (a "pedro.cordeiro"
" home directory, a "github.com" path segment, an "e2e_extraction" worktree)
" was slugifying to a directory that does not exist, so has_transcript() and
" is_foreign_active() always came back empty for such a project and every
" resume fell through to --session-id instead of --resume — which the CLI
" then refuses outright, since a transcript for that id already exists on
" disk under the *correctly* slugified directory it never thought to check.
function! claude#provider#claude#project_dir(cwd) abort
  return expand('~/.claude/projects/')
        \ . substitute(a:cwd, '[^A-Za-z0-9]', '-', 'g')
endfunction

" The filename is the session id, which is what makes a conversation the same
" object here, in Claude's own /resume picker and on disk.
function! claude#provider#claude#transcript_path(id, cwd) abort
  if empty(a:cwd)
    return ''
  endif
  return claude#provider#claude#project_dir(a:cwd) . '/' . a:id . '.jsonl'
endfunction

" Every session id already on disk for {cwd}, as a dict for cheap lookup.
function! claude#provider#claude#ids(cwd) abort
  let l:dir = claude#provider#claude#project_dir(a:cwd)
  if !isdirectory(l:dir)
    return {}
  endif
  let l:seen = {}
  for l:path in glob(l:dir . '/*.jsonl', 0, 1)
    let l:seen[fnamemodify(l:path, ':t:r')] = 1
  endfor
  return l:seen
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
function! claude#provider#claude#scan(path) abort
  let l:rec = {
        \ 'id':      fnamemodify(a:path, ':t:r'),
        \ 'path':    a:path,
        \ 'cwd':     '',
        \ 'branch':  '',
        \ 'name':    '',
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

" Every conversation belonging to the directories in {cwds}: the one Vim is
" in, plus every workspace of this repository. Claude files a transcript under
" the directory the session ran in, so a workspace session's conversations
" live under its own worktree and are invisible from the main checkout
" otherwise. Newest first, capped across the project rather than per directory.
function! claude#provider#claude#sessions(cwds) abort
  let l:limit = get(g:, 'claude_panel_closed_limit', 10)
  if l:limit <= 0
    return []
  endif
  let l:seen  = {}
  let l:paths = []
  for l:cwd in a:cwds
    let l:dir = claude#provider#claude#project_dir(l:cwd)
    if !isdirectory(l:dir) || has_key(l:seen, l:dir)
      continue
    endif
    let l:seen[l:dir] = 1
    call extend(l:paths, glob(l:dir . '/*.jsonl', 0, 1))
  endfor
  if empty(l:paths)
    return []
  endif
  call sort(l:paths, {a, b -> getftime(b) - getftime(a)})
  return map(l:paths[0 : l:limit - 1],
        \ {_, p -> claude#provider#claude#scan(p)})
endfunction

" ── the live-holder registry ─────────────────────────────────────────────────

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
function! claude#provider#claude#holder_pid(id) abort
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

" ── completion ───────────────────────────────────────────────────────────────

" Built-in slash commands — base list, always available once Claude starts.
let s:SLASH_COMMANDS = [
      \ {'word': '/add',          'menu': 'Add files to context'},
      \ {'word': '/bug',          'menu': 'Report a bug to Anthropic'},
      \ {'word': '/clear',        'menu': 'Clear conversation history'},
      \ {'word': '/compact',      'menu': 'Compact conversation to save tokens'},
      \ {'word': '/config',       'menu': 'Open configuration settings'},
      \ {'word': '/cost',         'menu': 'Show token usage and cost'},
      \ {'word': '/doctor',       'menu': 'Run diagnostics'},
      \ {'word': '/help',         'menu': 'Show help'},
      \ {'word': '/init',         'menu': 'Initialize CLAUDE.md for project'},
      \ {'word': '/login',        'menu': 'Log in to Claude'},
      \ {'word': '/logout',       'menu': 'Log out of Claude'},
      \ {'word': '/memory',       'menu': 'View and manage memory'},
      \ {'word': '/model',        'menu': 'Switch model'},
      \ {'word': '/permissions',  'menu': 'Manage tool permissions'},
      \ {'word': '/pr_comments',  'menu': 'View PR review comments'},
      \ {'word': '/quit',         'menu': 'Quit Claude'},
      \ {'word': '/release-notes','menu': 'Show release notes'},
      \ {'word': '/review',       'menu': 'Code review mode'},
      \ {'word': '/status',       'menu': 'Show account and session status'},
      \ {'word': '/terminal',     'menu': 'Run a command in terminal'},
      \ {'word': '/vim',          'menu': 'Enter Vim mode'},
      \ ]

let s:AGENTS = [
      \ {'word': '@claude',          'abbr': 'claude',          'menu': '[Built-in Agent]'},
      \ {'word': '@Explore',         'abbr': 'Explore',         'menu': '[Built-in Agent]'},
      \ {'word': '@general-purpose', 'abbr': 'general-purpose', 'menu': '[Built-in Agent]'},
      \ {'word': '@Plan',            'abbr': 'Plan',            'menu': '[Built-in Agent]'},
      \ {'word': '@statusline-setup','abbr': 'statusline-setup','menu': '[Built-in Agent]'},
      \ ]

" Built-ins plus the project-level and user-level custom commands and agents.
function! claude#provider#claude#completion(cwd) abort
  let l:cmds = copy(s:SLASH_COMMANDS)
  for l:f in glob(a:cwd . '/.claude/commands/*.md', 0, 1)
        \ + glob(expand('~') . '/.claude/commands/*.md', 0, 1)
    call add(l:cmds, {'word': '/' . fnamemodify(l:f, ':t:r'),
          \ 'menu': 'Custom command'})
  endfor

  let l:agents = copy(s:AGENTS)
  for l:f in glob(a:cwd . '/.claude/agents/*.md', 0, 1)
        \ + glob(expand('~') . '/.claude/agents/*.md', 0, 1)
    call add(l:agents, {
          \ 'word': '@' . fnamemodify(l:f, ':t:r'),
          \ 'abbr': fnamemodify(l:f, ':t:r'),
          \ 'menu': '[Agent]',
          \ })
  endfor

  return {'commands': l:cmds, 'agents': l:agents}
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

" Forget the --session-id/--name probe's answer.
function! claude#provider#claude#_reset() abort
  unlet! s:flags_ok
  let s:warned = {}
endfunction
