" ── git diff file tree ───────────────────────────────────────────────────────
"
" A sidebar listing every file that differs from the base branch, as a
" directory hierarchy, grouped per worktree. Committed and uncommitted changes
" appear together in one view, distinguished by colour and by their status
" letter.
"
" Replaces the flat NERDTree-bookmark lists that :GitChangedFiles and
" :GitUncommittedFiles produced.
"
" Git is never run on a redraw — only on the triggers in s:invalidate()'s
" callers — because each invocation costs ~22ms of process startup and a full
" refresh is 1 + 3×worktrees of them.

let s:bufnr      = -1
let s:prev_winid = -1
let s:collapsed  = {}    " fold key -> 1 while that node is shut
let s:nodes      = []    " parallel to the rendered lines
let s:cache      = {}    " '<worktree>|<base>' -> list of records
let s:base_over  = ''    " set by :ClaudeDiffBase
let s:base_cache = ''
let s:filter     = ''
let s:show_help  = 0

call claude#sidebar#register({
      \ 'name':     'difftree',
      \ 'priority': 20,
      \ 'Winid':    function('claude#difftree#winid'),
      \ 'Height':   {-> get(g:, 'claude_difftree_height', 15)},
      \ })

" ── git ──────────────────────────────────────────────────────────────────────

" Run git in {dir}. core.quotepath=false keeps non-ASCII paths readable
" instead of being octal-escaped by --name-status.
function! s:git(dir, args) abort
  if empty(a:dir)
    return []
  endif
  let l:out = systemlist('git -c core.quotepath=false -C '
        \ . shellescape(a:dir) . ' ' . a:args . ' 2>/dev/null')
  return v:shell_error == 0 ? l:out : []
endfunction

function! s:repo_root() abort
  let l:out = s:git(getcwd(), 'rev-parse --show-toplevel')
  return empty(l:out) ? '' : l:out[0]
endfunction

function! claude#difftree#is_repo() abort
  return !empty(s:repo_root())
endfunction

" Base branch, resolved once per Vim session unless overridden.
"
" An explicit :ClaudeDiffBase wins over the configured default: the command is
" a deliberate act, the global is only a starting point.
function! claude#difftree#base() abort
  if !empty(s:base_over)
    return s:base_over
  endif
  let l:configured = get(g:, 'claude_difftree_base', '')
  if !empty(l:configured)
    return l:configured
  endif
  if empty(s:base_cache)
    let s:base_cache = s:detect_base()
  endif
  return s:base_cache
endfunction

function! s:detect_base() abort
  let l:root = s:repo_root()
  if empty(l:root)
    return ''
  endif
  let l:head = s:git(l:root, 'symbolic-ref --short refs/remotes/origin/HEAD')
  if !empty(l:head)
    return substitute(l:head[0], '^origin/', '', '')
  endif
  for l:cand in ['main', 'master']
    if !empty(s:git(l:root, 'rev-parse --verify --quiet ' . l:cand))
      return l:cand
    endif
  endfor
  return ''
endfunction

function! claude#difftree#set_base(branch) abort
  let s:base_over = a:branch
  call claude#difftree#refresh()
endfunction

" Completion for :ClaudeDiffBase.
function! claude#difftree#complete_branch(lead, line, pos) abort
  let l:root = s:repo_root()
  if empty(l:root)
    return []
  endif
  let l:names = s:git(l:root,
        \ "for-each-ref --format='%(refname:short)' refs/heads refs/remotes")
  return filter(l:names, {_, n -> n =~# '^' . escape(a:lead, '\.*$^~[]')})
endfunction

" Worktrees, parsed from the stable porcelain format — plain `git worktree
" list` output is not meant to be machine-read.
function! s:worktrees() abort
  let l:root = s:repo_root()
  if empty(l:root)
    return []
  endif
  let l:out  = []
  let l:path = ''
  for l:line in s:git(l:root, 'worktree list --porcelain')
    if l:line =~# '^worktree '
      let l:path = l:line[9:]
    elseif l:line =~# '^branch '
      call add(l:out, {'path': l:path,
            \ 'branch': substitute(l:line[7:], '^refs/heads/', '', '')})
    elseif l:line ==# 'detached'
      call add(l:out, {'path': l:path, 'branch': '(detached)'})
    endif
  endfor
  return l:out
endfunction

" '<letter>\t<path>', or for a rename '<R100>\t<old>\t<new>'.
function! s:parse_status(line) abort
  let l:parts = split(a:line, "\t")
  if len(l:parts) < 2
    return ['', '']
  endif
  return [l:parts[0][0], l:parts[-1]]
endfunction

function! s:blank(path, wt) abort
  return {'path': a:path, 'committed': '', 'dirty': '',
        \ 'worktree': a:wt.path, 'branch': a:wt.branch}
endfunction

" Every changed file in {wt}, cached per (worktree, base).
function! s:files_for(wt) abort
  let l:base = claude#difftree#base()
  let l:key  = a:wt.path . '|' . l:base
  if has_key(s:cache, l:key)
    return s:cache[l:key]
  endif

  let l:files = {}

  if !empty(l:base)
    for l:line in s:git(a:wt.path, 'diff --name-status '
          \ . shellescape(l:base) . '...HEAD')
      let [l:st, l:path] = s:parse_status(l:line)
      if empty(l:path)
        continue
      endif
      let l:rec = get(l:files, l:path, s:blank(l:path, a:wt))
      let l:rec.committed = l:st
      let l:files[l:path] = l:rec
    endfor
  endif

  for l:line in s:git(a:wt.path, 'diff --name-status HEAD')
    let [l:st, l:path] = s:parse_status(l:line)
    if empty(l:path)
      continue
    endif
    let l:rec = get(l:files, l:path, s:blank(l:path, a:wt))
    let l:rec.dirty = l:st
    let l:files[l:path] = l:rec
  endfor

  if get(g:, 'claude_difftree_show_untracked', 1)
    for l:path in s:git(a:wt.path, 'ls-files --others --exclude-standard')
      if empty(l:path)
        continue
      endif
      let l:rec = get(l:files, l:path, s:blank(l:path, a:wt))
      let l:rec.dirty = '?'
      let l:files[l:path] = l:rec
    endfor
  endif

  let l:list = values(l:files)
  call sort(l:list, {a, b -> a.path ==# b.path ? 0 : (a.path < b.path ? -1 : 1)})
  let s:cache[l:key] = l:list
  return l:list
endfunction

" 'committed', 'uncommitted' or 'both'.
function! claude#difftree#status(rec) abort
  if !empty(a:rec.committed) && !empty(a:rec.dirty)
    return 'both'
  endif
  return empty(a:rec.dirty) ? 'committed' : 'uncommitted'
endfunction

" ── status indicators ────────────────────────────────────────────────────────
"
" The glyphs come from nerdtree-git-plugin, so the diff tree and NERDTree —
" which sit in the same sidebar column — describe git state in one alphabet.
"
" Each row carries two indicator columns, because this tree has an axis that
" plugin has no concept of: the first is what the branch did to the file
" relative to the base, the second what the working tree has done since. Both
" are drawn from the same vocabulary, so position is what separates them.
"
" Its status keys, and the default UTF-8 glyphs:
"   Modified ✹   Staged ✚   Untracked ✭   Renamed ➜
"   Unmerged ═   Deleted ✖   Dirty ✗   Ignored !   Clean ✔   Unknown 𝒳

" A copy of nerdtree-git-plugin's three maps, used only when the plugin is not
" installed. Kept as codepoints exactly as gitstatus.vim writes them.
function! s:embedded_map() abort
  if claude#sidebar#ascii()
    return {'Modified': '*', 'Staged': '+', 'Untracked': '!',
          \ 'Renamed': 'R', 'Unmerged': '=', 'Deleted': 'D',
          \ 'Dirty': 'X', 'Ignored': '?', 'Clean': 'C', 'Unknown': 'E'}
  endif
  if get(g:, 'NERDTreeGitStatusUseNerdFonts', 0)
    return {'Modified': nr2char(61545), 'Staged': nr2char(61543),
          \ 'Untracked': nr2char(61736), 'Renamed': nr2char(62804),
          \ 'Unmerged': nr2char(61556), 'Deleted': nr2char(63167),
          \ 'Dirty': nr2char(61453), 'Ignored': nr2char(61738),
          \ 'Clean': nr2char(61452), 'Unknown': nr2char(61832)}
  endif
  return {'Modified': nr2char(10041), 'Staged': nr2char(10010),
        \ 'Untracked': nr2char(10029), 'Renamed': nr2char(10140),
        \ 'Unmerged': nr2char(9552), 'Deleted': nr2char(10006),
        \ 'Dirty': nr2char(10007), 'Ignored': nr2char(33),
        \ 'Clean': nr2char(10004), 'Unknown': nr2char(120744)}
endfunction

" Glyph for a status key.
"
" nerdtree-git-plugin is asked first when it is installed, so the icons match
" exactly — including g:NERDTreeGitStatusUseNerdFonts and any
" g:NERDTreeGitStatusIndicatorMapCustom. The exception is the panel's own
" ASCII mode, which exists because the terminal cannot draw the glyphs at all.
function! claude#difftree#indicator(key) abort
  if !claude#sidebar#ascii() && exists('*gitstatus#getIndicator')
    try
      return gitstatus#getIndicator(a:key)
    catch
    endtry
  endif
  return get(s:embedded_map(), a:key, '?')
endfunction

" --name-status letters mapped with nerdtree-git-plugin's own precedence:
" an added-and-staged path is Staged, a copy is a Renamed (util.vim:153-176).
let s:letter_status = {
      \ 'A': 'Staged',   'M': 'Modified', 'D': 'Deleted',
      \ 'R': 'Renamed',  'C': 'Renamed',  'U': 'Unmerged',
      \ '?': 'Untracked',
      \ }

function! s:glyph(letter) abort
  if empty(a:letter)
    return ''
  endif
  return claude#difftree#indicator(get(s:letter_status, a:letter, 'Unknown'))
endfunction

" [branch-vs-base glyph, working-tree glyph]; either may be empty.
function! claude#difftree#marks(rec) abort
  return [s:glyph(a:rec.committed), s:glyph(a:rec.dirty)]
endfunction

" Every glyph that can appear in an indicator column, for the syntax patterns.
function! s:all_glyphs() abort
  let l:out = ''
  for l:key in values(s:letter_status)
    let l:g = claude#difftree#indicator(l:key)
    if stridx(l:out, l:g) < 0
      let l:out .= l:g
    endif
  endfor
  return l:out
endfunction

" Width of one indicator column: normally 1, more only if a custom map uses
" something wider.
function! s:col_width() abort
  let l:w = 1
  for l:key in values(s:letter_status)
    let l:w = max([l:w, strchars(claude#difftree#indicator(l:key))])
  endfor
  return l:w
endfunction

" Width of the whole bracketed field: "[x|y]".
function! s:field_width() abort
  return 2 * s:col_width() + 3
endfunction

" The bracketed indicator field for a row.
"
"   [+]     changed on the branch only
"   [ |*]   changed in the working tree only
"   [+|*]   both
"   (blank) neither
"
" The empty slot is kept when only the working tree changed, rather than
" collapsing to "[*]": a lone glyph could not say which of the two columns it
" came from, and the filename's colour depends on knowing whether there is
" uncommitted work. Everything is padded to one width so names stay aligned.
function! s:field(rec) abort
  let [l:c1, l:c2] = claude#difftree#marks(a:rec)
  let l:w = s:col_width()
  if empty(l:c1) && empty(l:c2)
    let l:text = ''
  elseif !empty(l:c2)
    let l:text = '[' . (empty(l:c1) ? repeat(' ', l:w) : l:c1) . '|' . l:c2 . ']'
  else
    let l:text = '[' . l:c1 . ']'
  endif
  return l:text . repeat(' ', s:field_width() - strchars(l:text))
endfunction

function! s:invalidate() abort
  let s:cache = {}
endfunction

" ── model ────────────────────────────────────────────────────────────────────

" Flat list of every changed file across every listed worktree.
function! claude#difftree#files() abort
  let l:base = claude#difftree#base()
  let l:out  = []
  for l:wt in s:worktrees()
    " A worktree sitting on the base branch diffs against itself: always empty.
    if l:wt.branch ==# l:base
      continue
    endif
    call extend(l:out, s:files_for(l:wt))
  endfor
  return l:out
endfunction

function! s:matches(path) abort
  if empty(s:filter)
    return v:true
  endif
  " Smart case: an all-lowercase filter ignores case.
  if s:filter ==# tolower(s:filter)
    return stridx(tolower(a:path), s:filter) >= 0
  endif
  return stridx(a:path, s:filter) >= 0
endfunction

function! s:new_dir(name) abort
  return {'name': a:name, 'dirs': [], 'index': {}, 'files': []}
endfunction

" Fold {files} into a directory tree, then collapse runs of single-child
" directories so `autoload/claude` is one node rather than two.
function! s:build_dirs(files) abort
  let l:root = s:new_dir('')
  for l:rec in a:files
    if !s:matches(l:rec.path)
      continue
    endif
    let l:node  = l:root
    let l:parts = split(l:rec.path, '/')
    for l:i in range(len(l:parts) - 1)
      let l:name = l:parts[l:i]
      if !has_key(l:node.index, l:name)
        let l:node.index[l:name] = len(l:node.dirs)
        call add(l:node.dirs, s:new_dir(l:name))
      endif
      let l:node = l:node.dirs[l:node.index[l:name]]
    endfor
    call add(l:node.files, l:rec)
  endfor
  if get(g:, 'claude_difftree_collapse_dirs', 1)
    call s:collapse(l:root)
  endif
  return l:root
endfunction

function! s:collapse(node) abort
  for l:dir in a:node.dirs
    call s:collapse(l:dir)
  endfor
  " A directory with one subdirectory and no files of its own is merged into
  " its child: two nodes carrying one piece of information become one.
  while len(a:node.dirs) == 1 && empty(a:node.files) && !empty(a:node.name)
    let l:only = a:node.dirs[0]
    let a:node.name  = a:node.name . '/' . l:only.name
    let a:node.dirs  = l:only.dirs
    let a:node.files = l:only.files
    let a:node.index = l:only.index
  endwhile
endfunction

" [{branch, path, root}] for every worktree with changes.
function! claude#difftree#tree() abort
  let l:base = claude#difftree#base()
  let l:out  = []
  for l:wt in s:worktrees()
    if l:wt.branch ==# l:base
      continue
    endif
    let l:files = s:files_for(l:wt)
    if empty(l:files)
      continue
    endif
    let l:root = s:build_dirs(l:files)
    if empty(l:root.dirs) && empty(l:root.files)
      continue           " everything filtered out
    endif
    call add(l:out, {'branch': l:wt.branch, 'path': l:wt.path, 'root': l:root})
  endfor
  return l:out
endfunction

" ── colours ──────────────────────────────────────────────────────────────────

" Tree furniture follows NERDTree; the status glyphs follow
" nerdtree-git-plugin, preferring its own groups when its syntax file has been
" sourced and otherwise the groups it links them to
" (after/syntax/nerdtree.vim:36-45).
"
" Two notes on that list: it names Unmerged twice, first Function then Label,
" the later winning — Label is used here. And it links Clean to `Method`,
" which is not a standard Vim highlight group; Clean is never rendered by this
" panel, so it is simply omitted rather than given an invented fallback.
let s:highlights = [
      \ ['ClaudeDiffHeader',      'NERDTreeCWD',              'Statement'],
      \ ['ClaudeDiffProject',     'NERDTreeCWD',              'Statement'],
      \ ['ClaudeDiffBranch',      'NERDTreeDir',              'Directory'],
      \ ['ClaudeDiffDir',         'NERDTreeDir',              'Directory'],
      \ ['ClaudeDiffMarker',      'NERDTreeClosable',         'Directory'],
      \ ['ClaudeDiffCommitted',   'NERDTreeFile',             'Normal'],
      \ ['ClaudeDiffUncommitted', 'NERDTreeFlags',            'Number'],
      \ ['ClaudeDiffModified',    'NERDTreeGitStatusModified',  'Special'],
      \ ['ClaudeDiffStaged',      'NERDTreeGitStatusStaged',    'Function'],
      \ ['ClaudeDiffUntracked',   'NERDTreeGitStatusUntracked', 'Comment'],
      \ ['ClaudeDiffRenamed',     'NERDTreeGitStatusRenamed',   'Title'],
      \ ['ClaudeDiffUnmerged',    'NERDTreeGitStatusUnmerged',  'Label'],
      \ ['ClaudeDiffDeleted',     'NERDTreeGitStatusDeleted',   'Operator'],
      \ ['ClaudeDiffField',       '',                         'Normal'],
      \ ['ClaudeDiffHelp',        'NERDTreeHelp',             'String'],
      \ ]

function! claude#difftree#_relink() abort
  call claude#sidebar#link_highlights(s:highlights)
endfunction

function! s:setup_syntax() abort
  silent! syntax clear
  let l:m = claude#sidebar#marker_class()

  execute 'syntax match ClaudeDiffProject /^' . l:m
        \ . ' .*$/ contains=ClaudeDiffMarker'
  execute 'syntax match ClaudeDiffBranch  /^  ' . l:m
        \ . ' .*$/ contains=ClaudeDiffMarker'
  execute 'syntax match ClaudeDiffDir     /^ \{4,}' . l:m
        \ . ' .*$/ contains=ClaudeDiffMarker'
  execute 'syntax match ClaudeDiffMarker  /' . l:m . '/ contained'

  " A file row is an indent, two indicator columns and a space, then the name.
  "
  " The columns are matched as one container with the glyphs `contained`
  " inside it, rather than as separate ^-anchored matches: a pattern anchored
  " to ^ is only ever tried at column 1, so of two such matches only the
  " earliest-starting one is ever applied and the second column would never be
  " highlighted. nerdtree-git-plugin solves it the same way, with
  " containedin=NERDTreeFlags.
  let l:g = escape(s:all_glyphs(), ']^\-')
  let l:w = s:col_width()
  let l:any  = '[' . l:g . ' ]\{' . l:w . '}'
  let l:some = '[' . l:g . ']\{' . l:w . '}'
  " "[x]" is shorter than the padded field, so a clean row has extra spaces
  " between the closing bracket and the name.
  let l:gap  = repeat(' ', s:field_width() - (l:w + 2) + 1)

  let l:groups = []
  for [l:key, l:group] in [
        \ ['Modified',  'ClaudeDiffModified'],
        \ ['Staged',    'ClaudeDiffStaged'],
        \ ['Untracked', 'ClaudeDiffUntracked'],
        \ ['Renamed',   'ClaudeDiffRenamed'],
        \ ['Unmerged',  'ClaudeDiffUnmerged'],
        \ ['Deleted',   'ClaudeDiffDeleted'],
        \ ]
    " A glyph is user-configurable and may contain regex metacharacters, so it
    " is escaped into a literal match.
    execute 'syntax match ' . l:group . ' /'
          \ . escape(claude#difftree#indicator(l:key), '/\.*$^~[]')
          \ . '/ contained'
    call add(l:groups, l:group)
  endfor
  let l:contains = 'contains=' . join(l:groups, ',')

  " The filename is coloured by whether the working-tree slot is filled, which
  " is what says the file still has uncommitted work in it. A separator in the
  " field is exactly what marks that case.
  execute 'syntax match ClaudeDiffField /^ \{2,}\[' . l:any . '|' . l:some
        \ . '\] / ' . l:contains . ' nextgroup=ClaudeDiffUncommitted'
  execute 'syntax match ClaudeDiffField /^ \{2,}\[' . l:some . '\]' . l:gap
        \ . '/ ' . l:contains . ' nextgroup=ClaudeDiffCommitted'
  syntax match ClaudeDiffCommitted   /\S.*$/ contained
  syntax match ClaudeDiffUncommitted /\S.*$/ contained

  syntax match ClaudeDiffHeader /\%1lGit Diff.*/
  syntax match ClaudeDiffHelp /^? help$/
  syntax match ClaudeDiffHelp /^ \S.*$/
endfunction

" ── rendering ────────────────────────────────────────────────────────────────

function! s:width() abort
  return get(g:, 'claude_difftree_width', 35)
endfunction

function! s:marker(key) abort
  return claude#sidebar#marker(!has_key(s:collapsed, a:key))
endfunction

" A directory is forced open while a filter is narrowing the tree, so matches
" are always visible without the user unfolding anything.
function! s:is_open(key) abort
  return !empty(s:filter) || !has_key(s:collapsed, a:key)
endfunction

function! s:node(kind, key, indent, label, payload) abort
  return {'kind': a:kind, 'key': a:key, 'indent': a:indent,
        \ 'label': a:label, 'payload': a:payload}
endfunction

function! s:add(lines, nodes, text, node) abort
  call add(a:lines, a:text)
  call add(a:nodes, a:node)
endfunction

function! s:emit_dir(dir, wtkey, prefix, indent, lines, nodes) abort
  for l:sub in a:dir.dirs
    let l:path = empty(a:prefix) ? l:sub.name : a:prefix . '/' . l:sub.name
    let l:key  = 'd:' . a:wtkey . '|' . l:path
    call s:add(a:lines, a:nodes,
          \ a:indent . s:marker(l:key) . ' '
          \ . claude#sidebar#fit(s:width(), a:indent, l:sub.name),
          \ s:node('dir', l:key, a:indent, l:sub.name, l:path))
    if s:is_open(l:key)
      call s:emit_dir(l:sub, a:wtkey, l:path, a:indent . '  ',
            \ a:lines, a:nodes)
    endif
  endfor
  for l:rec in a:dir.files
    let l:name  = fnamemodify(l:rec.path, ':t')
    let l:field = s:field(l:rec) . ' '
    call s:add(a:lines, a:nodes,
          \ a:indent . l:field
          \ . claude#sidebar#fit(s:width(), a:indent . l:field, l:name),
          \ s:node('file', '', a:indent, l:name, l:rec))
  endfor
endfunction

function! s:build() abort
  let l:lines = []
  let l:nodes = []
  let l:base  = claude#difftree#base()

  let l:title = 'Git Diff'
  let l:right = (empty(l:base) ? '(no base)' : l:base)
        \ . (empty(s:filter) ? '' : '  /' . s:filter)
  let l:pad = max([1, s:width() - strchars(l:title) - strchars(l:right) - 1])
  call s:add(l:lines, l:nodes, l:title . repeat(' ', l:pad) . l:right,
        \ s:node('header', '', '', l:title, ''))

  if s:show_help
    for l:h in [
          \ '',
          \ ' <CR>/o open   i split   s vsplit',
          \ ' t tab     R refresh  b base',
          \ ' / filter  <Esc> clear filter',
          \ ' <Space> fold   q hide   ? help',
          \ ]
      call s:add(l:lines, l:nodes, l:h, s:node('help', '', '', l:h, ''))
    endfor
  endif

  call s:add(l:lines, l:nodes, '', s:node('blank', '', '', '', ''))

  if !claude#difftree#is_repo()
    call s:add(l:lines, l:nodes, '  (not a git repository)',
          \ s:node('empty', '', '', '', ''))
    return [l:lines, l:nodes]
  endif
  if empty(l:base)
    call s:add(l:lines, l:nodes, '  (no base branch — press b to set one)',
          \ s:node('empty', '', '', '', ''))
    return [l:lines, l:nodes]
  endif

  let l:tree = claude#difftree#tree()
  if empty(l:tree)
    call s:add(l:lines, l:nodes,
          \ empty(s:filter)
          \   ? '  (no changes vs ' . l:base . ')'
          \   : '  (no files match /' . s:filter . ')',
          \ s:node('empty', '', '', '', ''))
    return [l:lines, l:nodes]
  endif

  let l:pkey = 'p:' . s:repo_root()
  call s:add(l:lines, l:nodes,
        \ s:marker(l:pkey) . ' ' . fnamemodify(s:repo_root(), ':t'),
        \ s:node('project', l:pkey, '', fnamemodify(s:repo_root(), ':t'), ''))
  if s:is_open(l:pkey)
    for l:wt in l:tree
      let l:bkey = 'b:' . l:wt.path
      call s:add(l:lines, l:nodes,
            \ '  ' . s:marker(l:bkey) . ' '
            \ . claude#sidebar#fit(s:width(), '  ', l:wt.branch),
            \ s:node('branch', l:bkey, '  ', l:wt.branch, l:wt.path))
      if s:is_open(l:bkey)
        call s:emit_dir(l:wt.root, l:wt.path, '', '    ', l:lines, l:nodes)
      endif
    endfor
  endif

  call s:add(l:lines, l:nodes, '', s:node('blank', '', '', '', ''))
  call s:add(l:lines, l:nodes, '? help', s:node('help', '', '', '', ''))
  return [l:lines, l:nodes]
endfunction

function! s:render() abort
  if s:bufnr == -1 || !bufexists(s:bufnr)
    return
  endif
  let [l:lines, l:nodes] = s:build()
  let l:win     = bufwinid(s:bufnr)
  let l:restore = (l:win != -1 && win_getid() == l:win) ? line('.') : 0

  call setbufvar(s:bufnr, '&modifiable', 1)
  silent! call deletebufline(s:bufnr, 1, '$')
  call setbufline(s:bufnr, 1, l:lines)
  call setbufvar(s:bufnr, '&modifiable', 0)
  let s:nodes = l:nodes

  if l:restore > 0
    call win_execute(l:win,
          \ 'call cursor(' . min([l:restore, len(l:lines)]) . ', 1)')
  endif
endfunction

" ── window ───────────────────────────────────────────────────────────────────

function! claude#difftree#bufnr() abort
  return s:bufnr
endfunction

function! claude#difftree#winid() abort
  return s:bufnr == -1 ? -1 : bufwinid(s:bufnr)
endfunction

function! claude#difftree#is_open() abort
  return s:bufnr != -1 && bufexists(s:bufnr) && bufwinid(s:bufnr) != -1
endfunction

function! claude#difftree#toggle() abort
  if claude#difftree#is_open()
    call claude#difftree#close()
  else
    call claude#difftree#open()
  endif
endfunction

function! claude#difftree#open() abort
  if claude#difftree#is_open()
    call win_gotoid(bufwinid(s:bufnr))
    return
  endif
  let s:prev_winid = win_getid()
  execute claude#sidebar#split_cmd(s:width())

  if s:bufnr != -1 && bufexists(s:bufnr)
    execute 'buffer ' . s:bufnr
  else
    enew
    let s:bufnr = bufnr('%')
    silent! file [claude-diff]
  endif

  call claude#sidebar#buf_options('claudedifftree')
  call s:setup_keys()
  call claude#difftree#_relink()
  call s:setup_syntax()

  " Settle the geometry before running git, which is slow enough that Vim
  " could otherwise redraw the unstacked layout first.
  call claude#sidebar#stack()

  call s:invalidate()
  call s:render()
endfunction

function! claude#difftree#close() abort
  if s:bufnr == -1
    return
  endif
  let l:win = bufwinid(s:bufnr)
  if l:win == -1
    return
  endif
  if winnr('$') <= 1 && tabpagenr('$') <= 1
    return
  endif
  call win_execute(l:win, 'close')
endfunction

" Re-run git and rebuild. Safe to call when the panel is closed.
function! claude#difftree#refresh() abort
  call s:invalidate()
  if claude#difftree#is_open()
    call s:render()
  endif
endfunction

" BufWritePost hook: a save is the one event that reliably changes the dirty
" set, and it is cheap enough to act on because it is rare.
function! claude#difftree#_on_write() abort
  if get(g:, 'claude_difftree_auto_refresh', 1) && claude#difftree#is_open()
    call claude#difftree#refresh()
  endif
endfunction

" ── keys ─────────────────────────────────────────────────────────────────────

function! s:setup_keys() abort
  " Vim does not turn a double-click into <CR> on its own: it only moves
  " the cursor, so the click has to be mapped explicitly. NERDTree does
  " the same thing through <LeftRelease>. Needs 'mouse' to include n or a.
  nnoremap <buffer> <silent> <2-LeftMouse> :call <SID>activate()<CR>
  nnoremap <buffer> <silent> <CR>    :call <SID>activate()<CR>
  nnoremap <buffer> <silent> o       :call <SID>activate()<CR>
  nnoremap <buffer> <silent> i       :call <SID>open_mode('split')<CR>
  nnoremap <buffer> <silent> s       :call <SID>open_mode('vsplit')<CR>
  nnoremap <buffer> <silent> t       :call <SID>open_mode('tab')<CR>
  nnoremap <buffer> <silent> R       :call claude#difftree#refresh()<CR>
  nnoremap <buffer> <silent> b       :call <SID>prompt_base()<CR>
  nnoremap <buffer> <silent> /       :call <SID>prompt_filter()<CR>
  nnoremap <buffer> <silent> <Esc>   :call <SID>clear_filter()<CR>
  nnoremap <buffer> <silent> za      :call <SID>fold()<CR>
  nnoremap <buffer> <silent> <Space> :call <SID>fold()<CR>
  nnoremap <buffer> <silent> q       :call claude#difftree#close()<CR>
  nnoremap <buffer> <silent> ?       :call <SID>help()<CR>
endfunction

function! s:current() abort
  let l:idx = line('.') - 1
  if l:idx < 0 || l:idx >= len(s:nodes)
    return {}
  endif
  return s:nodes[l:idx]
endfunction

function! s:activate() abort
  let l:node = s:current()
  if empty(l:node)
    return
  endif
  if l:node.kind ==# 'file'
    call claude#difftree#open_file(l:node.payload, 'here')
  elseif !empty(l:node.key)
    call s:fold()
  endif
endfunction

function! s:open_mode(mode) abort
  let l:node = s:current()
  if !empty(l:node) && l:node.kind ==# 'file'
    call claude#difftree#open_file(l:node.payload, a:mode)
  endif
endfunction

function! s:fold() abort
  let l:node = s:current()
  if empty(l:node) || empty(l:node.key)
    return
  endif
  if has_key(s:collapsed, l:node.key)
    call remove(s:collapsed, l:node.key)
  else
    let s:collapsed[l:node.key] = 1
  endif
  call s:render()
endfunction

function! s:help() abort
  let s:show_help = !s:show_help
  call s:render()
endfunction

function! s:prompt_base() abort
  let l:new = input('Diff against branch: ', claude#difftree#base(),
        \ 'customlist,claude#difftree#complete_branch')
  redraw
  if !empty(l:new)
    call claude#difftree#set_base(l:new)
  endif
endfunction

" ── filtering ────────────────────────────────────────────────────────────────

" Incremental: each keystroke re-renders, so the tree narrows as you type.
" <CR> keeps the filter, <Esc> abandons it and restores what was there before.
function! s:prompt_filter() abort
  let l:saved = s:filter
  let s:filter = ''
  call s:render()
  while 1
    redraw
    echohl Question
    echo '/' . s:filter
    echohl None
    let l:c = getchar()
    let l:ch = type(l:c) == v:t_number ? nr2char(l:c) : l:c
    if l:ch ==# "\<Esc>"
      let s:filter = l:saved
      break
    elseif l:ch ==# "\<CR>"
      break
    elseif l:ch ==# "\<BS>" || l:ch ==# "\<C-h>"
      let s:filter = strcharpart(s:filter, 0, strchars(s:filter) - 1)
    elseif l:ch ==# "\<C-u>"
      let s:filter = ''
    elseif l:ch =~# '^[[:print:]]$'
      let s:filter .= l:ch
    else
      continue
    endif
    call s:render()
  endwhile
  echo ''
  call s:render()
endfunction

function! s:clear_filter() abort
  if !empty(s:filter)
    let s:filter = ''
    call s:render()
  endif
endfunction

function! claude#difftree#filter() abort
  return s:filter
endfunction

function! claude#difftree#set_filter(text) abort
  let s:filter = a:text
  call s:render()
endfunction

" ── opening a file ───────────────────────────────────────────────────────────

function! claude#difftree#open_file(rec, mode) abort
  if type(a:rec) != v:t_dict
    return
  endif
  let l:full = a:rec.worktree . '/' . a:rec.path
  if !filereadable(l:full)
    echohl WarningMsg
    echomsg 'claude.vim: ' . a:rec.path . ' no longer exists on disk'
    echohl None
    return
  endif
  call claude#sidebar#make_window(a:mode, s:prev_winid)
  execute 'edit ' . fnameescape(l:full)
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

function! claude#difftree#_lines() abort
  if s:bufnr == -1 || !bufexists(s:bufnr)
    return []
  endif
  return getbufline(s:bufnr, 1, '$')
endfunction

function! claude#difftree#_nodes() abort
  return s:nodes
endfunction

function! claude#difftree#_reset() abort
  if s:bufnr != -1 && bufexists(s:bufnr)
    silent! execute 'bwipeout! ' . s:bufnr
  endif
  let s:bufnr      = -1
  let s:prev_winid = -1
  let s:collapsed  = {}
  let s:nodes      = []
  let s:cache      = {}
  let s:base_over  = ''
  let s:base_cache = ''
  let s:filter     = ''
  let s:show_help  = 0
endfunction
