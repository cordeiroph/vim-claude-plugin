# claude.vim

A Vim plugin that opens the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) in a terminal split, giving you persistent AI sessions alongside your code.

Run as many sessions as you like, each in a **project** of its own: a git worktree, on a branch named after it, cut from a baseline branch — so several agents can work side by side without sharing a checkout. A NERDTree-style **projects panel** shows every project with its diff against the baseline, what it has not pushed yet, its files and its sessions, and swaps to a view of every session grouped by what it is doing.

## Requirements

- Vim 8.1+ (with `+terminal`)
- The `claude` CLI on your `$PATH`
- Optional: the [`pi`](https://github.com/earendil-works/pi) CLI, to run Pi
  sessions alongside Claude ones — see [Choosing an agent](#choosing-an-agent)
- Optional: [fzf.vim](https://github.com/junegunn/fzf.vim), for
  `:ClaudeProjectFiles` and `:ClaudeProjectRg`; [`rg`](https://github.com/BurntSushi/ripgrep)
  for the latter and for `@` file completion in the input window

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'cordeiroph/claude.vim'
```

Or copy `plugin/claude.vim`, `autoload/claude.vim`, and `autoload/claude/` into your plugin directory manually.

## Usage

| Mapping | Command | Action |
|---------|---------|--------|
| `<C-a>` | `:ClaudeSidebars` | Raise or dismiss the projects panel, leaving the cursor where it is |
| `<leader>cs` | `:ClaudeSessions` | Toggle the projects panel (and focus it) |
| `<leader>co` | `:ClaudeOpen` | Focus a session, starting one if none is running |
| `<leader>cn` | `:ClaudeNew [project:] [name]` | Start a session even when others are already running |
| `<leader>pn` | `:PiNew [project:] [name]` | Start a session on Pi rather than the default agent |
| `<leader>cw` | `:ClaudeProjects` | Choose the project (git worktree) to work in |
| `<leader>cd` | `:ClaudeDiff` | Toggle the git diff tree |
| `<leader>cr` | `:ClaudeResume` | Reopen a closed session of this directory |
| `<leader>ct` | `:ClaudeToggle` | Show/hide a Claude window |
| `<leader>cx` | `:ClaudeClose` | End a session |
| `<leader>cf` | `:ClaudeFocus` | Move cursor to a Claude window (enters insert mode) |
| `<leader>ce` | `:ClaudeExplain` | Explain the current file (normal) or selection (visual) |
| `<leader>ci` | `:ClaudeInput` | Toggle the input window for multi-line messages |
| `<leader>cm` | `:ClaudeModel` | Switch model interactively |
| `<leader>ch/l/k/j` | `:ClaudeWin*` | Navigate between windows |

Commands with no default mapping:

| Command | Action |
|---------|--------|
| `:ClaudeProjectFiles[!]` | Find a file in a project, asking which first (fzf.vim) |
| `:ClaudeProjectRg[!] [query]` | Search a project's contents with ripgrep, asking which first (fzf.vim) |
| `:ClaudeReveal [file]` | Show the current file in the projects panel, like `:NERDTreeFind` |
| `:ClaudeRename [name]` | Rename a session |
| `:ClaudeSessionsOpen` / `:ClaudeSessionsClose` | Open or hide the projects panel explicitly |
| `:ClaudeDiffOpen` / `:ClaudeDiffClose` / `:ClaudeDiffRefresh` | Drive the diff tree explicitly |
| `:ClaudeDiffBase [base]` | Set (or, with no argument, clear) the diff base of the branch under the cursor in the diff tree |
| `:SessionPanelHookSetup [agent]` | Install the status hooks into the current folder |

For example, to search and reveal per project:

```vim
nmap <F1>  :ClaudeProjectFiles<CR>
nmap <F2>  :ClaudeProjectRg<CR>
nmap <C-f> :ClaudeReveal<CR>
```

When several sessions are running, commands that need just one show a picker; when only one is running, it is used without prompting. Starting a session without naming it on the command line asks which project it goes in first, then its name — see [Projects](#projects).

Inside the Claude terminal, press `<Esc><Esc>` to enter terminal-normal mode (so Vim handles the cursor and mouse). Single `<Esc>` is passed through to Claude.

`:ClaudeRooms` and `:ClaudeWorkspaces` are older names for `:ClaudeProjects` and still work.

## Input window

`<leader>ci` toggles a dedicated buffer for writing long, multi-line prompts. It opens as a 10-line split at the bottom. Pressing `<leader>ci` again discards the content and closes the window. To preserve your text, press `<C-c>` instead — it saves a draft and hides the window; reopening restores it.

The buffer is a `.md` file, so syntax highlighting and Copilot completions work out of the box.

| Key | Action |
|-----|--------|
| `<C-s>` (insert or normal) | Send the message and close the window |
| `<C-c>` (normal) | Save draft and hide the window |
| `q` (normal) | Discard draft and close |

Type `/` to trigger slash-command completion. Type `@` to complete file paths or agent names — file completions require [`rg`](https://github.com/BurntSushi/ripgrep) on your `$PATH` and support basename matching (e.g. `@cla` matches `doc/claude.txt`).

Claude is opened automatically if no session is running.

## Projects

A project is a git worktree that sessions belong to: its own checkout, inside the repository, on a branch named after the project and cut from a **baseline** — `origin/main` unless you name another. The repository's main checkout is a project too, the **root**. Every session in a repository belongs to one.

```
repo/
└── .vim-workspace/                 kept out of git status via .git/info/exclude
    ├── panel/
    │   └── repo/                   project panel, on branch panel
    └── difftree/
        └── repo/                   project difftree, on branch difftree
```

**Creating one.** `N` in the projects panel asks for a name, then a baseline with branch completion. A blank baseline means the *latest* default branch: it is fetched (`g:claude_project_fetch`) and the project is cut from the remote's copy, not a stale local one. The new branch has no upstream, so `git push` from it never lands on the baseline. A name whose branch or directory is taken gets a number (`panel-1`); `g:claude_project_branch_prefix` puts something like `feature/` in front of the branch.

**The baseline** is what the project diffs against and what it merges from. A baseline named by its local branch — `main` — is read off the remote when the remote has it, `origin/main`: that is what the work will land on. `b` moves it, and the diffs follow at once. `u` brings the project up to date: it fetches the baseline and merges it into the project's branch. `u` is refused while the worktree has uncommitted changes, and a merge that stops on conflicts is left in progress for you to resolve. The plugin never pushes, and never merges anything into the baseline — that step is yours.

**Deleting one.** `D` removes the project's worktree; the branch, and every commit on it, is always kept. It asks first, and asks again when uncommitted changes would be lost. The root checkout cannot be deleted. A project removed by hand drops out of the list on its own.

**Starting a session in one.** Starting a session asks which project first, then the session's name:

```
Project for the new session (blank keeps *):
1. * claude-plugin (root) — main
2.   panel
3.   difftree
4.   + New project…
```

- **An existing project** — the session joins it; nothing is created. A blank answer keeps the selected project.
- **A new project** asks for a name and a baseline, as `N` does.

Nothing is created until every question is answered, so CTRL-C anywhere leaves nothing behind. A session left unnamed in a project it just created takes the project's name. `g:claude_session_prompt_name = 0` skips every question: the session goes in the selected project, on the default agent, unnamed.

`:ClaudeNew`/`:PiNew` answer both questions without prompting when the text starts with `project:` — a word immediately followed by a colon. Everything after it is the session name, e.g. `:ClaudeNew panel: Fix the fleet config`. The project is used if it exists and made with the default baseline if it doesn't; `root:` means the main checkout. `:ClaudeNew panel:` with nothing after the colon names the session after the project. Without a leading `word:` the whole text is still just the session name, spaces and all — `:ClaudeNew fix the bug` names the session "fix the bug" and touches no project.

**Choosing one.** `<leader>cw` (`:ClaudeProjects`) lists every project and re-roots NERDTree onto the one you pick. Sessions started without being asked run there. It also runs `:tcd` to that project, so the current tab's working directory — and anything that depends on it, like `:Git status` — follows; other tabs are left alone. The choice lasts for this Vim session.

**Searching one.** `:ClaudeProjectFiles` and `:ClaudeProjectRg [query]` are fzf.vim's file finder and a ripgrep search (`rg --column --line-number --no-heading --smart-case`) that ask which project first, then search that project's worktree. With nothing to choose between — the root checkout alone, or outside git — they search right away, as `:Files` and `:Rg` would. The question falls back to a numbered list without fzf, or with `g:claude_no_popup = 1`.

**Revealing a file.** `:ClaudeReveal` opens the projects panel on the project the current file is in, unfolds its Files and every directory on the way, and puts the cursor on the file. A file git ignores is not in the tree, so the cursor lands on its project instead. Outside any project it runs `:NERDTreeFind`.

> **Watch out:** `git clean -ffdx` in the main checkout deletes every project, uncommitted work included (a single `-f` skips them). Tools that ignore git's ignore rules — `:vimgrep **`, some test runners — see one copy of the repository per project; set an absolute `g:claude_project_dir` to keep projects outside it.

**Coming from rooms.** Projects were called rooms, and rooms could be split into sub-rooms. Both carry over where they already are — nothing is moved: a room is a project, and a sub-room becomes a project of its own named `<room>-<sub>`, still diffing against its old room until `b` says otherwise. Workspaces, from before rooms, become projects the same way, and the sessions in them follow. The `g:claude_room_dir`, `g:claude_room_fetch` and `g:claude_room_store` options still work; `g:claude_workspace_dir` and `g:claude_workspace_store` are read only to migrate from.

## Projects panel

`<C-a>` (or `<leader>cs`) toggles the projects panel. It has two views, swapped with `g`, and each keeps its own folds.

**Projects**, which is what it opens on — every project of the repository you are in, the root checkout first:

```
Projects                  1 waiting

▾ claude-plugin (root) [origin/main]
  ▸ main Diff
  ▸ Local Diff
  ▸ Files
  ▾ Sessions (1)
    ● panel design               1m
▾ panel [origin/main]
  ▾ main Diff
    ▾ autoload/claude
      [ |✹] panel.vim
      [ |✭] scratch.vim
  ▾ Local Diff
    (not pushed)
  ▾ Files
    ▸ autoload/
    ▸ doc/
      README.md
  ▾ Sessions (2)
    ○ icon set                   5m
    ✻ pick a diff base           2m

? help
```

A project row is its name and, in brackets, the baseline it diffs against. When the project's branch is not the one its name implies — a worktree you made yourself, or one carried over from a workspace — the branch follows an em dash: `research — pedro/e2e-instance [origin/main]`. Under it:

- **`<baseline> Diff`** (`main Diff` above) — named after the baseline branch, without its remote: everything the project changed since it left its baseline, committed and uncommitted, drawn exactly as the [diff tree](#git-diff-tree) draws it.
- **Local Diff** — what this checkout has that the remote branch does not: unpushed commits plus uncommitted work, compared with the branch's upstream, else `origin/<branch>`. A branch never pushed says `(not pushed)`.
- **Files** — the worktree as a tree, honouring `.gitignore`. Directories open one level at a time; files open like NERDTree's (`<CR>`, `i`, `s`, `t`).
- **Sessions** — the agents working in the project.

The diffs and Files start shut and are read afresh each time they are opened, on `R`, and on a write, so looking costs git only when you look. Sessions from another repository, or from a checkout that is no project, sit under **Elsewhere** at the bottom.

**By state**, for when the question is *which agent is waiting for me?*:

```
Claude Sessions           1 waiting

▾ Needs you (1)
  ▾ panel
    ✻ pick a diff base           2m
▾ Working (1)
  ▾ claude-plugin (root)
    ● panel design               1m
▾ Idle (1)
  ▾ panel
    ○ icon set                   5m
▸ Done (10)

? help
```

Inside each group, sessions sit under their project; with sessions from more than one repository listed, the project row is prefixed with its repository (`claude-plugin › panel`). `Done` starts folded, draws at most `g:claude_panel_done_rows` rows with a `… N more` for the rest, and hides the sessions nobody named or nobody has touched for `g:claude_panel_stale_days` days. It says how many it is hiding; `I` reveals them.

`✻` waiting for you, `●` working, `○` idle, `✗` closed but resumable.

Waiting and working are read from the bottom rows of the session's terminal, where Claude prints its own state — a spinner while it works, a numbered list while it asks. Both are patterns you can change (`g:claude_panel_waiting_pat`, `g:claude_panel_working_pat`); when neither matches, the idle timer (`g:claude_panel_idle_secs`) decides.

| Key | Action |
|-----|--------|
| `<CR>` / `o` / double-click | Open the session or file, or fold a row |
| `i` | Open in a horizontal split |
| `s` | Open in a vertical split |
| `t` | Open in a new tab |
| `N` | Create a project: a name, then a baseline (blank for `origin/main`) |
| `n` | Start a session in the project under the cursor, asking only its name |
| `m` | The project menu: every project action, each listed with its key |
| `b` | Change the project's baseline (branch completion; blank for the default) |
| `u` | Fetch the baseline and merge it into the project's branch |
| `D` | Delete the project: its worktree goes, its branch is kept |
| `g` | Swap the top level: projects ⇄ by state |
| `/` | Filter every group |
| `r` | Rename the session |
| `d` | End the session (transcript kept, so it stays resumable) |
| `X` | Purge the session and delete its transcript |
| `R` | Rescan transcripts, and re-read every diff and file tree |
| `I` | Show or hide the buried sessions |
| `<Space>` / `za` | Fold or unfold |
| `q` | Hide the panel |
| `?` | Toggle the inline key reference |

`m`, `n`, `b`, `u` and `D` act on **the project under the cursor**: its own row, or any row inside it — a section, a directory, a file, a session — and, in the state view, a project row and the sessions under it. `n` on a session row starts another like it, in the same project on the same agent; on any other row inside a project it starts one there, asking which agent when more than one is installed; anywhere else it asks which project first.

`/` filters every group by label, project or branch. Groups left empty are dropped, folds that hid a match are opened, and the hidden tail is searched too — a row you asked for by name is not a row to hide.

Hiding the panel never stops a session. Status is polled (`g:claude_panel_refresh_ms`) only while the panel is visible.

The panel uses NERDTree's palette — group nodes coloured like directories, session names like files — so the sidebar reads as one thing. Where NERDTree's highlight groups exist they are used directly, so restyling NERDTree restyles the panel. Override `ClaudeSessionProject`, `ClaudeSessionBaseTag`, `ClaudeSessionBranch`, `ClaudeSessionName`, `ClaudeSessionActive` and friends to restyle just the panel; a link you set is never overwritten.

### Work the terminal cannot see

A subagent, or a background task that outlives the turn that started it, prints nothing — so the tail alone puts that session in Idle. The agents can say so themselves: `:SessionPanelHookSetup` installs the bundled writers into the folder you are in (Claude Code's hook into `.claude/`, Pi's extension into `.pi/extensions/`), and `g:claude_panel_hook_state = 1` lets the panel read what they write.

It writes only under the current directory, and running it twice changes nothing: a correct copy is left alone, an already-registered handler is not registered again, and a settings file it cannot parse is refused rather than replaced. `examples/hooks/README.md` has the event table, the manual install for every project, and the removal steps.

Records are evidence, never authority: a dead session can never be listed as alive, a record that asks for attention while the terminal says the session is working loses to the terminal, and anything stale, foreign or malformed leaves the patterns deciding exactly as they do today.

### Session names, and the buried tail

New sessions prompt for a name, which is passed to the Claude CLI too, so it shows up in Claude's own prompt box and `/resume` picker. Names are stored in `g:claude_session_store` — by default `data/sessions.json` inside the plugin directory.

> **Note:** a plugin update or reinstall (`:PlugUpdate`, `:PlugClean`, deleting the bundle directory) deletes that file and every session name with it. To keep names across updates, set `g:claude_session_store` to a path outside the plugin, e.g. `expand('~/.claude/vim-sessions.json')`. The same goes for `g:claude_project_store` and `g:claude_difftree_store`.

Leaving the name blank is a real answer: the session goes unnamed and Claude names the conversation itself. Sessions carrying a `claude <date> <time>` name count as unnamed too — that is what earlier versions minted when the prompt was left empty, so nobody ever chose it. An unnamed session is labelled by the first thing that was asked of it, read from its transcript, and falls back to its id (`(unnamed 4f3c9a02)`) only when there is no message yet.

A **finished** session is buried — left out of the panel list, the way NERDTree leaves out dotfiles — when nobody named it, or when nobody has touched it for `g:claude_panel_stale_days` days (2 by default). A running session is never buried, whatever it is called: the one waiting for you is the last thing to hide.

Press `I` to show the buried ones and again to put them away; renaming one with `r` un-hides it until it goes stale. They are hidden from the panel list only: a buried session still counts in the header while it runs, still appears in the pickers and in `:ClaudeResume`, and still runs.

Claude only writes a conversation to disk once it has content, so a session you started but never messaged has nothing to resume. Opening one of those claims its id for a fresh conversation rather than failing — the name and id are kept.

### Sharing a column with NERDTree

The projects panel, the diff tree and NERDTree would otherwise form columns of their own and swallow most of the screen. Whichever of them are open share one column, panel on top:

```
+----------------+---------------------------+
| Projects       |                           |
+----------------+   your code               |
| NERDTree       |                           |
+----------------+---------------------------+
```

It works whichever opens first, and closing one hands the column to the others. The column is sized by percentage of the screen — the projects panel takes `g:claude_panel_height_pct` (25), the diff tree `g:claude_difftree_height_pct` (40), and the bottom-most sidebar (NERDTree, when it is installed) absorbs the rest; zero a percentage to go back to a height in lines. Resize any of them by hand and it stays put, since the sizes are applied only when the sidebars first come together.

`<C-a>` (`:ClaudeSidebars`) raises or dismisses the projects panel alone — the panel carries each project's diffs and files itself, so the diff tree (`<leader>cd`) and NERDTree open only when you ask for them. It is mapped in normal mode only, so `<C-a>` still increments a number under the cursor from a terminal buffer, from insert mode, and in visual mode; rebind or disable it with `g:claude_sidebar_toggle_key`. While stacked the column is NERDTree's width, since NERDTree resets its own width on every redraw. Set `g:claude_panel_nerdtree_stack = 0` to opt out.

### Git diff tree

`<leader>cd` opens a tree of every file that differs from the base branch — committed and uncommitted together — grouped by branch and directory. The projects panel draws each project's diff the same way; the diff tree is for seeing every branch at once.

```
Git Diff                      main

▾ claude-plugin
  ▾ main
    ▾ autoload/claude
      [✚|✹] difftree.vim
      [✚]   panel.vim
      [ |✭] scratch.vim
    ▾ doc
      [✹]   claude.txt
  ▾ hotfix/e947 (wt-hotfix)
    ▾ autoload/claude
      [✹]   input.vim
  ▾ feature/agent-session-panel (no worktree)
    ▾ autoload/claude
      [✚]   session.vim
      [✚]   sidebar.vim
```

One row per **branch**, directly under the repository. A worktree holds exactly one branch, so it never needs a level of its own — it is named in the label instead:

| Label | Meaning |
|---|---|
| `main` | checked out in the repository's main worktree |
| `hotfix/e947 (wt-hotfix)` | checked out in a linked worktree of that name |
| `feature/x (no worktree)` | has commits but no checkout anywhere — committed changes only |

[Projects](#projects) are drawn the way they sit on disk instead, after your own branch: the project, then its worktree folder, diffed against the project's baseline. `d` on either row deletes the project and `D` force-deletes it:

```
▾ panel/
  ▾ claude-plugin/
    ▸ autoload/
```

The branch you are actually sitting on comes first. It is what shows *your* uncommitted work: a branch has no committed changes against itself, so on the base branch every other rule would skip your checkout and the panel would come up empty. When a branch is the base, the committed half is compared against its upstream instead, so unpushed commits still show. A row disappears when it has nothing to report.

Branch names are **yellow**, except a branch with no remote-tracking branch — work that exists only on your machine — which is **grey**. In the status glyphs, added is **green** and removed is **red**, taken from your `DiffAdd` and `DiffDelete` colours.

Each branch can diff against a base of its own: press `b` on a branch row to set it, or clear it with an empty answer (`:ClaudeDiffBase` does the same). The choice persists across Vim restarts in `g:claude_difftree_store`, keyed by repository. `B` sets a session-wide default for branches with no base of their own. A branch on a non-default base shows it in brackets: `[feature/alpha] feature/delta (beta)`. A project's baseline, moved with `b` in the projects panel, replaces any such override on its branch, so the two never disagree.

The branches listed are the union of every worktree, every branch a Claude session has run on (live or closed, taken from the session registry), and the branch you are on now. That is the point: a branch Claude worked on stays visible after you move off it. A branch no longer checked out anywhere is marked `(no worktree)` and dimmed. It shows **committed changes only** — with no working tree there is nothing to be dirty, so its second indicator slot is always blank.

Each row carries a bracketed field with **two slots**. The first says what the branch did to the file relative to the base; the second what the working tree has done since:

| Field | Meaning |
|---|---|
| `[✚]` | added on this branch, clean in the working tree |
| `[✹]` | modified on this branch, clean in the working tree |
| `[ \|✹]` | untouched by the branch, modified in the working tree |
| `[✚\|✹]` | added on this branch **and** modified since |
| blank | neither |

The empty slot is kept when only the working tree changed — a lone `[✹]` could not say which of the two slots it came from.

The glyphs come from [nerdtree-git-plugin](https://github.com/Xuyuanp/nerdtree-git-plugin), so the diff tree and NERDTree describe git state in the same alphabet:

| Column | Git letter | Status | Glyph | ASCII | Colour source |
|---|---|---|---|---|---|
| branch vs base | `A` | Staged | `✚` | `+` | `NERDTreeGitStatusStaged` → `Function` |
| branch vs base | `M` | Modified | `✹` | `*` | `NERDTreeGitStatusModified` → `Special` |
| branch vs base | `D` | Deleted | `✖` | `D` | `NERDTreeGitStatusDeleted` → `Operator` |
| branch vs base | `R` `C` | Renamed | `➜` | `R` | `NERDTreeGitStatusRenamed` → `Title` |
| working tree | `M` | Modified | `✹` | `*` | `NERDTreeGitStatusModified` → `Special` |
| working tree | `A` | Staged | `✚` | `+` | `NERDTreeGitStatusStaged` → `Function` |
| working tree | `D` | Deleted | `✖` | `D` | `NERDTreeGitStatusDeleted` → `Operator` |
| working tree | `R` `C` | Renamed | `➜` | `R` | `NERDTreeGitStatusRenamed` → `Title` |
| working tree | untracked | Untracked | `✭` | `!` | `NERDTreeGitStatusUntracked` → `Comment` |
| either | — | none | blank | blank | — |

`A → Staged` is nerdtree-git-plugin's own rule (`x =~# '[MA]'`), not an invention here.

If the plugin is installed, its `gitstatus#getIndicator()` is called directly, so `g:NERDTreeGitStatusUseNerdFonts` and any `g:NERDTreeGitStatusIndicatorMapCustom` you set carry over automatically. Without it, an embedded copy of its defaults is used. `g:claude_panel_ascii` selects its ASCII set.

Colours prefer the plugin's own `NERDTreeGitStatus*` groups when its syntax file has been sourced, falling back to the groups it links them to — so restyling one restyles the other. A link you set yourself is never overwritten.

> **Limitation:** the tree uses `git diff --name-status`, not `git status --porcelain`, so staged-but-uncommitted work cannot be told apart from unstaged (both show `✹`/`✚` by letter, not by index state), and `═ Unmerged` never appears. Ignored and clean files are not listed at all.

## Choosing an agent

Sessions can run Claude or [Pi](https://github.com/earendil-works/pi). Everything else is the same for both: the panel lists them together, names and resumes them the same way, and a project can hold one of each.

| | |
| --- | --- |
| `<leader>pn`, `:PiNew [project:] [name]` | Start a Pi session, whatever the default is |
| `<leader>cn`, `:ClaudeNew [project:] [name]` | Start one on the default agent |
| `n` on a session row | Starts another on the agent the cursor is on |
| `n` on any other row | Asks which agent, when more than one is installed |

A row shows which agent it is running only while the panel is listing more than one, so a Claude-only panel reads exactly as it did. `/pi` filters to Pi sessions.

Claude keeps its own settings under the names it always had — `g:claude_cmd`, `g:claude_models`, `g:claude_panel_working_pat`, `g:claude_panel_waiting_pat` — and a `vimrc` that sets none of the agent options behaves exactly as before.

> **Note:** `:ClaudeModel` offers a numbered list only when the agent has one. Pi ships none, so it sends a bare `/model` and lets Pi open its own picker; set `g:claude_providers.pi.models` to get the list here instead.

## Model switching

`:ClaudeModel` (or `<leader>cm`) shows a numbered picker and switches models without interrupting the conversation. Opens a new session first if none is running. The list belongs to the session's agent — `g:claude_models` for Claude, `g:claude_providers.pi.models` for Pi, which ships none and so opens Pi's own picker instead (see [Choosing an agent](#choosing-an-agent)).

## Configuration

All settings are optional; the values below are the defaults. Add them to your `vimrc`:

```vim
" ── the Claude window ──
" Which edge the Claude window appears on: 'right', 'left', 'top', 'bottom'
let g:claude_split_anchor = 'right'
" Width (columns) for left/right splits, height (lines) for top/bottom splits
let g:claude_split_size = 80
" Shell command used to launch Claude
let g:claude_cmd = 'claude'
" Models shown in the :ClaudeModel picker
let g:claude_models = ['claude-opus-4-7', 'claude-sonnet-4-6', 'claude-haiku-4-5-20251001']
" -1 probes `claude --help` for --session-id/--name once; 1 forces them on, 0 off
let g:claude_session_flags = -1

" ── agents ──
" Which CLI a new session runs by default, and per-agent overrides
let g:claude_provider = 'claude'
let g:claude_providers = {}            " e.g. {'pi': {'cmd': 'pi --thinking high'}}

" ── sessions ──
" Where session names are stored. Empty = data/sessions.json inside the
" plugin directory, which a plugin update will wipe.
let g:claude_session_store = ''
" 0 = ask nothing when starting a session: no project, no agent, no name
let g:claude_session_prompt_name = 1

" ── projects ──
" Where projects (git worktrees) are checked out. Empty means .vim-workspace
" inside the repository; an absolute path keeps them outside it.
let g:claude_project_dir = ''
" Fetch the default branch before cutting a new project from it.
let g:claude_project_fetch = 1
" Where projects are remembered. Empty means data/rooms.json inside the
" plugin directory.
let g:claude_project_store = ''
" Put in front of a new project's branch name, e.g. 'feature/'.
let g:claude_project_branch_prefix = ''
" (g:claude_room_dir / _fetch / _store are the older names and still work;
" a g:claude_project_* setting wins over its room twin.)

" ── the projects panel ──
" Width, edge, and how often status is polled while it is open
let g:claude_panel_width = 35
let g:claude_panel_anchor = 'left'
let g:claude_panel_refresh_ms = 2000
" 1 opens the panel when Vim starts
let g:claude_panel_auto_open = 0
" Key that raises or dismisses the panel; '' leaves it unmapped
let g:claude_sidebar_toggle_key = '<C-a>'
" Status glyphs, merged over the defaults; 1 forces the [A]/[I]/[C] ASCII set
let g:claude_panel_icons = {}
let g:claude_panel_ascii = 0
" Seconds of silence before a running session is shown as idle. Only consulted
" when the bottom of the terminal says nothing conclusive
let g:claude_panel_idle_secs = 30
" What the bottom of a Claude terminal looks like while it works, and while it
" waits for you. The second is what fills the "Needs you" group.
let g:claude_panel_working_pat = 'esc to interrupt'
let g:claude_panel_waiting_pat = '\%(^\|\n\)\s*❯\=\s*1\.\s\|Do you want\|(y/n)'
" Agent-hook state files, which report work a terminal never prints. Set to 1
" once :SessionPanelHookSetup has installed the writers.
let g:claude_panel_hook_state = 0
" Empty follows the writer: $XDG_RUNTIME_DIR/claude-vim-status, else /tmp.
let g:claude_panel_hook_state_root = ''
" A backstop for a writer that died mid-state, not a freshness window.
let g:claude_panel_hook_state_ttl_secs = 900
" Finished sessions: days before one is buried, how many the Done group draws,
" whether to list them at all, and how many are read from disk per project
let g:claude_panel_stale_days = 2
let g:claude_panel_done_rows = 10
let g:claude_panel_show_closed = 1
let g:claude_panel_closed_limit = 10

" ── the sidebar column ──
" Share one column with the diff tree and NERDTree (panel on top)
let g:claude_panel_nerdtree_stack = 1
" Column heights, as a percentage of the screen; the bottom sidebar takes the
" rest. Set a percentage to 0 to size that sidebar in lines instead.
let g:claude_panel_height_pct = 25
let g:claude_difftree_height_pct = 40
let g:claude_panel_height = 15
let g:claude_difftree_height = 15

" ── the git diff tree ──
" Width when it is the only sidebar
let g:claude_difftree_width = 35
" Branch to diff against. Empty auto-detects: origin/HEAD, then main, then master
let g:claude_difftree_base = ''
" Include untracked files; re-run git on :write; merge single-child directories
let g:claude_difftree_show_untracked = 1
let g:claude_difftree_auto_refresh = 1
let g:claude_difftree_collapse_dirs = 1
" Where per-branch bases are remembered. Empty = data/difftree.json in the plugin
let g:claude_difftree_store = ''

" ── everything else ──
" 1 uses numbered lists instead of popups and fzf for every picker
let g:claude_no_popup = 0
" Set to 1 to disable all default mappings
let g:claude_no_default_mappings = 0
```

## Help

Full documentation is available inside Vim:

```
:help claude
```

## License

MIT
