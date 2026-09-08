" ── input completion ─────────────────────────────────────────────────────────

" Built-in slash commands — base list, always available once Claude starts.
let s:slash_commands_base = [
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

let s:agents_base = [
      \ {'word': '@claude',          'abbr': 'claude',          'menu': '[Built-in Agent]'},
      \ {'word': '@Explore',         'abbr': 'Explore',         'menu': '[Built-in Agent]'},
      \ {'word': '@general-purpose', 'abbr': 'general-purpose', 'menu': '[Built-in Agent]'},
      \ {'word': '@Plan',            'abbr': 'Plan',            'menu': '[Built-in Agent]'},
      \ {'word': '@statusline-setup','abbr': 'statusline-setup','menu': '[Built-in Agent]'},
      \ ]

" Completion data belongs to a session: each Claude process sees its own
" project commands and agents. s:last_* holds the most recently collected set
" and is used when no single session can be resolved — before the first
" session exists, or while several are running.
let s:last_commands = []
let s:last_agents   = []

function! s:get_session_commands() abort
  let l:rec = claude#session#get(claude#session#current())
  return !empty(l:rec) && !empty(l:rec.commands)
        \ ? l:rec.commands : s:last_commands
endfunction

function! s:get_session_agents() abort
  let l:rec = claude#session#get(claude#session#current())
  return !empty(l:rec) && !empty(l:rec.agents)
        \ ? l:rec.agents : s:last_agents
endfunction

" Collect slash commands and agents when a Claude instance starts. Called
" from claude#session#new()/resume() with the session id — never from the
" input panel. Without an id the data is only cached as the fallback set.
function! claude#input#collect_data(...) abort
  " Slash commands: built-ins + project-level + user-level custom commands.
  let l:cmds = copy(s:slash_commands_base)
  for l:f in glob(getcwd() . '/.claude/commands/*.md', 0, 1)
        \ + glob(expand('~') . '/.claude/commands/*.md', 0, 1)
    call add(l:cmds, {'word': '/' . fnamemodify(l:f, ':t:r'), 'menu': 'Custom command'})
  endfor

  " Agents: built-ins + project-level + user-level.
  let l:agents = copy(s:agents_base)
  for l:f in glob(getcwd() . '/.claude/agents/*.md', 0, 1)
        \ + glob(expand('~') . '/.claude/agents/*.md', 0, 1)
    call add(l:agents, {
          \ 'word': '@' . fnamemodify(l:f, ':t:r'),
          \ 'abbr': fnamemodify(l:f, ':t:r'),
          \ 'menu': '[Agent]',
          \ })
  endfor

  let s:last_commands = l:cmds
  let s:last_agents   = l:agents

  let l:id = a:0 > 0 ? a:1 : ''
  if !empty(l:id) && claude#session#exists(l:id)
    let l:rec = claude#session#get(l:id)
    let l:rec.commands = l:cmds
    let l:rec.agents   = l:agents
  endif
endfunction

" Complete slash commands (/) and file references (@) in the input buffer.
" Registered as completefunc; auto-triggered by / and @ insert mappings.
function! claude#input#complete(findstart, base) abort
  if a:findstart
    let l:line = getline('.')
    let l:i    = col('.') - 1
    while l:i > 0
      let l:ch = l:line[l:i - 1]
      if l:ch ==# '@'
        return l:i - 1
      endif
      if l:ch =~# '\s'
        break
      endif
      let l:i -= 1
    endwhile
    " No @ found — only treat / as a command trigger when it starts the word.
    return (l:i < col('.') - 1 && l:line[l:i] ==# '/') ? l:i : -3
  endif

  if a:base[:0] ==# '/'
    let l:typed = a:base[1:]
    return filter(copy(s:get_session_commands()),
          \ {_, c -> c.word[1:] =~# '^' . escape(l:typed, '\^$.*[]~')})
  elseif a:base[:0] ==# '@'
    let l:prefix = a:base[1:]
    let l:slash  = strridx(l:prefix, '/')

    " Agent completions (only when Claude is running; empty list otherwise).
    let l:pat    = '^' . escape(l:prefix, '\^$.*[]~')
    let l:agents = filter(copy(s:get_session_agents()),
          \ {_, a -> a.abbr =~# l:pat})

    " Use rg to list files (fast, honours .gitignore). No rg = no file completions.
    if executable('rg')
      if !exists('s:rg_cache_dir') || s:rg_cache_dir !=# getcwd()
        let s:rg_cache_dir   = getcwd()
        let s:rg_cache_files = systemlist('rg --files --color=never 2>/dev/null')
      endif
      if empty(l:prefix)
        let l:items = copy(s:rg_cache_files)
      else
        let l:esc   = escape(l:prefix, '\^$.*[]~')
        if l:slash < 0
          " No separator — match path-prefix or bare filename prefix.
          let l:items = filter(copy(s:rg_cache_files),
                \ {_, f -> f =~# '^' . l:esc
                \       || fnamemodify(f, ':t') =~# '^' . l:esc})
        else
          " Has separator — match files whose path starts with the typed prefix.
          let l:items = filter(copy(s:rg_cache_files),
                \ {_, f -> f =~# '^' . l:esc})
        endif
      endif
    else
      let l:items = []
    endif
    let l:items = uniq(sort(l:items))
    " equal:1 bypasses Vim's word-prefix re-filter so basename-matched items
    " (e.g. @doc/claude.txt for base @cla) are not dropped. The TextChangedI/P
    " autocmd in s:input_split re-triggers C-x C-u on each keystroke so the
    " function itself always runs with the current base and narrows correctly.
    let l:files = map(l:items, {_, f -> {
          \ 'word': '@' . f,
          \ 'abbr': f . (isdirectory(f) ? '/' : ''),
          \ 'menu': isdirectory(f) ? '[dir]' : '[file]',
          \ 'equal': 1,
          \ }})
    return l:agents + l:files
  endif
  return []
endfunction

" ── input window ─────────────────────────────────────────────────────────────
"
" State is tab-local (t:) so each tab has an independent input buffer and
" draft. t:claude_input_bufnr — bufnr of the open split, -1 when none.
"        t:claude_input_saved  — draft lines preserved across toggle-off.

" Open or toggle the input window. If it is already visible, close it and save
" the current text as a draft; the draft is restored on the next open.
function! claude#input#open() abort
  let l:bufnr = get(t:, 'claude_input_bufnr', -1)
  if l:bufnr != -1 && bufexists(l:bufnr)
    call claude#input#cancel()
  else
    call s:input_split()
  endif
endfunction

" Refresh the @-file popup via complete() — no "searching" blink on every
" keystroke, unlike feedkeys(C-x C-u) which goes through completefunc.
function! s:refresh_at_complete() abort
  let l:line = getline('.')
  let l:i    = col('.') - 1
  while l:i > 0
    let l:ch = l:line[l:i - 1]
    if l:ch ==# '@'
      let l:base  = '@' . l:line[l:i : col('.') - 2]
      let l:items = claude#input#complete(0, l:base)
      call complete(l:i, l:items)
      return
    endif
    if l:ch =~# '\s' | return | endif
    let l:i -= 1
  endwhile
endfunction

function! s:input_split() abort
  let l:saved   = get(t:, 'claude_input_saved', [])
  let l:tmpfile = getcwd() . '/.' . fnamemodify(tempname(), ':t') . '.md'
  call writefile(l:saved, l:tmpfile)

  execute 'botright 10split ' . fnameescape(l:tmpfile)
  setlocal noswapfile nobuflisted bufhidden=wipe
  setlocal statusline=Claude\ Input\ ——\ <C-s>\ send,\ <C-c>\ hide

  let t:claude_input_bufnr = bufnr('%')
  let b:claude_tmpfile      = l:tmpfile

  " Always delete the temp file when the buffer is wiped, regardless of
  " whether it's closed by submit, cancel, or bufhidden=wipe.
  execute 'autocmd BufWipeout <buffer> call delete(' . string(l:tmpfile) . ')'

  if !empty(l:saved)
    execute len(l:saved)
  endif

  nnoremap <buffer> <silent> <C-s> :call claude#input#submit()<CR>
  inoremap <buffer> <silent> <C-s> <Esc>:call claude#input#submit()<CR>
  " Hiding is on CTRL-C, not <Esc>: the window opens in insert mode, so an
  " <Esc> mapping here would make the first press leave insert and the second
  " silently close the window.
  nnoremap <buffer> <silent> <C-c> :call <SID>input_split_save_and_close()<CR>
  " Vim's own CTRL-C leaves insert mode without firing InsertLeave, which
  " would strand 'completeopt' on the value InsertEnter set below. Going out
  " through <Esc> keeps that pair balanced; the second press then hides.
  inoremap <buffer> <C-c> <Esc>
  nnoremap <buffer> <silent> q     :call claude#input#cancel()<CR>

  setlocal completefunc=claude#input#complete
  inoremap <buffer> <silent> /      /<C-x><C-u>
  inoremap <buffer> <silent> @      @<C-x><C-u>
  inoremap <buffer> <expr>   <Esc>  pumvisible() ? '<C-e>' : '<Esc>'
  inoremap <buffer> <expr>   <Down> pumvisible() ? '<C-n>' : '<Down>'
  inoremap <buffer> <expr>   <Up>   pumvisible() ? '<C-p>' : '<Up>'
  inoremap <buffer> <expr>   <CR>   pumvisible() ? '<C-y>' : '<CR>'
  autocmd InsertEnter <buffer>
        \ let b:_copt = &completeopt | set completeopt=menuone,noselect,noinsert
  autocmd InsertLeave <buffer>
        \ if exists('b:_copt') | let &completeopt = b:_copt | unlet b:_copt | endif
  " TextChangedP fires while popup is visible; TextChangedI when it's not (e.g.
  " after Vim's word-prefix filter closes it). Together they re-trigger C-x C-u
  " on each keystroke so completefunc always gets the updated base.
  autocmd TextChangedI,TextChangedP <buffer> call s:refresh_at_complete()

  startinsert!
endfunction

" Toggle-off: save split content as draft then close.
function! s:input_split_save_and_close() abort
  let l:bufnr = get(t:, 'claude_input_bufnr', -1)
  let l:lines = getbufline(l:bufnr, 1, '$')
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  let t:claude_input_saved = l:lines
  let t:claude_input_bufnr = -1
  execute 'bwipeout! ' . l:bufnr
  " BufWipeout autocmd handles temp file deletion.
endfunction

" Send: collect content, close, send to Claude, clear draft.
function! claude#input#submit() abort
  let l:lines = getline(1, '$')
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  let t:claude_input_bufnr = -1
  let t:claude_input_saved = []
  bwipeout!
  " BufWipeout autocmd handles temp file deletion.
  if !empty(l:lines)
    call claude#_send_input(join(l:lines, "\n"))
  endif
endfunction

" Cancel: discard the draft and close.
function! claude#input#cancel() abort
  let t:claude_input_bufnr = -1
  let t:claude_input_saved = []
  bwipeout!
  " BufWipeout autocmd handles temp file deletion.
endfunction
