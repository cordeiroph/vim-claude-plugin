" Guard against being sourced twice (e.g. when Vundle reloads plugins).
if exists('g:loaded_claude_plugin')
  finish
endif
let g:loaded_claude_plugin = 1

" ── configuration defaults ───────────────────────────────────────────────────

" g:claude_split_anchor — which screen edge the Claude window is pinned to.
" Accepted values: 'right' (default), 'left', 'top', 'bottom'.
if !exists('g:claude_split_anchor')
  let g:claude_split_anchor = 'right'
endif

" g:claude_split_size — width (columns) for left/right anchors, or height
" (lines) for top/bottom anchors.
if !exists('g:claude_split_size')
  let g:claude_split_size = 80
endif

" g:claude_cmd — the shell command used to launch Claude CLI.
if !exists('g:claude_cmd')
  let g:claude_cmd = 'claude'
endif

" g:claude_models — ordered list of model names shown by ClaudeModel picker.
if !exists('g:claude_models')
  let g:claude_models = [
        \ 'claude-opus-4-7',
        \ 'claude-sonnet-4-6',
        \ 'claude-haiku-4-5-20251001',
        \ ]
endif

" ── session panel configuration ──────────────────────────────────────────────

" g:claude_panel_width — panel width in columns.
if !exists('g:claude_panel_width')
  let g:claude_panel_width = 35
endif

" g:claude_panel_anchor — which edge the panel is pinned to: 'left' or 'right'.
if !exists('g:claude_panel_anchor')
  let g:claude_panel_anchor = 'left'
endif

" g:claude_panel_icons — status glyphs, keyed 'active', 'idle', 'closed'.
" Partial dicts are merged over the defaults.
if !exists('g:claude_panel_icons')
  let g:claude_panel_icons = {}
endif

" g:claude_panel_ascii — 1 forces the [A]/[I]/[C] glyph set.
if !exists('g:claude_panel_ascii')
  let g:claude_panel_ascii = 0
endif

" g:claude_panel_refresh_ms — status poll interval while the panel is visible.
" The poller is stopped entirely when the panel is hidden.
if !exists('g:claude_panel_refresh_ms')
  let g:claude_panel_refresh_ms = 2000
endif

" g:claude_panel_idle_secs — seconds without terminal output before a running
" session is shown as idle rather than active. Only consulted when the bottom
" of the terminal says nothing conclusive; see the two patterns below.
if !exists('g:claude_panel_idle_secs')
  let g:claude_panel_idle_secs = 30
endif

" g:claude_panel_working_pat — pattern marking a session as working, matched
" against the bottom of its terminal. Claude prints this while it runs.
if !exists('g:claude_panel_working_pat')
  let g:claude_panel_working_pat = 'esc to interrupt'
endif

" g:claude_panel_waiting_pat — pattern marking a session as waiting for you:
" a numbered choice, a permission question, a yes/no. Matching sessions are
" grouped under "Needs you" at the top of the panel.
if !exists('g:claude_panel_waiting_pat')
  let g:claude_panel_waiting_pat =
        \ '\%(^\|\n\)\s*❯\=\s*1\.\s\|Do you want\|(y/n)'
endif

" g:claude_panel_stale_days — days after which a finished session is hidden
" from the panel, whoever named it. 0 hides none. The panel's I key reveals
" them, along with the finished sessions nobody named.
if !exists('g:claude_panel_stale_days')
  let g:claude_panel_stale_days = 2
endif

" g:claude_panel_done_rows — how many finished sessions the Done group draws
" before it stops with a "… N more" row.
if !exists('g:claude_panel_done_rows')
  let g:claude_panel_done_rows = 10
endif

" g:claude_panel_show_closed — 0 lists only live sessions.
if !exists('g:claude_panel_show_closed')
  let g:claude_panel_show_closed = 1
endif

" g:claude_panel_closed_limit — max closed sessions listed per project.
if !exists('g:claude_panel_closed_limit')
  let g:claude_panel_closed_limit = 10
endif

" g:claude_panel_auto_open — 1 opens the panel on VimEnter.
if !exists('g:claude_panel_auto_open')
  let g:claude_panel_auto_open = 0
endif

" g:claude_panel_height — panel height in lines while it shares a column with
" NERDTree. The panel is height-fixed at this size and NERDTree takes the rest.
if !exists('g:claude_panel_height')
  let g:claude_panel_height = 15
endif

" g:claude_panel_height_pct — the same height as a percentage of the screen,
" which is what the panel uses by default so the column keeps its proportions
" on any terminal. Set it to 0 to size the panel in lines with
" |g:claude_panel_height| instead.
if !exists('g:claude_panel_height_pct')
  let g:claude_panel_height_pct = 25
endif

" g:claude_panel_nerdtree_stack — 1 (default) stacks the panel above NERDTree
" in one column when both are open. 0 leaves them as separate columns.
if !exists('g:claude_panel_nerdtree_stack')
  let g:claude_panel_nerdtree_stack = 1
endif

" g:claude_session_store — where session names are persisted. Defaults to
" data/sessions.json inside the plugin directory, which keeps the plugin
" self-contained but is wiped by a plugin reinstall; point this somewhere
" durable (e.g. '~/.claude/vim-sessions.json') to keep names across updates.
if !exists('g:claude_session_store')
  let g:claude_session_store = ''
endif

" g:claude_session_prompt_name — 0 skips both prompts for new sessions: no
" branch, no workspace, and no name — Claude names the conversation itself,
" which leaves the session hidden from the panel until I reveals it.
if !exists('g:claude_session_prompt_name')
  let g:claude_session_prompt_name = 1
endif

" g:claude_session_flags — whether the CLI understands --session-id/--name.
" -1 (default) probes `claude --help` once; 1 forces them on, 0 off. Only
" needed when the probe cannot run, e.g. g:claude_cmd launches Claude through
" a wrapper with another name.
if !exists('g:claude_session_flags')
  let g:claude_session_flags = -1
endif

" ── workspace configuration ──────────────────────────────────────────────────

" g:claude_workspace_dir — parent directory for the git worktrees new
" workspaces check out into. Empty (default) puts each one beside the main
" checkout as <repo>-<workspace name>; set it to keep them elsewhere, e.g.
" '~/src/worktrees'.
if !exists('g:claude_workspace_dir')
  let g:claude_workspace_dir = ''
endif

" g:claude_workspace_store — where workspaces are persisted, with the same
" override-or-plugin-dir rule (and reinstall caveat) as
" |g:claude_session_store|.
if !exists('g:claude_workspace_store')
  let g:claude_workspace_store = ''
endif

" ── git diff tree configuration ──────────────────────────────────────────────

" g:claude_difftree_height — height in the shared sidebar column, applied when
" it first comes to share one. A starting size, not an enforced one.
if !exists('g:claude_difftree_height')
  let g:claude_difftree_height = 15
endif

" g:claude_difftree_height_pct — that height as a percentage of the screen,
" used in preference to the line count. 0 falls back to
" |g:claude_difftree_height|.
if !exists('g:claude_difftree_height_pct')
  let g:claude_difftree_height_pct = 40
endif

" g:claude_difftree_width — width when the diff tree is the only sidebar.
if !exists('g:claude_difftree_width')
  let g:claude_difftree_width = 35
endif

" g:claude_difftree_base — branch to diff against. Empty auto-detects:
" origin/HEAD, then main, then master.
if !exists('g:claude_difftree_base')
  let g:claude_difftree_base = ''
endif

" g:claude_difftree_show_untracked — include untracked files.
if !exists('g:claude_difftree_show_untracked')
  let g:claude_difftree_show_untracked = 1
endif

" g:claude_difftree_auto_refresh — re-run git on :write while the panel is open.
if !exists('g:claude_difftree_auto_refresh')
  let g:claude_difftree_auto_refresh = 1
endif

" g:claude_difftree_collapse_dirs — merge runs of single-child directories, so
" `autoload/claude` is one node rather than two.
if !exists('g:claude_difftree_collapse_dirs')
  let g:claude_difftree_collapse_dirs = 1
endif

" ── sidebar column configuration ─────────────────────────────────────────────

" g:claude_sidebar_toggle_key — key that raises or dismisses the whole sidebar
" column (|:ClaudeSidebars|). An empty string leaves the key unmapped.
"
" The default shadows Vim's built-in CTRL-A increment-number command in
" normal mode.
if !exists('g:claude_sidebar_toggle_key')
  let g:claude_sidebar_toggle_key = '<C-a>'
endif

" ── commands ─────────────────────────────────────────────────────────────────

command! ClaudeOpen    call claude#open()
command! ClaudeToggle  call claude#toggle()
command! ClaudeClose   call claude#close()
command! ClaudeExplain call claude#explain('n')
command! ClaudeModel   call claude#select_model()
command! ClaudeResume  call claude#resume()
command! ClaudeInput   call claude#input#open()

" Session panel.
command!          ClaudeSessions      call claude#panel#toggle()
command!          ClaudeSessionsOpen  call claude#panel#open()
command!          ClaudeSessionsClose call claude#panel#close()
command! -nargs=? ClaudeNew           call claude#new(<q-args>)
command! -nargs=? ClaudeRename        call claude#rename(<q-args>)

" Workspaces: the git worktrees sessions run in.
command! ClaudeWorkspaces call claude#workspace#pick()

" Git diff tree.
" The whole sidebar column: sessions, diff tree and NERDTree together.
command! ClaudeSidebars call claude#sidebar#toggle_all()

command! ClaudeDiff        call claude#difftree#toggle()
command! ClaudeDiffOpen    call claude#difftree#open()
command! ClaudeDiffClose   call claude#difftree#close()
command! ClaudeDiffRefresh call claude#difftree#refresh()
" Sets the base for one branch: the argument's, or the one under the cursor.
" An empty argument clears that branch's override.
command! -nargs=* -complete=customlist,claude#difftree#complete_branch
      \ ClaudeDiffBase call claude#difftree#base_command(<q-args>)

" Window navigation commands (wrappers around wincmd h/l/k/j).
command! ClaudeFocus      call claude#focus()
command! ClaudeWinLeft    call claude#win_move('h')
command! ClaudeWinRight   call claude#win_move('l')
command! ClaudeWinUp      call claude#win_move('k')
command! ClaudeWinDown    call claude#win_move('j')

" ── autocommands ─────────────────────────────────────────────────────────────

augroup claude_plugin
  autocmd!
  " Vim refuses to exit while a terminal job is running (E947), so the jobs
  " must be stopped before that check runs. ExitPre fires just after QuitPre
  " but only for a :q / :wq / :qall that actually ends the session, so a live
  " session survives closing an ordinary split. QuitPre must not be used here:
  " it fires for every window close and would kill the session each time.
  if exists('##ExitPre')
    autocmd ExitPre * call claude#_stop_jobs()
  else
    " Vim 8.1 before patch 8.1.0446 has no ExitPre; fall back to QuitPre with
    " a guard so only the quit that closes the last window stops the jobs.
    autocmd QuitPre * call claude#_quit_pre()
  endif
  " VimLeavePre fires after Vim commits to exiting; wipe the buffers then.
  autocmd VimLeavePre * call claude#close_all()
  " Track the most recently focused session, so the picker offers it first.
  autocmd WinEnter * call claude#_win_enter()
  autocmd VimEnter * if g:claude_panel_auto_open | call claude#panel#open() | endif
  " Share one column with NERDTree: re-stack when it opens, and let the panel
  " reclaim the column when it closes. Both hooks no-op without NERDTree.
  " FileType fires while NERDTree is still building itself, long before
  " NERDTreeInit, so the repair lands before the two columns are painted.
  " NERDTreeInit is kept as a second chance for trees that skip that path.
  autocmd FileType nerdtree call claude#panel#_nerdtree_init()
  " NERDTree's highlight groups only exist once its syntax file has been
  " sourced, so pick them up the first time a tree appears.
  autocmd FileType nerdtree call claude#panel#_relink()
  autocmd FileType nerdtree call claude#difftree#_relink()
  " A save is the one event that reliably changes the uncommitted set.
  autocmd BufWritePost * call claude#difftree#_on_write()
  autocmd User NERDTreeInit call claude#panel#_nerdtree_init()
  if exists('##WinClosed')
    autocmd WinClosed * call claude#panel#_win_closed(expand('<amatch>'))
  endif
augroup END

" ── keymaps ──────────────────────────────────────────────────────────────────

" All default mappings can be disabled by setting g:claude_no_default_mappings=1
" before this plugin loads.
if !exists('g:claude_no_default_mappings')
  nnoremap <silent> <leader>co :ClaudeOpen<CR>
  nnoremap <silent> <leader>ct :ClaudeToggle<CR>
  nnoremap <silent> <leader>cx :ClaudeClose<CR>
  nnoremap <silent> <leader>cf :ClaudeFocus<CR>

  " Start a session even when others are running. <leader>co focuses or picks
  " one instead, and only creates when nothing is live.
  nnoremap <silent> <leader>cn :ClaudeNew<CR>

  " Toggle the session panel.
  nnoremap <silent> <leader>cs :ClaudeSessions<CR>

  " Toggle the git diff tree.
  nnoremap <silent> <leader>cd :ClaudeDiff<CR>

  " Pick the workspace to work in; NERDTree follows the choice.
  nnoremap <silent> <leader>cw :ClaudeWorkspaces<CR>

  " Raise or dismiss the whole sidebar column. Normal mode only: <C-a> must
  " keep incrementing a number under the cursor elsewhere (insert mode,
  " visual mode, etc).
  if !empty(g:claude_sidebar_toggle_key)
    execute 'nnoremap <silent> ' . g:claude_sidebar_toggle_key
          \ . ' :ClaudeSidebars<CR>'
  endif

  " Explain: normal mode sends the whole file; visual mode sends the selection.
  nnoremap <silent> <leader>ce :call claude#explain('n')<CR>
  xnoremap <silent> <leader>ce :<C-u>call claude#explain('v')<CR>

  " Switch model for the current session.
  nnoremap <silent> <leader>cm :ClaudeModel<CR>

  " Resume a previous session from the last 10 for this directory.
  nnoremap <silent> <leader>cr :ClaudeResume<CR>

  " Floating input window for composing multi-line messages.
  nnoremap <silent> <leader>ci :ClaudeInput<CR>

  " Window navigation (mirrors Ctrl-W hjkl as leader shortcuts).
  nnoremap <silent> <leader>ch :ClaudeWinLeft<CR>
  nnoremap <silent> <leader>cl :ClaudeWinRight<CR>
  nnoremap <silent> <leader>ck :ClaudeWinUp<CR>
  nnoremap <silent> <leader>cj :ClaudeWinDown<CR>
endif
