" ── the Pi provider ──────────────────────────────────────────────────────────
"
" Pi (https://github.com/earendil-works/pi), driven the same way Claude is: one
" terminal per session, an id this plugin chooses, and a conversation on disk
" the panel reads rows from.
"
" Two things about Pi shape everything here.
"
" --session-id is both halves of the lifecycle: it opens the session when the
" project already has that id and creates it with that id when it does not, so
" spawning and resuming are the same argument vector. It cannot be combined
" with --session, --continue or --resume, and none of them are ever passed.
"
" A conversation is <timestamp>_<id>.jsonl, so the filename is not the id and
" nothing may build a path by concatenating one. The directory is the cwd with
" only slashes, backslashes and colons replaced, wrapped in a pair of dashes —
" dots and underscores survive, which is the opposite of Claude's rule.

" Where Pi keeps conversations, before g:claude_providers.pi.sessions_root.
let s:ROOT = '~/.pi/agent/sessions'

" How many lines of a conversation are read to place and label it. More than
" Claude's 60: the display name is appended as the conversation goes on, and
" --name puts one near the head but a rename inside the TUI does not.
let s:SCAN_LINES = 200

function! claude#provider#pi#spec() abort
  return {
        \ 'name':        'pi',
        \ 'label':       'Pi',
        \ 'cmd':         'pi',
        \ 'models':      [],
        \ 'working_pat': 'to interrupt',
        \ 'waiting_pat': '\%(^\|\n\)\s*❯\=\s*1\.\s\|(y/n)',
        \ 'caps':        {'preassign_id': 1, 'name_flag': 1},
        \ }
endfunction

" ── launching ────────────────────────────────────────────────────────────────

" {spec} is {'id', 'name', 'resume'}. 'resume' is ignored: --session-id says
" "this session, whether or not it exists yet", which is what both callers
" mean. A List, never a string — see claude#provider#claude#argv().
function! claude#provider#pi#argv(spec) abort
  let l:me   = claude#provider#get('pi')
  let l:argv = split(get(l:me, 'cmd', 'pi'))
  call extend(l:argv, ['--session-id', a:spec.id])
  if !empty(get(a:spec, 'name', ''))
    call extend(l:argv, ['--name', a:spec.name])
  endif
  if !empty(get(l:me, 'model', ''))
    call extend(l:argv, ['--model', l:me.model])
  endif
  if !empty(get(l:me, 'sessions_root', ''))
    " Conversations are kept somewhere other than ~/.pi/agent/sessions, so the
    " CLI has to be told as well — it takes the per-project directory, which is
    " what session_dir() builds.
    call extend(l:argv, ['--session-dir', claude#provider#pi#session_dir(
          \ get(a:spec, 'cwd', getcwd()))])
  endif
  return l:argv
endfunction

" What :ClaudeModel sends. With no g:claude_providers.pi.models configured the
" plugin has no list to offer and sends a bare /model, which hands over to Pi's
" own model selector; with a list, an exact id switches without a prompt.
function! claude#provider#pi#model_text(model) abort
  return empty(a:model) ? '/model' : '/model ' . a:model
endfunction

" ── conversations on disk ────────────────────────────────────────────────────

" ~/.pi/agent/sessions/--Users-me-project--/, per Pi's own encoding:
"   `--${cwd.replace(/^[/\\]/,'').replace(/[/\\:]/g,'-')}--`
" Only separators are replaced. A dot or an underscore in the path is kept, so
" this must never be folded together with claude#session#project_dir(), which
" replaces every character that is not a letter or a digit.
function! claude#provider#pi#session_dir(cwd) abort
  let l:root = get(claude#provider#get('pi'), 'sessions_root', s:ROOT)
  let l:path = substitute(a:cwd, '[/\\]\+$', '', '')
  let l:path = substitute(l:path, '^[/\\]', '', '')
  return expand(l:root) . '/--' . substitute(l:path, '[/\\:]', '-', 'g') . '--'
endfunction

" The id of a conversation file: everything after the timestamp. The timestamp
" carries no underscore, so the last one is the separator.
function! s:id_of(path) abort
  return matchstr(fnamemodify(a:path, ':t:r'), '.*_\zs.*$')
endfunction

" The file holding {id}'s conversation, or '' when Pi has none. Found by glob
" because the name starts with the time the session was created, which is not
" something the plugin knows.
function! claude#provider#pi#transcript_path(id, cwd) abort
  if empty(a:cwd) || empty(a:id)
    return ''
  endif
  let l:hits = glob(claude#provider#pi#session_dir(a:cwd)
        \ . '/*_' . a:id . '.jsonl', 0, 1)
  return empty(l:hits) ? '' : l:hits[0]
endfunction

" Every session id Pi already has on disk for {cwd}, as a dict.
function! claude#provider#pi#ids(cwd) abort
  let l:dir = claude#provider#pi#session_dir(a:cwd)
  if !isdirectory(l:dir)
    return {}
  endif
  let l:seen = {}
  for l:path in glob(l:dir . '/*.jsonl', 0, 1)
    let l:id = s:id_of(l:path)
    if !empty(l:id)
      let l:seen[l:id] = 1
    endif
  endfor
  return l:seen
endfunction

function! s:trim_snippet(text) abort
  let l:s = substitute(a:text, '[\r\n]\+', ' ', 'g')
  let l:s = substitute(l:s, '^\s\+\|\s\+$', '', 'g')
  return strcharpart(l:s, 0, 60)
endfunction

" First text block of a message entry written by the user.
function! s:message_text(entry) abort
  let l:msg = get(a:entry, 'message', {})
  if type(l:msg) != v:t_dict || get(l:msg, 'role', '') !=# 'user'
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

" Read enough of a conversation to place and label it: the header line says
" where it ran, the first user message is what it is called when nothing else
" names it, and the last session_info in the window is the name Pi shows.
function! claude#provider#pi#scan(path) abort
  let l:rec = {
        \ 'id':      s:id_of(a:path),
        \ 'path':    a:path,
        \ 'cwd':     '',
        \ 'branch':  '',
        \ 'name':    '',
        \ 'snippet': '',
        \ 'created': getftime(a:path),
        \ }
  for l:line in readfile(a:path, '', s:SCAN_LINES)
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
    let l:type = get(l:entry, 'type', '')
    if l:type ==# 'session'
      if !empty(get(l:entry, 'id', ''))
        let l:rec.id = l:entry.id
      endif
      let l:rec.cwd = get(l:entry, 'cwd', l:rec.cwd)
    elseif l:type ==# 'session_info'
      " Latest wins, and an empty name clears the title — the same rule Pi
      " reads these by.
      let l:rec.name = s:trim_snippet(get(l:entry, 'name', ''))
    elseif l:type ==# 'message' && empty(l:rec.snippet)
      let l:rec.snippet = s:message_text(l:entry)
    endif
  endfor
  return l:rec
endfunction

" Every conversation Pi holds for the directories in {cwds}: the one Vim is in,
" plus every workspace of this repository. Newest first, capped across the
" project rather than per directory.
function! claude#provider#pi#sessions(cwds) abort
  let l:limit = get(g:, 'claude_panel_closed_limit', 10)
  if l:limit <= 0
    return []
  endif
  let l:seen  = {}
  let l:paths = []
  for l:cwd in a:cwds
    let l:dir = claude#provider#pi#session_dir(l:cwd)
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
  let l:out = []
  for l:path in l:paths[0 : l:limit - 1]
    let l:scan = claude#provider#pi#scan(l:path)
    " A file with no header is not a conversation — a partial write, or
    " something else that happens to end in .jsonl.
    if !empty(l:scan.id) && !empty(l:scan.cwd)
      call add(l:out, l:scan)
    endif
  endfor
  return l:out
endfunction

" ── completion ───────────────────────────────────────────────────────────────

" Pi's built-in slash commands.
let s:SLASH_COMMANDS = [
      \ {'word': '/changelog', 'menu': 'Show the changelog'},
      \ {'word': '/clone',     'menu': 'Clone the session'},
      \ {'word': '/compact',   'menu': 'Compact conversation to save tokens'},
      \ {'word': '/copy',      'menu': 'Copy the last message'},
      \ {'word': '/debug',     'menu': 'Debug information'},
      \ {'word': '/export',    'menu': 'Export the session to HTML'},
      \ {'word': '/fork',      'menu': 'Fork the session'},
      \ {'word': '/hotkeys',   'menu': 'Show hotkeys'},
      \ {'word': '/import',    'menu': 'Import a session'},
      \ {'word': '/login',     'menu': 'Log in to a provider'},
      \ {'word': '/logout',    'menu': 'Log out of a provider'},
      \ {'word': '/model',     'menu': 'Switch model'},
      \ {'word': '/name',      'menu': 'Name this session'},
      \ {'word': '/new',       'menu': 'Start a new session'},
      \ {'word': '/quit',      'menu': 'Quit Pi'},
      \ {'word': '/reload',    'menu': 'Reload extensions and settings'},
      \ {'word': '/resume',    'menu': 'Resume a session'},
      \ {'word': '/session',   'menu': 'Show session information'},
      \ {'word': '/settings',  'menu': 'Open settings'},
      \ {'word': '/share',     'menu': 'Share the session'},
      \ {'word': '/tree',      'menu': 'Show the conversation tree'},
      \ {'word': '/trust',     'menu': 'Trust project-local files'},
      \ ]

" Built-ins plus the prompt templates Pi loads: .md files in <cwd>/.pi/prompts
" and ~/.pi/agent/prompts, neither scanned recursively. Pi has no @agent
" concept, so the agent list is empty and @ completes files alone.
function! claude#provider#pi#completion(cwd) abort
  let l:cmds = copy(s:SLASH_COMMANDS)
  let l:root = fnamemodify(expand(
        \ get(claude#provider#get('pi'), 'sessions_root', s:ROOT)), ':h')
  for l:f in glob(a:cwd . '/.pi/prompts/*.md', 0, 1)
        \ + glob(l:root . '/prompts/*.md', 0, 1)
    call add(l:cmds, {'word': '/' . fnamemodify(l:f, ':t:r'),
          \ 'menu': 'Prompt template'})
  endfor
  return {'commands': l:cmds, 'agents': []}
endfunction
