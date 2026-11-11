" ── finding in a project ─────────────────────────────────────────────────────
"
" :ClaudeProjectFiles and :ClaudeProjectRg — fzf.vim's file finder and a
" ripgrep search, each rooted at a project's worktree, asked for first. With
" nothing to choose between (outside git, or the root checkout alone) the
" question is skipped and the search runs where it always would have.
"
" fzf.vim is not a dependency of the plugin: every fzf# call is guarded, and
" without it the commands say so rather than erroring.

" The projects worth asking about, as [[label, path], ...], root first.
" Empty when there is nothing to choose between.
function! s:choices() abort
  let l:root = claude#room#project_root()
  if empty(l:root)
    return []
  endif
  let l:recs = filter(claude#room#list(l:root),
        \ {_, r -> !get(r, 'missing', 0) && isdirectory(r.path)})
  if len(l:recs) < 2
    return []
  endif
  let l:cur = get(claude#room#current(), 'id', 'root')
  return map(l:recs, {_, r -> [(r.id ==# l:cur ? '* ' : '  ')
        \ . claude#room#label(r), r.path]})
endfunction

" Where to search when nothing is asked: the only project, else Vim's cwd.
function! s:fallback_dir() abort
  let l:root = claude#room#project_root()
  return empty(l:root) ? getcwd() : l:root
endfunction

function! s:warn(msg) abort
  echohl WarningMsg
  echomsg 'claude.vim: ' . a:msg
  echohl None
endfunction

" Whether {name} can be called. An autoload function only exists once its
" script has been sourced — fzf.vim's are not, until something first uses
" them — so its script is looked for on 'runtimepath' before giving up.
function! s:callable(name) abort
  if !exists('*' . a:name) && a:name =~# '#'
    execute 'silent! runtime autoload/'
          \ . substitute(matchstr(a:name, '.*\ze#'), '#', '/', 'g') . '.vim'
  endif
  return exists('*' . a:name)
endfunction

function! s:has_fzf() abort
  return s:callable('fzf#run') && s:callable('fzf#wrap')
endfunction

" Ask which project, then call {Search} with its worktree. fzf when it is
" there, inputlist() otherwise — or when g:claude_no_popup asks for it, as the
" project picker does.
function! s:with_project(prompt, Search) abort
  let l:choices = s:choices()
  if empty(l:choices)
    call a:Search(s:fallback_dir())
    return
  endif

  if s:has_fzf() && !get(g:, 'claude_no_popup', 0)
    let l:lines = map(copy(l:choices), {_, c -> c[0] . "\t" . c[1]})
    call fzf#run(fzf#wrap({
          \ 'source':  l:lines,
          \ 'sink':    {line -> a:Search(split(line, "\t")[-1])},
          \ 'options': ['--prompt=' . a:prompt . '> ', '--delimiter=\t',
          \             '--with-nth=1', '--no-sort'],
          \ }))
    return
  endif

  let l:menu = [a:prompt . ' in which project?']
  let l:i = 1
  for [l:label, l:_] in l:choices
    call add(l:menu, printf('%d. %s', l:i, l:label))
    let l:i += 1
  endfor
  try
    let l:pick = inputlist(l:menu)
  catch /^Vim:Interrupt$/
    let l:pick = 0
  endtry
  redraw
  if l:pick >= 1 && l:pick <= len(l:choices)
    call a:Search(l:choices[l:pick - 1][1])
  endif
endfunction

" ── the searches ─────────────────────────────────────────────────────────────

function! s:files_in(dir, bang) abort
  if !s:callable('fzf#vim#files')
    call s:warn('fzf.vim is not installed; :ClaudeProjectFiles needs it')
    return
  endif
  if s:callable('fzf#vim#with_preview')
    call fzf#vim#files(a:dir, fzf#vim#with_preview(), a:bang)
  else
    call fzf#vim#files(a:dir, {}, a:bang)
  endif
endfunction

" The ripgrep command and spec of the vimrc's own :Rg, rooted at {dir}: fzf
" runs the search and its sink from there, so the relative paths rg prints
" open in the right checkout.
function! s:grep_in(dir, query, bang) abort
  if !s:callable('fzf#vim#grep')
    call s:warn('fzf.vim is not installed; :ClaudeProjectRg needs it')
    return
  endif
  call fzf#vim#grep('rg --column --line-number --no-heading --color=always'
        \ . ' --smart-case ' . shellescape(a:query),
        \ {'dir': a:dir, 'options': '--delimiter : --nth 4..'}, a:bang)
endfunction

" :ClaudeProjectFiles[!] — find a file in a project.
function! claude#find#files(bang) abort
  call s:with_project('Files', {dir -> s:files_in(dir, a:bang)})
endfunction

" :ClaudeProjectRg[!] [query] — search a project's contents.
function! claude#find#grep(query, bang) abort
  call s:with_project('Rg', {dir -> s:grep_in(dir, a:query, a:bang)})
endfunction
