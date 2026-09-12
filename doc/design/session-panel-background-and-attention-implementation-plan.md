# Implementation plan: background work and attention states

Status: **proposed**

This plan operationalizes `doc/design/session-panel-background-and-attention.md`
for both bundled providers: Claude Code and Pi.

## 1. Current-state assessment

The core status model is already implemented for **both providers**.

| Capability | Claude | Pi | Evidence |
|---|---|---|---|
| Four statuses (`waiting`, `active`, `idle`, `closed`) | Implemented | Implemented through the same classifier | `autoload/claude/session.vim`: `s:classify(tail, provider)` and `claude#session#status(id)` |
| Provider-specific patterns | Claude globals | Pi spec defaults and per-provider override | `claude#provider#claude#spec()`, `claude#provider#pi#spec()`, `claude#provider#get()` |
| Needs-you grouping and glyph | Implemented | Shared panel behavior | `autoload/claude/panel.vim` |
| Quiet, recognized background work remains active | Implemented when its working pattern matches | Implemented when `to interrupt` matches | `s:working_pat(provider)` and `s:classify()` |
| Safe no-match fallback | Recent output → `active`, later → `idle` | Same | `claude#session#status(id)` |
| Provider-isolation regression coverage | Present for Claude | Missing dedicated coverage | `test/session_state.vader`; no `test/provider_classify.vader` |

`claude#session#status(id)` first resolves process liveness, then calls
`s:classify(get(rec, 'term_tail', ''), claude#provider#of(rec))`. The
classifier checks the provider's working pattern before its waiting pattern;
otherwise the existing `last_active` / `g:claude_panel_idle_secs` fallback
applies. This correctly prevents a quiet, still-running terminal with a visible
working footer from being grouped as Idle.

The state UI is likewise already in place: `claude#panel#icon(status)` includes
`waiting`, syntax contains `ClaudeSessionWaiting`, and the state view renders
Needs you before Working, Idle, and Done. The Pi provider supplies
`working_pat: 'to interrupt'` and a tentative `waiting_pat`.

### Remaining scope

No broad panel or classifier rewrite is justified. The remaining gap is
**confidence and verification of Pi's attention signal**:

- Pi's `waiting_pat` is an unverified heuristic, documented as such in
  `doc/design/pi-cli-implementation.md`.
- No dedicated test proves that Pi patterns are selected for Pi records and
  that Claude overrides cannot leak into Pi classification.
- Pi's real tool-approval and question tails have not been captured, so the
  current pattern can either miss a prompt (safe fallback to Idle) or produce a
  false Needs-you result.

## 2. Shared invariants

Any option must preserve these rules:

1. A missing/non-running job is `closed`.
2. A provider-specific current working signal is `active`, even after the idle
   timeout.
3. A provider-specific current input-request signal is `waiting`.
4. Working wins over waiting when both match the sampled tail.
5. A running session with no recognized current signal remains `active` only
   while output is recent, then becomes `idle`.
6. Claude settings (`g:claude_panel_working_pat` and
   `g:claude_panel_waiting_pat`) remain Claude-only. Pi settings are supplied
   through `g:claude_providers.pi.working_pat` and `.waiting_pat` and merged by
   `claude#provider#get('pi')`.
7. `waiting` remains presentation-compatible with the existing state view,
   place view, glyph maps, highlights, counts, and full-render path for rows
   moving between state groups.

## 3. Implementation options

### Option A — verify and tune Pi's existing provider patterns (recommended)

This is a narrow evidence-driven change: retain the existing classifier and
provider seam, capture actual Pi terminal tails, then adjust only Pi's default
patterns and tests if evidence requires it.

#### Files and seams

| File | Change |
|---|---|
| `autoload/claude/provider/pi.vim` | Potentially revise only `working_pat` and `waiting_pat` in `claude#provider#pi#spec()`. |
| `test/session_state.vader` or new `test/provider_classify.vader` | Add provider-selection, override-isolation, and Pi-tail classification coverage through `claude#session#_classify(tail, provider)`. |
| `doc/claude.txt` and `README.md` | Document Pi-specific pattern overrides only if defaults or supported behavior change. |
| `doc/design/pi-cli-implementation.md` | Mark the waiting-prompt uncertainty resolved only after a manual capture verifies it. |

#### Steps

1. Run Pi sessions that exercise ordinary work, a numbered choice/confirmation,
   and tool approval. Capture only the bottom rows that `s:term_tail()` reads.
2. Classify each capture against `claude#provider#pi#spec()` defaults using the
   `claude#session#_classify()` test seam.
3. Keep `working_pat: 'to interrupt'` if it matches Pi's active footer;
   otherwise replace it with the narrowest observed stable footer.
4. Set `waiting_pat` only to observed Pi prompt forms. Do not import a
   Claude-specific phrase merely because it looks plausible.
5. Add tests for Pi working, Pi waiting, ambiguous/no-match, and both-match
   precedence. Assert that overriding Claude globals changes Claude only, while
   `g:claude_providers.pi` changes Pi only.
6. Re-run `make test`; manually verify state and place views with one Claude
   and one Pi session.

#### Detection and fallback

Pi continues to use `s:classify(tail, 'pi')`, which obtains patterns from
`claude#provider#get('pi')`. A verified working footer yields `active`; a
verified question/approval marker yields `waiting`; no match remains on the
existing output-age fallback. Until a Pi prompt is verified, it is preferable
for Pi to miss Needs you than to classify arbitrary transcript text as waiting.

#### Effects, benefits, and risks

No panel code changes are expected: `waiting` already has icons, highlighting,
grouping, counts, and redraw behavior. This option has minimal maintenance cost
and preserves provider isolation. Its limitation is unavoidable heuristic
accuracy: a Pi release may change terminal wording. A narrow pattern favors
false negatives (Idle fallback) over disruptive false positives (Needs you).

### Option B — add explicit per-provider classifier hooks

Extend the provider contract with an optional `classify_tail(tail)` hook. The
session layer would delegate first to that hook, then use generic configured
patterns and the existing idle-time fallback.

#### Files and seams

| File | Change |
|---|---|
| `autoload/claude/provider.vim` | Document the optional `classify_tail({tail})` hook and its empty-result fallback. |
| `autoload/claude/provider/claude.vim` | Optionally implement a hook that retains Claude pattern semantics. |
| `autoload/claude/provider/pi.vim` | Implement Pi-specific prompt/working parsing. |
| `autoload/claude/session.vim` | Update `s:classify(tail, provider)` to call `claude#provider#call()` before generic pattern matching. |
| `test/provider_classify.vader` | Add hook dispatch, empty-result fallback, precedence, and cross-provider isolation tests. |
| Provider design/docs | Document the new extension point and overrides. |

#### Steps

1. Define the hook contract: return `active`, `waiting`, or `''`; never return
   `idle` or `closed`, which remain session-layer lifecycle decisions.
2. Update `s:classify()` to call the provider hook safely, accepting `''` as
   “cannot tell.”
3. Move only genuinely provider-specific parsing into the two provider modules.
   Retain configured pattern fallback so users can adapt to CLI output changes.
4. Add fixtures from real Claude and Pi tails, then test all hook outcomes and
   the generic fallback.
5. Confirm the existing state grouping uses returned values unchanged.

#### Detection and fallback

Each provider can parse richer multi-line structures than a single regex, but
an absent or uncertain hook returns `''`, then the existing patterns and idle
timer apply. This keeps a provider module from claiming process liveness or
changing `closed` behavior.

#### Effects, benefits, and risks

The UI is unchanged. This approach is extensible for future CLIs and can
express Pi-specific approval layouts precisely. It costs more API surface,
requires stronger provider-contract tests, and risks duplicating user-configured
patterns. It is disproportionate unless real Pi tails cannot be represented
reliably by the current patterns.

### Option C — introduce explicit prompt-state tracking in polling

Have `claude#session#poll()` record a provider-classified state and the time it
was last observed, instead of deriving solely from the latest `term_tail` in
`claude#session#status()`.

#### Files and seams

| File | Change |
|---|---|
| `autoload/claude/session.vim` | Extend record creation, polling, and status evaluation with transient classified-state fields. |
| `autoload/claude/panel.vim` | Audit repaint/full-render behavior for persisted state transitions. |
| `test/session_state.vader`, `test/panel_groups.vader` | Add transition, stale-prompt, and timer-expiry tests. |
| Store code, only if state is persisted | Avoid persistence unless a separate requirement proves it necessary. |

#### Steps

1. Add transient `observed_state` and `observed_at` fields to live records.
2. Update them during `claude#session#poll()` only when a current provider
   signal is observed.
3. Define expiry rules so an old `waiting` cannot survive after Pi or Claude
   resumes work.
4. Make `status()` consume the transient state before applying the idle timer.
5. Test all transition paths and panel relocation.

#### Detection and fallback

Classification remains provider-specific, but the status can survive terminal
redraw quirks for a bounded interval. Once the observation expires, it must
return to the current generic classifier and output-age fallback.

#### Effects, benefits, and risks

This may improve stability where terminal tails flicker, but it is the highest
complexity option. Incorrect expiry can leave a session falsely demanding
attention; it also expands record invariants and redraw testing. Do not choose
it without evidence that Option A cannot handle real Pi output.

## 4. Comparison and recommendation

| Criterion | A: tune patterns | B: classifier hooks | C: tracked state |
|---|---:|---:|---:|
| Uses existing provider design | High | Medium | Medium |
| Pi-specific accuracy potential | Medium | High | Medium |
| New complexity | Low | Medium | High |
| Risk of stale Needs-you state | Low | Low | High |
| User override compatibility | High | Medium | High effort |
| Appropriate for verified remaining gap | **High** | Low until needed | Low |

Recommend **Option A**. The architecture already carries provider-specific
patterns through `claude#provider#get()` and `s:classify(tail, provider)`, and
the panel already understands `waiting`. The missing work is Pi evidence and
provider-isolation coverage, not a missing abstraction. Reconsider Option B
only if captured Pi states require structural parsing that narrow configurable
patterns cannot express.

## 5. Phased execution plan

### Phase 1 — establish Pi terminal evidence

Capture Pi bottom-tail output during background work and each user-attention
flow that Pi supports.

**Acceptance criteria:** captures distinguish current working text from prompt
text; uncertain or absent forms are recorded as unsupported rather than guessed.

### Phase 2 — codify provider-isolation tests

Add `test/provider_classify.vader` (or an equivalently focused section in
`test/session_state.vader`) for Claude and Pi classification, working-over-
waiting precedence, and independent overrides.

**Acceptance criteria:** Pi's `to interrupt` signal is active; Pi waiting
fixtures are waiting only when verified; Claude globals do not alter Pi;
`g:claude_providers.pi` does not alter Claude.

### Phase 3 — tune only evidence-backed Pi defaults

If Phase 1 identifies a mismatch, update
`claude#provider#pi#spec()` in `autoload/claude/provider/pi.vim`; otherwise
make no production change.

**Acceptance criteria:** all captured Pi cases classify correctly; unmatched Pi
tails retain recent-output and idle-time fallback; no Claude behavior changes.

### Phase 4 — panel and regression verification

Exercise mixed Claude/Pi sessions in Needs you, Working, Idle, and Done and
run the full Vader suite with `make test`.

**Acceptance criteria:** waiting sessions render under Needs you with the
existing waiting glyph/highlight and count; state changes relocate rows on
redraw; place view retains its tree; all tests pass.

## 6. Assumptions and open questions

- Pi's active footer `to interrupt` is currently treated as an observed but
  non-contractual signal.
- Pi's approval/question terminal layout remains unverified until captured from
  a real Pi CLI session.
- No stable Pi machine-readable API or live-holder registry is assumed; this
  plan deliberately avoids adding external polling.
- If Pi's prompt UI does not expose a stable terminal-tail marker, the correct
  behavior is the existing conservative fallback, not a fabricated Needs-you
  state.
