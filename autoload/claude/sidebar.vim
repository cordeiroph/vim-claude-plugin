" ── shared sidebar mechanics ─────────────────────────────────────────────────
"
" Everything several side panels need in common: creating the window, keeping
" them in one column in a fixed order, recognising a sidebar so a file is
" never opened into one, and linking highlight groups to NERDTree's.
"
" Sidebars register themselves with a priority, and the column is always
" ordered by it, top to bottom:
"
"   10  Claude sessions   (autoload/claude/panel.vim)
"   20  Git diff tree     (autoload/claude/difftree.vim)
"   30  NERDTree          (registered below)
"
" A registration is:
"   name      unique string
"   priority  smaller is higher up the column
"   Winid     funcref -> window id in this tab, or -1
"   Height    funcref -> lines to fix the window at, or 0 to leave it free
"
" The bottom-most sidebar is never height-fixed: it absorbs the remainder.

let s:registry    = []
let s:stacked_ids = []

function! claude#sidebar#register(spec) abort
  call filter(s:registry, 'v:val.name !=# a:spec.name')
  call add(s:registry, a:spec)
  call sort(s:registry, {a, b -> a.priority - b.priority})
endfunction

function! s:spec_winid(spec) abort
  try
    return a:spec.Winid()
  catch
    return -1
  endtry
endfunction

function! s:spec_height(spec) abort
  try
    return has_key(a:spec, 'Height') ? a:spec.Height() : 0
  catch
    return 0
  endtry
endfunction

" Live sidebar windows in this tab, ordered top to bottom.
function! claude#sidebar#winids() abort
  let l:out = []
  for l:spec in s:registry
    let l:id = s:spec_winid(l:spec)
    if l:id > 0 && win_id2win(l:id) > 0 && index(l:out, l:id) == -1
      call add(l:out, l:id)
    endif
  endfor
  return l:out
endfunction

" Buffer numbers of every open sidebar, for callers that must not count them
" as ordinary windows.
function! claude#sidebar#bufnrs() abort
  return map(claude#sidebar#winids(), {_, id -> winbufnr(win_id2win(id))})
endfunction

" ── NERDTree ─────────────────────────────────────────────────────────────────

" Window id of NERDTree in the current tab, or -1.
"
" t:NERDTreeBufName is set before the window is even split, so looking the
" window up by name works while NERDTree is still building itself — which is
" when the repair has to run to be invisible. g:NERDTree.GetWinNum() is the
" same lookup, but going direct means this also works for a window tree, where
" that variable is not set.
function! claude#sidebar#nerdtree_winid() abort
  if exists('t:NERDTreeBufName')
    let l:nr = bufwinnr(t:NERDTreeBufName)
    if l:nr > 0
      return win_getid(l:nr)
    endif
  endif
  if !exists('g:NERDTree')
    return -1
  endif
  try
    let l:nr = g:NERDTree.IsOpen() ? g:NERDTree.GetWinNum() : -1
  catch
    return -1
  endtry
  return l:nr > 0 ? win_getid(l:nr) : -1
endfunction

function! claude#sidebar#nerdtree_bufnr() abort
  if !exists('t:NERDTreeBufName')
    return -1
  endif
  return bufnr(t:NERDTreeBufName)
endfunction

" NERDTree owns the bottom of the column and is never height-fixed.
call claude#sidebar#register({
      \ 'name':     'nerdtree',
      \ 'priority': 30,
      \ 'Winid':    function('claude#sidebar#nerdtree_winid'),
      \ })

" ── the ordered stack ────────────────────────────────────────────────────────

function! s:stack_enabled() abort
  return get(g:, 'claude_panel_nerdtree_stack', 1) && exists('*win_splitmove')
endfunction

" True when {wins} are consecutive leaves of one 'col' node, in this order.
function! claude#sidebar#is_stacked(wins) abort
  return s:find(winlayout(), a:wins)
endfunction

function! s:find(node, wins) abort
  if a:node[0] ==# 'leaf'
    return v:false
  endif
  if a:node[0] ==# 'col'
    let l:kids = a:node[1]
    for l:start in range(len(l:kids) - len(a:wins) + 1)
      let l:ok = v:true
      for l:k in range(len(a:wins))
        let l:leaf = l:kids[l:start + l:k]
        if l:leaf[0] !=# 'leaf' || l:leaf[1] != a:wins[l:k]
          let l:ok = v:false
          break
        endif
      endfor
      if l:ok
        return v:true
      endif
    endfor
  endif
  for l:kid in a:node[1]
    if s:find(l:kid, a:wins)
      return v:true
    endif
  endfor
  return v:false
endfunction

" Heights are applied only on the transition into the stacked state. Doing it
" on every call would fight a manual resize, since stack() runs from a timer.
function! s:apply_heights(wins) abort
  for l:i in range(len(a:wins) - 1)
    let l:h = s:height_for(a:wins[l:i])
    if l:h > 0
      call win_execute(a:wins[l:i],
            \ 'resize ' . l:h . ' | setlocal winfixheight')
    endif
  endfor
endfunction

function! s:height_for(winid) abort
  for l:spec in s:registry
    if s:spec_winid(l:spec) == a:winid
      return s:spec_height(l:spec)
    endif
  endfor
  return 0
endfunction

" Bring every open sidebar into one column, in priority order.
"
" The sweep runs bottom-up so each move's target is already in its final
" position: at most N-1 moves, and idempotent. Only registered sidebars are
" touched, so an unrelated split is never pulled into the column.
function! claude#sidebar#stack() abort
  if !s:stack_enabled()
    return
  endif
  let l:wins    = claude#sidebar#winids()
  let l:changed = l:wins !=# s:stacked_ids

  if len(l:wins) < 2 || claude#sidebar#is_stacked(l:wins)
    let s:stacked_ids = l:wins
    " Already in one column. Apply heights only when the set of sidebars just
    " changed -- a sidebar opening or closing is a transition; the poll timer
    " repeating with the same set is not, and must not undo a manual resize.
    if l:changed && len(l:wins) > 1
      call s:apply_heights(l:wins)
    endif
    return
  endif

  let l:cur = win_getid()
  try
    let l:i = len(l:wins) - 2
    while l:i >= 0
      " rightbelow:0 always lands the moved window above the target, so the
      " order comes out right whichever sidebar opened first.
      call win_splitmove(l:wins[l:i], l:wins[l:i + 1],
            \ {'vertical': v:false, 'rightbelow': v:false})
      let l:i -= 1
    endwhile
  catch
    return
  finally
    " Moving windows must not steal focus from whoever triggered this.
    if win_id2win(l:cur) > 0 && win_getid() != l:cur
      call win_gotoid(l:cur)
    endif
  endtry

  let s:stacked_ids = l:wins
  call s:apply_heights(l:wins)
endfunction

" Repair hook for a NERDTree opened on its own (:NERDTree, <C-n>, a session
" file, anything the plugin does not drive itself).
"
" Timing is everything here. NERDTree's window exists as its own column from
" the moment Creator._createTreeWin() splits — measured at 14ms — and
" User NERDTreeInit only fires at the very end of createTabTree(), after
" _createNERDTree() and render(), which with nerdtree-git-plugin runs git
" status calls. Repairing that late means Vim has already painted two columns
" side by side.
"
" FileType nerdtree fires from the last line of _setCommonBufOptions(), the
" last call in _createTreeWin() — after NERDTree has sized its window but
" before it builds or renders the tree. That is the earliest point at which
" the window can be identified, so it is the hook that keeps the repair
" invisible. NERDTreeInit stays wired up as a second chance, and the session
" panel's poll timer remains the final backstop.
function! claude#sidebar#_nerdtree_init() abort
  call claude#sidebar#stack()
endfunction

" WinClosed hook. When a stacked sidebar goes the column collapses on its own,
" so the only thing left to do is release the survivor's fixed height once it
" is alone and should own the whole column again.
function! claude#sidebar#_win_closed(winid) abort
  let l:id = str2nr(a:winid)
  if index(s:stacked_ids, l:id) == -1
    return
  endif
  call filter(s:stacked_ids, 'v:val != ' . l:id)
  call timer_start(0, {-> s:settle()})
endfunction

function! s:settle() abort
  let l:wins = claude#sidebar#winids()
  if len(l:wins) == 1
    call win_execute(l:wins[0], 'setlocal nowinfixheight')
  endif
  let s:stacked_ids = l:wins
endfunction

" ── window creation and targeting ────────────────────────────────────────────

function! claude#sidebar#split_cmd(width) abort
  let l:anchor = get(g:, 'claude_panel_anchor', 'left')
  let l:pos    = l:anchor ==# 'right' ? 'botright' : 'topleft'
  return l:pos . ' vertical ' . a:width . 'split'
endfunction

" Create the window a sidebar should live in.
"
" When another sidebar is already open, split inside its column instead of
" opening a second one beside it. Two sidebar columns merged by
" win_splitmove() leave the survivor too wide -- measured: a 35-column session
" panel became 62 when the diff tree opened beside it and was then folded in,
" and stayed 62 after the diff tree closed -- because Vim gives the freed
" width to the remaining column rather than back to the main area.
"
" Splitting inside the column never creates the second column, so there is
" nothing to merge and the width cannot drift.
function! claude#sidebar#open_window(width) abort
  " With stacking off the sidebars are meant to stay in separate columns, so
  " the shared-column shortcut must not apply either.
  let l:existing = s:stack_enabled() ? claude#sidebar#winids() : []
  if empty(l:existing)
    execute claude#sidebar#split_cmd(a:width)
    return
  endif
  call win_gotoid(l:existing[0])
  leftabove split
endfunction

function! claude#sidebar#buf_options(filetype) abort
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nobuflisted
  setlocal nowrap
  setlocal nonumber norelativenumber
  setlocal signcolumn=no
  setlocal foldcolumn=0
  setlocal cursorline
  setlocal winfixwidth
  setlocal nowinfixheight
  setlocal nomodifiable
  execute 'setlocal filetype=' . a:filetype
endfunction

" True when {winid} is any registered sidebar, rather than somewhere a file
" may be opened.
function! claude#sidebar#is_sidebar(winid) abort
  if a:winid <= 0 || win_id2win(a:winid) <= 0
    return v:true
  endif
  for l:spec in s:registry
    if a:winid == s:spec_winid(l:spec)
      return v:true
    endif
  endfor
  return v:false
endfunction

" Leave the sidebars for the main area. Returns 2 when a fresh window had to
" be created (nothing but sidebars were open), 1 when an existing one was
" entered. {prev_winid} is where the caller was before entering its panel.
function! claude#sidebar#enter_main(prev_winid) abort
  if !claude#sidebar#is_sidebar(win_getid())
    return 1
  endif
  if !claude#sidebar#is_sidebar(a:prev_winid)
    call win_gotoid(a:prev_winid)
    return 1
  endif
  " The remembered window is gone or is itself a sidebar: take any ordinary
  " window in this tab before falling back to creating one.
  for l:nr in range(1, winnr('$'))
    if !claude#sidebar#is_sidebar(win_getid(l:nr))
      call win_gotoid(win_getid(l:nr))
      return 1
    endif
  endfor
  execute claude#split_cmd()
  enew
  setlocal noswapfile
  return 2
endfunction

" Create the window a file or terminal should be shown in. {mode} is 'here',
" 'split', 'vsplit' or 'tab'.
function! claude#sidebar#make_window(mode, prev_winid) abort
  if a:mode ==# 'tab'
    tabnew
    setlocal noswapfile
    return
  endif
  if a:mode ==# 'here'
    call claude#sidebar#enter_main(a:prev_winid)
    execute claude#split_cmd()
    return
  endif
  if claude#sidebar#enter_main(a:prev_winid) == 2
    return                        " a fresh window was just created
  endif
  execute a:mode ==# 'vsplit' ? 'vertical split' : 'split'
endfunction

" ── glyphs and text ──────────────────────────────────────────────────────────

function! claude#sidebar#ascii() abort
  return get(g:, 'claude_panel_ascii', 0) || &encoding !~? '^utf'
endfunction

" Fold marker for an open or closed node.
function! claude#sidebar#marker(is_open) abort
  if claude#sidebar#ascii()
    return a:is_open ? 'v' : '>'
  endif
  return a:is_open ? '▾' : '▸'
endfunction

" A character class matching either marker, whichever set is in use.
function! claude#sidebar#marker_class() abort
  return '[' . escape(claude#sidebar#marker(1)
        \ . claude#sidebar#marker(0), ']^\-') . ']'
endfunction

" Fit {text} into {width}, trimming from the left of a path so the
" distinctive tail stays visible.
function! claude#sidebar#fit(width, indent, text) abort
  let l:room = a:width - strchars(a:indent) - 1
  if l:room < 4 || strchars(a:text) <= l:room
    return a:text
  endif
  let l:ellipsis = claude#sidebar#ascii() ? '...' : '…'
  let l:keep = l:room - strchars(l:ellipsis)
  return l:ellipsis . strcharpart(a:text, strchars(a:text) - l:keep)
endfunction

function! claude#sidebar#home_relative(path) abort
  let l:home = expand('~')
  if a:path[0 : len(l:home) - 1] ==# l:home
    return '~' . a:path[len(l:home) :]
  endif
  return a:path
endfunction

" ── highlight linking ────────────────────────────────────────────────────────

" The group {name} is linked to, or '' when it is not a link.
function! s:link_target(name) abort
  try
    let l:out = execute('highlight ' . a:name)
  catch
    return ''
  endtry
  let l:m = matchlist(l:out, 'links to \(\S\+\)')
  return empty(l:m) ? '' : l:m[1]
endfunction

" Link each [group, nerdtree_group, fallback] triple, preferring NERDTree's
" own group when it is defined so restyling NERDTree restyles the sidebar too.
"
" NERDTree's groups do not exist until its syntax file has been sourced, so
" the first link is usually to the fallback and has to be upgraded later.
" `highlight default link` cannot do that — "default" means it will not
" overwrite an existing link, including one we set ourselves — so an upgrade
" is applied with `highlight! link`, and only when the current link is still
" the fallback we chose. Anything the user set is left alone.
function! claude#sidebar#link_highlights(map) abort
  for [l:group, l:nerd, l:fallback] in a:map
    let l:want = (!empty(l:nerd) && hlexists(l:nerd)) ? l:nerd : l:fallback
    let l:cur  = s:link_target(l:group)
    if empty(l:cur)
      execute 'highlight default link ' . l:group . ' ' . l:want
    elseif l:cur ==# l:fallback && l:want !=# l:fallback
      execute 'highlight! link ' . l:group . ' ' . l:want
    endif
  endfor
endfunction

" ── test seam ────────────────────────────────────────────────────────────────

function! claude#sidebar#_registry() abort
  return map(copy(s:registry), {_, s -> s.name})
endfunction

function! claude#sidebar#_unregister(name) abort
  call filter(s:registry, 'v:val.name !=# a:name')
endfunction

function! claude#sidebar#_reset() abort
  let s:stacked_ids = []
endfunction
