---
name: dream-reviewers
description: |
  Validate the agent reviewers that gate a project's quality (the pr-review-loop
  roster). Mine every PR's review threads + the dream-marker stream into
  per-reviewer scorecards (acceptance rate, false-positive/won't-fix/reopen
  rates, taste overrides), then propose roster changes (keep / refine / retire).

  Use when: (1) the user asks to validate/audit/tune their PR reviewers or
  AGENT-REVIEWERS.md, (2) deciding whether a reviewer earns its keep or should be
  retired/refined, (3) a periodic reviewer-health pass. For mining general
  session lessons, use the `dream` skill instead.
argument-hint: "(optional) project dir"
---

# Dream — reviewer validation

The PR review loop is the project's main quality gate. This scores each reviewer
from real history and proposes roster tuning. Propose-only — never auto-edit the
quality gate.

Read [`references/MARKER-CONTRACT.md`](../../references/MARKER-CONTRACT.md): the
**marker stream is the authoritative source**. pr-review-loop emits one marker per
finding+disposition (durable, unbiased, records who dispositioned it). GitHub and
the log harvest are backfill for un-instrumented history.

## 0. Locate scripts

```
Glob: **/plugins/dream/scripts/dream    OR   **/dream/*/scripts/dream
```
Run from the project dir (or set `DREAM_PROJECT_DIR`). Needs `gh` authed for the
GitHub backfill.

## 1. Build the finding sources

```bash
# Authoritative: dream-marker stream (what pr-review-loop emits going forward)
<scripts>/dream reviews-synth --source markers     # → scorecards from markers

# Backfill for history that predates markers:
<scripts>/dream reviews-distill                    # mine all PR review threads (GitHub)
<scripts>/dream reviews-synth --source all         # markers + GitHub merged
<scripts>/dream reviews-coverage                   # firing coverage from logs (UNBIASED)
<scripts>/dream reviews-harvest                    # durable log <result> + /tmp findings
```

**Mind the bias.** GitHub holds only *posted* findings (the loop historically
skipped posting), so `--source github` UNDER-counts. `reviews-coverage` (every
Agent spawn) is the complete, unbiased firing record — use it to contextualize
acceptance rates ("fired 353× but only N findings posted"). Outputs land in
`~/.dream/<slug>/reviews/` (`SCORECARDS.md`, `COVERAGE.md`).

Metrics per reviewer: `acceptance_value` (was it RIGHT — valid/total resolved),
`acceptance_fixstrict` (did it drive a CHANGE), `false_positive_rate`,
`wont_fix_rate`, `unresolved_rate`, `reopened`, and `taste(user)` (dispositions
the OPERATOR made — only markers carry this).

## 2. Propose roster changes (YOU, or a spawned Opus Task)

Read `reviews/scorecards.json` + `coverage.json` + the reviewer definitions
(`AGENT-REVIEWERS.md` at root and in subtrees; the 6 pr-review-loop plugin
defaults are config-only, not file-editable). If the project has `DECISIONS.md`
file(s), read them too: a low-fix reviewer that enforces a *documented invariant*
(cite the decision) is a **guardian KEEP**, not noise — and if a reviewer's rule
contradicts a current decision, that is `DECISIONS.md` drift worth flagging
(propose-only, alongside the roster). For each reviewer decide:

- **KEEP** — earning its keep (high value, healthy fix rate). Note: high-value /
  low-fix "guardian" reviewers (invariant confirmations that get *acknowledged*,
  not *fixed*) are KEEPs, not noise — read contested examples to tell them apart.
- **REFINE** — a prompt or "When to spawn" tweak. Quote the current text, give the
  revised text, ground it in contested findings.
- **RETIRE / DOWNWEIGHT** — persistent low acceptance / high won't-fix. Recommend
  `disabled` (config) or narrowed scope. Be cautious below ~5 findings (low signal).

Weight `taste(user)` heavily — an operator overruling a reviewer is the strongest
signal. Keep the detailed scorecards/coverage artifacts in `~/.dream/<slug>/reviews/`
(`SCORECARDS.md`, `COVERAGE.md`, `scorecards.json`) as backing data.

## 3. Promote

Write the human-facing roster proposals to **one self-contained per-run file**:
`~/.dream/<slug>/review/pending/<YYYYMMDD>-reviewers.md` (today's date; **overwrite**
if a run already wrote it today — do NOT append). This shares the `review/pending/`
queue the SessionStart hook watches and the `dream` skill writes to; the user
dismisses a run by moving its file into `review/reviewed/` (or deleting it).

AGENT-REVIEWERS.md edits and `# Configuration` `disabled` changes are
**propose-only** — this is the quality gate; the user approves every change. Any
`DECISIONS.md` drift you spot is propose-only too. Product-only observations →
the issue tracker, not the roster.
