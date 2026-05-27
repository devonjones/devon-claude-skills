---
name: pr-review-loop
description: |
  Manage the PR review feedback loop: monitor CI checks, fetch review comments, and iterate on fixes.
  Use when: (1) pushing changes to a PR and waiting for CI/reviews, (2) user says "new reviews available",
  (3) iterating on PR feedback from Gemini, Cursor, Claude, or other reviewers, (4) monitoring PR status.

  Supports multiple review bots: Gemini Code Assist, Cursor Bugbot, and Claude agent fallback.
  Also supports custom agent reviewers defined in AGENT-REVIEWERS.md for focused reviews (security, DRY, etc.).
  Automatically detects priority levels from different bot formats and handles rate limits.
---

# PR Review Loop

## ⛔ STOP - READ THIS FIRST ⛔

### 1. Locate the scripts directory

**FIRST**, use the Glob tool to find the scripts:
```
Glob pattern: **/pr-review-loop/*/scripts/commit-and-push.sh
Path: ~/.claude/plugins/cache
```
This gives you the full absolute path to the scripts directory.

**Then use the full literal path for every script call.** For example:
```bash
/home/user/.claude/plugins/cache/devon-claude-skills/pr-review-loop/1.0.0/skills/pr-review-loop/scripts/commit-and-push.sh "msg"
```

**NEVER use variables** like `$SCRIPTS/commit-and-push.sh` — this breaks permission matching.
**NEVER use compound commands** like `export PATH=... && commit-and-push.sh` — this also breaks permissions.
**Always inline the full absolute path** in every Bash call.

### 2. No raw git commands

| ❌ FORBIDDEN | ✅ USE INSTEAD |
|--------------|----------------|
| `git commit` | `scripts/commit-and-push.sh "msg"` |
| `git commit -m "..."` | `scripts/commit-and-push.sh "msg"` |
| `git push` | `scripts/commit-and-push.sh "msg"` |
| `git push origin` | `scripts/commit-and-push.sh "msg"` |

**If you use `git commit` or `git push` directly, it will be BLOCKED.**

---

## ⚠️ Do NOT Run as a Background Task Agent

**The PR review loop MUST run in the main conversation, NOT as a background Task.**

Tasks cannot spawn sub-Tasks. If the review loop runs as a Task, agent reviewers (from
AGENT-REVIEWERS.md) will silently fail to spawn — they require the Task tool, which is
only available in the main conversation.

**What to do instead:** Execute the review loop steps directly in the main conversation.
This allows you to spawn agent reviewer Tasks in parallel (C3 of each round) while
keeping Gemini/bot comment handling inline.

Individual agent reviewers (leaf-level Tasks that don't need to spawn further Tasks)
should still be spawned via the Task tool — that works because they're called from the
main conversation, not from within another Task.

---

Streamline the push-review-fix cycle for PRs with automated reviewers.

## Supported Review Bots

| Bot | Trigger | Priority Format |
|-----|---------|-----------------|
| **Gemini Code Assist** | `/gemini review` comment | `![critical]`, `![high]`, `![medium]`, `![low]` |
| **Cursor Bugbot** | Auto on push | `<!-- **High Severity** -->`, `### Bug:` |
| **Claude** | Manual via script | `🚨`, `**Critical**`, `### Critical Issues`, `⚠️` |

Priority detection automatically parses all formats when summarizing and fetching comments.

### Priority to Exit-Condition Mapping

The quality-weighted exit condition (see ONE MORE LOOP Rule) depends on classifying findings as P1/P2 vs P3/nitpick. Use this table:

| Source label | P-level | Blocks quality-weighted exit? |
|---|---|---|
| Gemini `![critical]`, `![high]` | P1/P2 | Yes — must be resolved or merged with explicit user sign-off |
| Gemini `![medium]` | P2 if correctness/security/breaking; else P3 | Yes if correctness/security/breaking; no if style/prose |
| Gemini `![low]` | P3/nitpick | No |
| Cursor `**High Severity**`, `### Bug:` | P1/P2 | Yes |
| Claude `🚨`, `### Critical Issues`, `**Critical**` | P1/P2 | Yes |
| Claude `⚠️` | P2 if correctness/security/breaking; else P3 | Yes if correctness/security/breaking; no if style/prose |
| Agent comment, no explicit label | Infer from content: correctness/security/breaking → P1/P2; else P3 | Per inferred level |

**"Won't fix" on a P1/P2 finding does NOT resolve it on its own** — it still blocks quality-weighted exit unless either (i) the finding is reclassified to P3 with explicit justification (drop one P-level with reasoning), (ii) the finding is actually fixed in a later round, or (iii) the user explicitly signs off on the carry-forward, in which case the finding is recorded as an acknowledged unresolved item in the merge-readiness summary.

The (iii) escape valve exists so the model isn't forced to relabel a genuine "won't fix" as a reclassification: surface the finding to the user, they sign off, it's recorded in the merge-readiness summary.

**Classifying `![medium]` (Gemini's most-used label) — use these heuristics:**

- P2 (blocking): the comment describes a correctness bug, security concern, breaking change, data loss risk, or incorrect error handling. Example: *"this will return nil for empty input"*, *"missing null check could crash on production data"*, *"env var not validated before use"*.
- P3 (non-blocking): the comment describes naming, phrasing, formatting, alternative implementations of equivalent behavior, documentation polish, or preference-level style. Example: *"variable name is ambiguous"*, *"consider using map over for-loop"*, *"comment could be clearer"*.
- When ambiguous: default to P2 on the first round; downgrade to P3 only if the fix is a judgment call, not a correctness improvement.

## Comment Formats: Line Comments vs PR Comments

Different bots use different comment formats:

### Line Comments (Gemini, Cursor)
- Posted on specific lines of the diff
- Each issue is a separate comment thread
- Reply using `reply-to-comment.sh <PR> <comment-id> "Fixed"`
- Thread auto-resolves when replied to

### PR Comments (Claude)
- Single large comment on the PR (not on specific lines)
- Contains multiple issues organized by sections (e.g., "Issues & Concerns")
- Issues reference file:line locations in prose (e.g., "**Location:** `role_summaries_controller.rb:60`")
- Reply to the comment addressing multiple issues at once

**Handling Claude's PR comments:**

1. **Fetch the comment** to get the comment ID:
   ```bash
   gh pr view <PR> --json comments --jq '.comments[] | select(.author.login == "claude") | {id: .id, body: .body}'
   ```

2. **Parse issues** from the structured markdown:
   - Look for numbered headings like `### **1. BREAKING CHANGE: ...**`
   - Extract file:line references from `**Location:**` lines
   - Note priority indicators: 🚨 (critical), ⚠️ (warning), etc.

3. **Reply with a consolidated response** addressing each issue:
   ```bash
   gh pr comment <PR> --body "## Response to Claude Review

   **Issue 1 (Breaking API change):** Fixed - added deprecation support for old parameter name

   **Issue 2 (Missing validation):** Fixed - added ALLOWED_VIEW_ROLES validation

   **Issue 3 (Logic change):** Won't fix - this is intentional, documented in PR description

   **Issue 4 (Missing tests):** Fixed - added RSpec tests for SystemRoles methods
   "
   ```

4. **Individual issues** can also be addressed via separate replies if preferred:
   ```bash
   gh pr comment <PR> --body "**Re: Issue #2 (Missing Input Validation):** Fixed in commit abc123 - added validation for view_role parameter"
   ```

The key difference: Claude comments don't have "threads" to resolve - you reply to the main PR comment referencing which issues you're addressing.

## Critical: Be Skeptical of Reviews

**Not all suggestions are good.** Evaluate each review comment critically:

- Does this actually improve the code, or is it pedantic?
- Is this suggestion appropriate for the project's context?
- Would implementing this introduce unnecessary complexity?

**Skip suggestions that are:**
- Platform-specific when not applicable (Windows comments for Linux-only code)
- Overly defensive (excessive null checks, unlikely edge cases)
- Stylistic preferences that don't match project conventions
- Adding documentation for self-explanatory code

When in doubt, ask the user rather than blindly applying changes.

### Self-Contradiction Detection

Track changes across rounds. When a fix in round N reverses or conflicts with a fix from a previous round, this signals that the review loop may be degrading the code rather than improving it.

**When a contradiction is detected:**

1. **Identify all involved changes**: List the original code, the round N-K change, and the round N change that contradicts it.
2. **Analyze both positions**: Each round may have had valid reasoning. Assess whether the later round caught a genuine mistake in the earlier fix, or whether the loop is oscillating.
3. **Check against the original**: Compare both the round N-K and round N versions against the original pre-review-loop code. Often the original is the correct version.
4. **Report to the user** with a clear summary: what changed, what contradicted it, your assessment of which version is correct and why, and a recommendation.
5. **Do not silently apply the contradicting change.** Pause and get user input.

**Parallel valid findings**: Multiple reviewers may independently flag different aspects of the same code. This is not a contradiction — it's convergent analysis. The key distinction is whether round N is *undoing* round N-K's work (contradiction) vs. addressing a *different concern* in nearby code (parallel findings).

## Pattern Analysis: Sweep Before Fixing

When Gemini (or any reviewer) raises a finding, ask: **is this finding symptomatic of a broader pattern, or is it truly isolated?** Acting on this question before fixing prevents the same pattern from appearing in multiple subsequent rounds.

### Batch Before Acting

**Do not fix comments one-at-a-time.** After collecting all comments for a round (Gemini + other bots + agents), list them together before editing any file:

1. Identify patterns across comments (same issue type, multiple files or lines) — plan one sweep fix, not N individual fixes.
2. For each planned fix, re-read the new text through each active agent's lens *before* staging: would code-reviewer flag this phrasing? Would comment-analyzer flag a stale assertion? Revise until the fix itself wouldn't draw a new comment.
3. Commit once per round, not once per comment. Note deliberate trade-offs in the commit message body so reviewers see the reasoning rather than re-flagging it.

### Indicators of a Broader Pattern

A finding is likely a pattern when:
- It is about a code/naming style (camelCase vs kebab-case, `.foo[]` vs `.foo[]?`, etc.) — style issues almost always recur across files
- It is about a consistency rule between files (file A has updated terminology that file B hasn't adopted) — consistency gaps spread
- It is about a structural anti-pattern in examples (missing error handling, incorrect operator usage) — structural patterns repeat
- The comment body says "similar to X elsewhere" or "for consistency with Y"

A finding is likely isolated when:
- It is a specific factual error at one location (e.g., a wrong version number) — unlikely to recur in the same way
- It is about a single missing detail unique to one code path
- It is a judgment call about documentation tone

### When a Finding Targets Unchanged Content

If a reviewer flags an issue on content **not modified in recent pushes**, their initial review pass was incomplete:

1. **Widen the sweep to the full original PR diff** — not just recently-changed files.
2. **Consider an explicit full-diff review trigger**: push-triggered auto-reviews anchor on recently-changed files. Posting an explicit `/gemini review` comment (or `trigger-review.sh <PR> --wait`) prompts a review of the full PR diff and can surface remaining issues sooner.

### When a Finding Looks Like a Pattern

Before replying to the reviewer or making the fix:

1. **Sweep all changed files** (and closely related files) for the same pattern using grep or a targeted search.
2. **Fix all occurrences in one commit** rather than one per reviewer round. Multiple rounds for the same pattern means this step was skipped.
3. **Decide whether to re-run a targeted agent-reviewer**:
   - Re-run if: the pattern was something the agent was supposed to catch (e.g., code-reviewer for guideline violations, silent-failure-hunter for error handling) AND enough new lines were added or changed that a targeted re-run adds coverage
   - Skip re-run if: the agent already ran and addressed this area, and the fix is narrow enough that no new review surface was introduced

### Examples

| Reviewer Finding | Pattern Type | Sweep Action |
|---|---|---|
| `.items[]` should be `.items[]?` in `config.yaml` | Style/structural | Grep all changed files for `.items[]` without `?` |
| `userName` should be `user-name` in `api.md:42` | Naming style | Grep all changed files for `userName` |
| Field added to schema in `models.py` but the docs in `README.md` still show the old shape | Cross-file consistency | Check related diagrams/tables in all files modified by the PR |
| Wrong version number at one location | Isolated factual | Fix in place; no sweep needed |

## Stopping Heuristics

Use signal quality — not a fixed round cap — to decide when to stop iterating.

### Per-Round Assessment

After each round, evaluate:

| Metric | What It Means |
|--------|---------------|
| **Fix/rejection ratio** | What fraction of comments led to actual code fixes vs. "Won't fix" responses? A declining ratio suggests diminishing returns. |
| **Severity trend** | Are new comments addressing high-priority issues (correctness, security) or low-priority nitpicks (style, documentation)? |
| **Contradiction count** | Has this round contradicted any previous round's fixes? If so, investigate before continuing. |
| **Net code quality** | Is the code measurably better than after the previous round? Or are changes lateral (different but not better)? |

### When to Continue

- The current round produced fixes for genuine correctness or security issues
- New comments are addressing aspects not previously reviewed
- The fix/rejection ratio remains above ~50% (most comments are actionable)

### When to Stop

- Two consecutive rounds with zero actionable (P1/P2) fixes — i.e., only nitpicks, only "Won't fix" responses, or zero-comment rounds
- A self-contradiction is detected (pause for user input)
- The fix/rejection ratio drops below ~25% (most comments are not actionable)
- All remaining comments are stylistic or theoretical
- The Hard Round Ceiling has fired (see below) — stop regardless of other signals

### Hard Round Ceiling (Circuit Breaker)

**If you reach 7 total rounds, STOP the loop regardless of state.** This is a pure circuit breaker — the quality-weighted exit condition (see ONE MORE LOOP Rule) handles normal termination earlier; this fires only when the loop is stuck. Report to the user:

- Rounds completed and elapsed time
- Total comments received, by priority (P1/P2/P3 — see Priority to Exit-Condition Mapping) and source (Gemini, other bots, each agent)
- Outstanding unresolved items (if any)
- A recommendation on whether to continue, declare "good enough," or escalate

Then ask the user before proceeding further.

### ONE MORE LOOP Rule

When a full round (Gemini + other bots + agent reviewers) produces no actionable feedback, do ONE additional "final verification" round to catch any last feedback from the final push.

**Actionable feedback** = a **P1 or P2** finding (per the Priority to Exit-Condition Mapping) that is addressed with a code change. "Won't fix" responses, nitpick (P3) fixes, and zero-comment rounds are NOT actionable for loop-control purposes — they all count toward exit condition (b) below.

**Unifying with stopping heuristics**: The "Two consecutive rounds with zero actionable (P1/P2) fixes" stopping heuristic and ONE MORE LOOP describe the same exit mechanism from two angles:
- The **first** qualifying round (zero actionable fixes — i.e., only nitpicks, only "Won't fix", or zero comments) IS the ONE MORE LOOP trigger.
- The **second** qualifying round IS the final verification — if the full Exit condition (quality-weighted) below is satisfied (all of (a) through (d)), you exit immediately at end of that round. No third round needed.

**Tracking state**: Use `TaskCreate` to track whether you're in the "final verification round". Create a task like "Final verification round - if no actionable feedback, ready to merge".

**Reset condition**: If the final verification round produces **P1 or P2 fixes** (correctness, security, breaking changes — see Priority to Exit-Condition Mapping), remove the "final verification round" todo — you need a fresh "one more" after pushing those fixes. Nitpick-level (P3) fixes do NOT reset the counter.

**Exit condition (quality-weighted)**: You're done when ALL of:
- (a) **No P1/P2 findings** (correctness, security, breaking changes) in the last round
- (b) **The last two rounds had zero actionable (P1/P2) fixes** — i.e., they contained only nitpicks, were zero-comment rounds, or all feedback was "Won't fix"
- (c) **No contradictions across rounds**
- (d) **No unresolved P1/P2 Won't-fix findings carried forward from any prior round** — every Won't-fix on a P1/P2 must have been either (i) reclassified to P3 with explicit justification per the Priority Mapping rule, (ii) actually fixed in a later round, or (iii) explicitly signed off on by the user as an acknowledged carry-forward (recorded in the merge-readiness summary). Carried-forward Won't-fix on a real P1/P2 without one of these three resolutions blocks exit regardless of (a) and (b).

— **OR** the Hard Round Ceiling has fired (see above).

Proceed to merge readiness checks.

## Merge Readiness

When the review loop is complete, check CI status and read repo-specific merge guidance before proceeding.

### 1. Check CI Status

```bash
gh pr checks <PR> --watch
```

Do not proceed to merge if any checks are still running or failing. If CI is still running or newly failing at this point, fall back to the [CI Fix Loop](#ci-failure-handling) to diagnose and fix before reporting readiness.

### 2. Read Repo-Specific Merge Guidance

Read the repo's `CLAUDE.md` and follow any linked files it references (e.g., `.ai-knowledge/code-review-guidelines.md`). These define the repo's merge policy — what approvals are required, whether auto-merge is permitted, attestation requirements, and any other merge criteria.

Use whatever you find to determine:
- Whether this PR is ready to merge or needs further action
- Whether to merge automatically or ask the user
- What information to include in a merge-readiness summary

### 3. Prepare Merge-Readiness Summary

Always prepare a summary of what the review loop did and observed:

- **Review loop activity**: Rounds completed, total comments addressed (fixed / won't fix / out of scope)
- **CI status**: All checks passed, any failures, any checks still running
- **Unresolved items**: Any review comments that remain open or contested
- **Self-contradictions**: Any detected during the loop and how they were resolved
- **Beads tickets**: Out-of-scope items captured for follow-up
- **Branch protection status**: Whether all required checks and approvals are satisfied
- **Stale defaults pin bypass** (if `--skip-stale-check` was used): note the config and current plugin versions; recommend running `/pr-review-loop:audit-agents`
- **Validator activity** (if `independent_validator.enabled`): per-flagger acceptance rate (`X of Y findings posted; Z dropped as INVALID; W posted with [validator: uncertain]`). A flagger with persistent low acceptance is a candidate for retirement or prompt refinement.

If repo-specific guidance defines additional merge criteria (attestation requirements, approval types, etc.), include the status of those criteria in the summary as well.

### 4. Merge or Ask

- **If repo guidance authorizes auto-merge** and all its criteria are met (CI passed, required approvals present, branch protections satisfied): merge
- **If any criteria are not met**, or no repo-specific guidance exists: present the summary and ask the user

The review loop should **not** override branch protections or bypass repo-defined merge requirements.

## Autonomous Loop Workflow

**CRITICAL RULES - NEVER VIOLATE THESE:**
1. **ALWAYS use full absolute paths for scripts** - Glob once to find the scripts directory, then inline the full path in every Bash call. NEVER use variables or compound commands (see setup at top of document)
2. **ALWAYS use `commit-and-push.sh`** - NEVER `git commit` or `git push` (see table at top of document)
3. **ALWAYS reply to EVERY comment**:
   - Line comments (Gemini, agents): use `reply-to-comment.sh`
   - PR comments (Claude): use `gh pr comment` with consolidated response
4. **ALWAYS use `--wait` flag** when checking for comments - this ensures proper 5-minute polling
5. **PR creation automatically triggers Gemini review** - use `get-review-comments.sh --wait` to wait for the first review

### Pre-Loop Setup (do once, before round 1)

1. **Discover and merge agents.** Run `scripts/discover-agents.sh <PR>` once. Its output includes:
   - The full merged agent list (defaults + user agents per C+E semantics)
   - The `configuration` block with `stale_pin`, `defaults_version_checked`, `current_plugin_version`, counts
   - The `language_detection` block (`null` when the repo already has any `AGENT-REVIEWERS.md`; otherwise `{matched: [...], same_directory_polyglot: bool}`)
2. **Offer language templates** (only when `language_detection != null` AND `language_detection.matched` is non-empty). See "Language Template Offer" below for the full flow.
3. **Check the stale pin.** If `configuration.stale_pin` is `true` AND `--skip-stale-check` was not passed:
   - Emit the stale-pin message (see "Stale Pin Detection" above) with current and pinned versions
   - **Exit non-zero.** Do NOT proceed to round 1.
   - Note: when step 2 just installed a template, `install-template.sh` pinned `defaults_version_checked` to the current plugin version, so the stale-pin check passes by construction.
4. **Emit the spawning summary.** Once cleared to proceed, log a one-line summary of which agents will run (see "Spawning Summary" above).
5. **Track --skip-stale-check usage.** If the bypass flag was used, remember to include the bypass note in the final merge-readiness summary.

After setup, proceed to The Loop.

### The Loop

**⚠️ CRITICAL: Each round includes ALL reviewer types before triggering the next cycle.**

**DO NOT** run multiple Gemini rounds before checking other reviewers. After addressing Gemini comments, you MUST check for other bot comments and run agent reviewers BEFORE triggering another Gemini review. This interleaving is essential because:
- Fixes made for Gemini may resolve issues other reviewers would have flagged
- Running all Gemini rounds first makes other reviewer feedback stale and irrelevant

```
EACH ROUND — three phases, in order:

  COLLECT PHASE (no edits yet):
  ┌─────────────────────────────────────────────────────────────┐
  │ C1. Get Gemini comments (--wait only on first check)        │
  │ C2. Check for other bot PR comments (Claude, Cursor, etc.)  │
  │ C3. Run agent reviewers (defaults + AGENT-REVIEWERS.md);    │
  │     for each finding, run the independent validator         │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  ⚠️ BATCH POINT — apply "Batch Before Acting" before any edit:
  list all collected comments together, identify cross-source
  patterns, plan fixes as a group, self-review each fix through
  each active agent's lens before staging.
                              │
                              ▼
  FIX PHASE (apply the batched plan):
  ┌─────────────────────────────────────────────────────────────┐
  │ F1. Apply + reply to Gemini comments                        │
  │ F2. Apply + reply to other bot comments                     │
  │ F3. Apply + reply to agent comments                         │
  │ F4. Commit and push ONCE (if ANY fixes were made)           │
  │ F5. Wait for CI checks; fix failures (max 3 CI retries)     │
  │ F6. Trigger next review (--wait)                            │
  │ F7. Inspect F6's output BEFORE applying exit conditions     │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  If F6 returned new comments → next COLLECT PHASE (new round).
  Otherwise → apply quality-weighted exit condition + Hard Round
  Ceiling check (see ONE MORE LOOP Rule in Stopping Heuristics).
```

**Phase order is mandatory.** Complete all COLLECT steps (C1, C2, C3) before beginning any FIX step (F1–F7). The BATCH POINT between them is what makes Pattern Analysis (`Sweep Before Fixing`) work.

**For full step-by-step details with commands and example outputs, see [`references/round-workflow.md`](references/round-workflow.md).** The diagram above is the authoritative execution order; the reference file is the operational companion the model can read on demand when actually running a round.

**COMPLETION:**
When a full round produces no actionable feedback (Gemini + other bots + agents all stable)
AND this was the "final verification" round:
- Report all beads tickets created during the loop (if any)
- Ask user about merge

## CI Failure Handling

### CI Fix Loop

```
CI FIX SUB-LOOP (max 3 attempts per round):
┌──────────────────────────────────────────────────┐
│ 1. Run check-ci.sh <PR> --wait                   │
│ 2. If passed → continue to trigger next review    │
│ 3. If failed:                                     │
│    a. Read the failure logs from check-ci output  │
│    b. Diagnose the root cause                     │
│    c. Apply a MINIMAL, TARGETED fix               │
│    d. commit-and-push.sh "fix: CI failure desc"   │
│    e. Go to step 1 (decrement retry counter)      │
│ 4. If max retries exhausted → STOP and ask user   │
└──────────────────────────────────────────────────┘
```

### Rules for CI Fixes

1. **Be conservative** — minimal fixes only; don't change behavior beyond what's needed to pass CI.

2. **Diagnose before fixing** — Read the failure logs carefully. Common CI failures:
   - **Lint/format errors**: Run the linter/formatter locally, commit the fix
   - **Test failures**: Read the failing test, understand what broke, fix the regression
   - **Type errors**: Fix the specific type issue flagged
   - **Build failures**: Fix the compilation/build error

3. **Don't break the PR to fix CI** — If a CI fix would require significant changes that alter PR behavior, STOP and ask the user. Examples:
   - A test is failing because the PR intentionally changed behavior (test needs updating, not the code)
   - A lint rule conflicts with the PR's approach (may need a targeted disable)
   - CI infrastructure issues (flaky tests, service outages) — not your problem to fix

4. **Max 3 attempts** — If CI still fails after 3 fix-push cycles, stop and escalate to the user.

5. **Timeout (exit code 2)** — If `check-ci.sh` times out waiting for checks to complete, ask the user whether to wait longer.

### Example CI Fix Flow

```bash
# After pushing review fixes
scripts/check-ci.sh <PR> --wait

# Output shows: ✗ CI checks failed (1/4 failed)
# === FAILED CI CHECKS ===
# --- lint (FAILURE) ---
# src/utils.py:42:1: E302 expected 2 blank lines, got 1

# Fix it
# (edit the file to add the missing blank line)

# Push the fix
scripts/commit-and-push.sh "fix: lint error in utils.py"

# Check again
scripts/check-ci.sh <PR> --wait
# ✓ All CI checks passed (4/4)
# → Proceed to trigger next review
```

## Reply Templates

### For Line Comments (Gemini, agent reviewers)
**ALWAYS reply using `reply-to-comment.sh`.** Templates:
- Fixed: "Fixed - [description]"
- Won't fix (bad suggestion): "Won't fix - [reason]"
- Out of scope (good suggestion): "Out of scope - tracked in BD-XXX" (see below)
- Deferred: "Good catch, tracking in #issue"
- Acknowledged: "Acknowledged - [explanation]"

### For PR Comments (Claude)
Reply using `gh pr comment` with a consolidated response:
```markdown
## Response to Claude Review

**Issue 1 (Breaking API change):** Fixed - added backward compatibility

**Issue 2 (Missing validation):** Fixed - added input validation in controller

**Issue 3 (Behavior change):** Won't fix - intentional, see PR description

**Issue 4 (Missing tests):** Out of scope - tracked in BD-XXX
```

## Out of Scope Suggestions (Beads Integration)

When a review suggestion is **good but outside the scope of this PR**, capture it for later rather than losing it.

**Decision tree:**
1. Is this suggestion valid and would improve the code? → If NO, use "Won't fix"
2. Does it belong in this PR? → If YES, fix it
3. It's a good suggestion but out of scope → Create a beads ticket if available

**Check if beads is installed:**
```bash
bd --version
```

**If beads is available, create a ticket:**
```bash
bd create
```

Include in the ticket:
- **Title**: Brief description of the suggested improvement
- **Description**: Must include ALL context needed to fix the issue later:
  - The original review comment text
  - File path and line number(s) affected
  - PR number and link for context
  - The gh command to fetch the exact comment:
    ```
    gh api /repos/{owner}/{repo}/pulls/{PR}/comments/{comment-id}
    ```
  - Any relevant code snippets or context from the current PR

**Then reply to the comment:**
```bash
scripts/reply-to-comment.sh <PR> <comment-id> "Out of scope - tracked in BD-XXX"
```

**Track the ticket** for reporting at the end of the review loop. Keep a list of all created tickets (ID and title) to include in the completion summary.

**If beads is NOT installed:**

1. Still reply to the comment noting the finding is out of scope:
   ```bash
   scripts/reply-to-comment.sh <PR> <comment-id> "Out of scope for this PR - see review loop completion summary"
   ```
2. Collect all out-of-scope findings with full context (original comment text, file paths, line numbers, PR number, reviewer, and the `gh api` command to fetch the comment). Track these via `TaskCreate` (one task per finding, with the full context in the task body) so they survive across rounds.
3. In the completion summary, list all out-of-scope findings and recommend installing beads to track them. Offer to create a follow-up PR that:
   - Creates a markdown file (e.g., `TODO-beads.md`) with pre-filled `bd create` commands for each out-of-scope finding, using the context collected in step 2
   - Includes instructions for the user to run `bd init` and execute the commands in the markdown file
4. If the user agrees, create a follow-up PR containing the generated markdown file and documentation updates explaining how users can install and use beads.

## Triggering Reviews by Bot Type

### Gemini Code Assist (Default)
```bash
scripts/trigger-review.sh <PR> --gemini --wait
```
The script uses two checks to avoid redundant `/gemini review` triggers and conserve quota (33 reviews/day on free tier):
1. **Commit check**: If Gemini has already reviewed the current HEAD commit, skips the trigger entirely.
2. **Config check**: If `.gemini/config.yaml` exists with `code_review: true`, the repo has auto-review enabled. When `--wait` is used, the script waits one poll interval for an auto-review before falling back to a manual trigger.

When quota is exceeded, the skill automatically detects this and suggests alternatives.

### Cursor Bugbot
```bash
scripts/trigger-review.sh <PR> --cursor --wait
```
Cursor auto-reviews on push, so `--cursor` just waits for comments to appear (typically 1-2 minutes).

### Claude Agent (Fallback)
```bash
scripts/trigger-review.sh <PR> --claude
```
Uses a Claude agent to review the PR and post comments. Useful when:
- Gemini is rate-limited
- You want a different perspective
- Cursor isn't configured on the repo

### Claude Review Workflow

When using Claude fallback:

1. **Run the script to get the prompt:**
   ```bash
   scripts/claude-review.sh <PR>
   ```

2. **Use the Task tool with the generated prompt:**
   ```
   Task tool:
     subagent_type: general-purpose
     description: Review PR #<PR>
     prompt: (copy from /tmp/claude_review_prompt_<PR>.txt)
   ```

3. **The agent will post the review as a PR comment**

4. **Continue the normal review loop** - address comments using `reply-to-comment.sh`

## Agent Reviewers (Default + Custom Focused Reviews)

The skill ships **6 default specialist reviewer agents** that spawn automatically. Users can author additional agents — or override / disable defaults — via `AGENT-REVIEWERS.md`.

### Default Specialist Reviewers

Located in `plugins/pr-review-loop/agents/`. Each is a native subagent with frontmatter (`name`, `description`, `model`, `color`) plus our standard focus/check/flag/skip/suggest template, with touch-it-you-own-it scope rules baked in:

| Default | Model | Focus |
|---------|-------|-------|
| `code-reviewer` | sonnet | CLAUDE.md compliance + significant bugs; confidence ≥80; quote-the-rule forcing function |
| `silent-failure-hunter` | opus | Empty / broad catches, optional-chain swallowing, fallback masking |
| `pr-test-analyzer` | opus | Behavioral coverage gaps, criticality 1-10 |
| `comment-analyzer` | sonnet | Factual accuracy, comment rot, value-free comments |
| `type-design-analyzer` | sonnet | Encapsulation, invariant expression / usefulness / enforcement (4 axes 1-10) |
| `code-simplifier` | opus | Genuine complexity / nested ternaries / dead code; behavior-preserving |

Defaults always spawn unless explicitly overridden or disabled (see "Override and Configuration Semantics" below).

### Override and Configuration Semantics (C+E)

User-authored agents in `AGENT-REVIEWERS.md` compose with defaults via these rules:

| User repo state | What spawns |
|-----------------|-------------|
| No `AGENT-REVIEWERS.md` | All 6 defaults |
| `AGENT-REVIEWERS.md` with no `# Agents` section | All 6 defaults + the user's `# Guidelines` / `# Context` apply |
| `AGENT-REVIEWERS.md` with new custom agents under `# Agents` | All 6 defaults + user's custom agents (additive) |
| User agent has the **same name** as a default (`## code-reviewer`) | User's version replaces that default; the other 5 still spawn |
| User has `# Configuration` with `disabled: ["pr-test-analyzer"]` | 5 defaults spawn (pr-test-analyzer skipped) |
| Hierarchical scoping (subtree-specific overrides) | Per-subdirectory rules apply as before; defaults always live at scope `/` |

### `# Configuration` Section

Project-level config lives in a `# Configuration` H1 section in the **root** `AGENT-REVIEWERS.md`. The section contains a fenced JSON block. Subdirectory `AGENT-REVIEWERS.md` configurations are warned about and ignored.

````markdown
# Configuration

```json
{
  "defaults_version_checked": "1.2.0",
  "disabled": ["pr-test-analyzer"],
  "overlap_acknowledged": {
    "my_pci_auditor": {
      "overlaps_with": "security-reviewer",
      "reason": "PCI-compliance-specific scope; we want both running because the default is general security"
    }
  },
  "independent_validator": {
    "enabled": true,
    "skip_for": ["code-simplifier"],
    "uncertain_action": "post_with_annotation"
  }
}
```
````

Fields:

- **`defaults_version_checked`** — plugin version (matches the value in `.claude-plugin/plugin.json`) whose defaults the user has reviewed. The `/pr-review-loop:audit-agents` tool (q2h) bumps this when the user accepts/rejects each recommendation.
- **`disabled`** — list of default agent names the user does NOT want spawned. Per-name opt-out.
- **`overlap_acknowledged`** — map from a user agent name to `{ overlaps_with, reason }`. Both agents continue to spawn; this entry documents intentional duplication so the audit tool doesn't recommend renaming. **`reason` is REQUIRED** — the parser rejects entries without it, so future readers see why both agents are intentionally running.
- **`independent_validator`** — controls the per-finding validation step (see "Independent Validator Pipeline" below). All three nested fields are optional; defaults are `enabled: true`, `skip_for: []`, `uncertain_action: "post_with_annotation"`.

### Language Template Offer

When pre-loop step 2 sees a non-empty `language_detection` block from `discover-agents.sh`, the loop offers to install language-specific reviewer templates before round 1. Templates live under `plugins/pr-review-loop/agent-reviewer-templates/` (initial set: `golang.md`, `python.md`). Each is an opinionated bundle that disables the baked-in defaults it explicitly subsumes (e.g., both packs ship a richer `error-handling-reviewer` and disable `silent-failure-hunter`) and acknowledges legitimate overlaps with `pr-test-analyzer`.

#### When the offer fires

Only when ALL of these hold:
- `language_detection != null` (no AGENT-REVIEWERS.md exists at root OR via walk-up from changed files)
- `language_detection.matched` is non-empty (at least one manifest detected)
- The user has not declined the offer earlier in this loop invocation

#### Prompt shapes

**Single match (one language, one subtree):**

```
No AGENT-REVIEWERS.md found. Detected: golang in `/` (matched: go.mod).

Available template: golang.md — adds 8 reviewers (test-coverage,
error-handling, complexity, concurrency, resource-leak, external-process,
dead-code, clarity) and disables silent-failure-hunter / comment-analyzer
/ code-simplifier (subsumed by the language pack's richer agents).

Install? [y/N]
```

**Per-subtree polyglot (`same_directory_polyglot == false`):**

```
No AGENT-REVIEWERS.md found. Detected:
  - golang in `/backend` (matched: go.mod)
  - python in `/frontend` (matched: pyproject.toml)

Available templates:
  [1] golang.md → /backend/AGENT-REVIEWERS.md
  [2] python.md → /frontend/AGENT-REVIEWERS.md

Each template installs in its detected subtree. A merged # Configuration
will be written to the root AGENT-REVIEWERS.md.

Install all? [y/N/select]
```

**Same-directory polyglot (`same_directory_polyglot == true`):**

```
No AGENT-REVIEWERS.md found. Detected MULTIPLE languages in the same directory:
  - golang in `/` (matched: go.mod)
  - python in `/` (matched: pyproject.toml)

The language packs share agent names (test-coverage-reviewer, etc.) and
cannot both install at the same subtree. Pick ONE to install at the
detected location, or skip and set up subtree boundaries manually.

Pick one to install: [1=golang, 2=python, N=skip]
```

#### Invocation

On user accept, run `install-template.sh` with the chosen pairs:

```bash
# Single match
scripts/install-template.sh golang:.

# Per-subtree polyglot — install all
scripts/install-template.sh golang:backend python:frontend

# Same-directory polyglot — user picked golang
scripts/install-template.sh golang:.
```

The script is transactional — it validates ALL target paths before writing anything and refuses if any `AGENT-REVIEWERS.md` already exists. Successful install bumps `defaults_version_checked` to the current plugin version, so the subsequent stale-pin check (step 3) passes by construction.

#### After install: offer repo-tailored recommendations

Once `install-template.sh` succeeds, offer a second prompt for repo-tailored reviewer recommendations:

```
Template installed. Want recommendations for repo-specific reviewers
based on the codebase (e.g., migration-safety-reviewer for DB-heavy
repos, prompt-injection-reviewer for LLM-heavy repos)? [y/N]
```

On accept, follow the "Project-Specific Reviewer Recommendations" section below — the proposals are presented via `AskUserQuestion` (multi-select), not plan mode. On decline, proceed to step 3 with just the template install in place.

#### When the user declines the install offer

Don't re-prompt within the same loop invocation. Track the decline via `TaskCreate` (or equivalent ephemeral state) so a fresh loop invocation re-fires the offer if conditions still hold. Continue to step 3 with only the 6 baked-in defaults.

### Project-Specific Reviewer Recommendations

After `install-template.sh` succeeds and the user accepts the post-install "want recommendations?" prompt, the loop spawns a focused scan of the repo and proposes 3-7 additional reviewers tailored to what it finds (e.g., `migration-safety-reviewer` for a repo with a `/db/migrations/` tree, `prompt-injection-reviewer` for a repo with LLM API calls in the diff).

#### Design rationale: AskUserQuestion, not plan mode

The original sketch for this flow used Claude Code's plan mode. **It doesn't work.** Verified: `EnterPlanMode` exists but `ExitPlanMode` returns no structured data — there's no programmatic way for a skill to read back which items the user approved, rejected, or modified. The right primitive is `AskUserQuestion` with `multiSelect: true`, which returns the user's picks structured.

Trade-off: no "modify a proposal before accepting" UX. The user accepts or rejects each proposal as written. If they want to tweak wording, they accept and edit the resulting AGENT-REVIEWERS.md by hand.

#### Repo scan: orchestrator picks per-repo

The scan that informs proposals is **the orchestrator's call** — there's no fixed list of files to read. Use these guidelines to set scan depth:

| Always read (cheap, high-signal) | Optional (depth-dependent) |
|----------------------------------|----------------------------|
| `README.md` at root              | `.beads/issues.jsonl` recent open issues |
| `CLAUDE.md` at root              | Top 20 commit messages (`git log --oneline -20`) |
| Top-level dependency manifests (names, not lockfiles) | Sampled source files |

**Scan budget**: keep the total read at ≤10k tokens of repo content. Stop scanning once you have enough signal to propose 3-7 reviewers.

**Source-file sampling**: for repos with <100 source files total, sample 5-10. For larger repos, cap at ~20. Bias toward larger / older files (more likely to encode patterns the team cares about). Skip generated code, tests, and vendored dependencies.

**Don't read the full PR diff** — the PR is just one slice of the repo; proposals should serve the repo broadly, not be PR-specific.

#### Proposal generation: spawn as a Task

Use the Task tool with a focused prompt rather than inlining the scan in the main loop conversation. Keeps main-context tokens low.

```yaml
Task tool:
  subagent_type: general-purpose
  description: Propose repo-specific reviewers for <repo-name>
  prompt: |
    The user just installed language-specific code-reviewer templates
    in this repo via the pr-review-loop skill. They want recommendations
    for ADDITIONAL repo-specific reviewers that the language packs can't
    anticipate — things tied to this repo's domain, architecture, or
    historical pain points.

    ## Already installed (do NOT re-propose these)

    Baked-in defaults: code-reviewer, silent-failure-hunter,
    pr-test-analyzer, comment-analyzer, type-design-analyzer,
    code-simplifier.

    Language pack(s) just installed: <pass the list from
    install-template.sh output, e.g., "golang.md (at /backend)">

    ## What to scan

    Use the scan-budget guidelines from SKILL.md "Repo scan" section.
    You have ~10k tokens of repo content to read; pick wisely. Always
    read README.md, CLAUDE.md, and top-level manifests. Sample source
    files. Skim recent commits and .beads/ if present.

    ## Output

    Return 3-7 proposed reviewers as a JSON array, no other text:

    ```json
    [
      {
        "name": "migration-safety-reviewer",
        "focus": "One-line description of what this reviewer flags",
        "scope": "/db/" | "/" | "/backend/" | ...,
        "rationale": "Why this repo needs it — cite a file or pattern you saw"
      },
      ...
    ]
    ```

    Scope rules:
    - "/" means root (applies to all changed files)
    - "/path/" means only files under that directory

    Don't propose reviewers that overlap with the already-installed
    ones. Don't propose generic best-practice reviewers ("be careful
    with secrets") — those add noise. Each proposal should cite a
    specific repo signal you saw during the scan.

    If you can't find 3 distinct repo-specific patterns worth proposing,
    return fewer (or even an empty array). Quality over count.
```

#### Presenting proposals via AskUserQuestion

Parse the proposal JSON. Show proposals in batches of ≤4 via `AskUserQuestion` with `multiSelect: true`. Use a `(1 of N)` indicator in the question header when batching:

```
Question: "Which proposed reviewers should the loop install? (1 of 2)"
Header: "Reviewers 1/2"
multiSelect: true
Options:
  - "migration-safety-reviewer" — Flag schema changes without rollback paths in /db/migrations/
  - "prompt-injection-reviewer" — Flag unbounded string interpolation into LLM API calls
  - "auth-bypass-reviewer" — Flag controller actions missing the require_auth callback
  - "race-condition-reviewer" — Flag shared-state writes outside the actor model in /workers/
```

After the first batch's answers, automatically follow up with batch 2 (no gate question) until all proposals have been presented. Zero picks across all batches is a valid outcome — just don't write anything.

#### Writing accepted proposals

Each accepted proposal has an explicit `scope`. Use it to route the write:

- **Scope `/`** (root-wide): append to root `AGENT-REVIEWERS.md`. If the root file has no `# Agents` section yet (templates went to subtrees), add one before the first proposal lands.
- **Scope `/path/`** (subtree): append to `<path>/AGENT-REVIEWERS.md`. If that file doesn't exist (no template was installed at that subtree), create it with just `# Agents` — the root file owns `# Configuration` per the install-template convention.

For each proposal, generate the H2 block:

```markdown
## <proposal.name>

<proposal.focus>

<!-- Proposed during install-template setup; rationale: <proposal.rationale> -->
```

Append as a new `## ` block under `# Agents` in the target file. Preserve any existing agents. The rationale comment supports future audit-agents (q2h) recommendations.

#### After writing

Emit a one-line summary to the spawning summary surface:

```
Installed 3 project-specific reviewer(s): migration-safety-reviewer (/db/), prompt-injection-reviewer (/), auth-bypass-reviewer (/).
```

No re-run of `discover-agents.sh` needed — round 1 picks up the new files naturally.

#### When the user declines the recommendations prompt

Just continue to step 3 (stale-pin check). The template install stays in place; no further writes happen. Track the decline via `TaskCreate` so the prompt doesn't re-fire if the loop happens to revisit this code path within the same invocation.

### Stale Pin Detection (at loop start)

Before round 1, the loop checks `defaults_version_checked` against the installed plugin version. The check is deterministic — a pure version-string compare, no LLM inference.

If the pin is missing or stale:

```
⚠️  AGENT-REVIEWERS.md was last audited against pr-review-loop v1.2.5.
    Installed version: v1.3.0
    Run `/pr-review-loop:audit-agents` to review changes, or
    pass `--skip-stale-check` to proceed with current configuration.
```

The loop **exits non-zero** on stale pin. The user must either run the audit tool (which bumps the pin) or re-invoke the loop with `--skip-stale-check`.

When `--skip-stale-check` is used, the merge-readiness summary at end-of-loop includes a bypass note so it isn't silently forgotten:

```
Note: ran with stale defaults pin (config v1.2.5, plugin v1.3.0).
Consider running `/pr-review-loop:audit-agents`.
```

### Spawning Summary

Once the stale check passes (or `--skip-stale-check` is set), the loop emits a one-line summary of which agents are running and why, before any agent spawns:

```
Spawning 6 reviewers: 4 defaults + 1 user override (code-reviewer) + 1 user agent (pci-auditor).
Disabled defaults: pr-test-analyzer.
Validation: enabled (sonnet validators across all flaggers).
```

(Math: 6 defaults − 1 disabled (pr-test-analyzer) − 1 overridden (code-reviewer) = 4 default agents spawning; plus the user's `code-reviewer` override and `pci-auditor` user agent = 6 total. Flagger model varies (some agents flag in opus, others in sonnet) but the validator model is held constant at sonnet so per-flagger acceptance-rate telemetry isn't confounded by validator strictness.)

Goes to the same task tracking state / pre-round summary surface as other setup state.

When validation is disabled or partially skipped, the third line reflects that:

```
Validation: enabled (skip_for: code-simplifier).
Validation: disabled.
```

### Independent Validator Pipeline

After every agent reviewer returns findings and BEFORE those findings are posted, the loop runs an independent validator subagent per finding to verify the issue against the diff context alone. Findings the validator rejects are dropped.

This catches the asymmetric-cost failure mode: a false-positive that gets *applied as a fix* introduces a real regression in once-correct code.

**When the validator runs.** Between agent return and finding posting, per round. Per-finding, in parallel via the Task tool.

**What the validator receives.**
- The finding text (severity, location, issue body)
- The relevant PR diff context (touched file or referenced lines)

**What the validator does NOT receive.**
- The flagging agent's name
- The flagger's confidence rating
- Any meta-context that would let the validator rationalize the finding

**Validator output.** Structured: `VERDICT: VALID | INVALID | UNCERTAIN` with a one-line `REASON:`.

**Filter behavior.**
- **VALID** → post the finding through the normal flow (`post-line-comment.sh` / pending-review batching)
- **INVALID** → drop silently from this round's posted findings; record in telemetry
- **UNCERTAIN** → behavior depends on `# Configuration .independent_validator.uncertain_action`:
  - `post_with_annotation` (default) — post with a `[validator: uncertain]` annotation
  - `post_silently` — post normally
  - `drop` — drop like INVALID

#### Validator model selection

The validator runs on **sonnet uniformly across all flaggers**, regardless of the flagger's own model. This is a deliberate choice for telemetry hygiene: per-flagger acceptance-rate signal stays comparable across agents only when the validator instrument is held constant. Mirroring the flagger's model (e.g., opus-validates-opus) would conflate "this flagger emits false positives" with "opus is more confident than sonnet" — both move the acceptance rate in the same direction.

Sonnet is the right choice for a "second look": cheaper than opus while still strong enough for the validator task.

Per-agent overrides may land later (see `devon-claude-skills-qml`) — when they do, the override is an explicit user opt-in, and the documentation will state that an overridden agent's acceptance rate is no longer directly comparable to others'.

#### Validator Task prompt template

```yaml
Task tool:
  subagent_type: general-purpose
  model: sonnet
  description: validate review finding on <file>:<line>
  prompt: |
    You are an independent validator for a code review finding.
    Your only job is to verify the finding against the actual code.
    You do NOT know which agent flagged this, and you do NOT know
    their confidence rating. Look at the code; decide if the issue
    is real.

    ## Finding

    Severity: <finding.severity>
    Location: <file>:<line>
    Issue: <finding.body>

    ## Diff context

    <PR diff for the touched file, or just the touched range>

    ## Your output

    Output exactly two lines:

      VERDICT: VALID | INVALID | UNCERTAIN
      REASON: <one-line rationale, plain text, no markdown>

    Use VALID when you can verify the issue exists in the code as
    described. Use INVALID when the code as written does not have
    the claimed problem. Use UNCERTAIN when you cannot verify
    either way from the diff context alone.
```

#### Configuration

In `# Configuration`:

```json
{
  "independent_validator": {
    "enabled": true,
    "skip_for": ["code-simplifier"],
    "uncertain_action": "post_with_annotation"
  }
}
```

- `enabled` (default `true`) — toggle validation on/off
- `skip_for` (default `[]`) — list of flagger agent names whose findings bypass validation
- `uncertain_action` (default `"post_with_annotation"`) — `post_with_annotation` | `post_silently` | `drop`

The parser **rejects** non-boolean `enabled`, non-array `skip_for`, `uncertain_action` outside the enum, or `independent_validator` itself being a non-object (exit 1). It **warns** (without rejecting) on unknown nested keys, so a typo like `enabld` is surfaced but doesn't block the loop.

#### Telemetry

Each finding's validator outcome is logged to `.beads/pr-review-loop/findings/<pr>-<round>.jsonl` (per the gx4 telemetry framework when it lands). Aggregated at end-of-round and end-of-loop:
- Per-flagger validation acceptance rate (helps identify reviewers that emit many false positives — comparable across flaggers because the validator model is held constant)
- Total findings dropped or annotated by the validator

### AGENT-REVIEWERS.md Format

Two types of H1 sections:

1. **`# Agents`** - Defines custom agent reviewers (H2 headings become agent names)
2. **Any other H1 section** - Treated as context/instructions for the main review loop (like CLAUDE.md)

```markdown
# Agents

## security-reviewer
Focus on security vulnerabilities: injection attacks, auth bypasses, secrets in code,
unsafe deserialization, path traversal, etc. Flag anything that could be exploited.

## dry-reviewer
Identify code duplication. Look for repeated logic that could be abstracted.
Consider whether abstraction would actually improve maintainability.

# Guidelines

When reviewing this codebase:
- All database queries must use parameterized statements
- Prefer composition over inheritance
- Error messages should never expose internal paths or stack traces

# Context

This is a Ruby on Rails API backend. The frontend is a separate React app.
Authentication uses JWT tokens stored in httpOnly cookies.
```

**How sections are used:**
- `# Agents` → H2 headings define agent reviewers with their specialized instructions
- Other H1 sections (`# Guidelines`, `# Context`, etc.) → Passed to the main pr-review-loop task as context, similar to CLAUDE.md content

### Hierarchical Scoping

`AGENT-REVIEWERS.md` files can exist at any directory level. Agents and context sections are scoped to their directory and below.

**Resolution rules:**
1. For each changed file, collect `AGENT-REVIEWERS.md` files from its directory up to repo root
2. Resolve sections by H1 name - **lower directory definitions override same-named sections from above**
3. For `# Agents`: each agent only reviews changes **within its directory scope and below**
4. For other H1 sections: winning version of each section (per override rule) is combined and passed to the review loop
5. Root-level definitions see all changes; subdirectory definitions see only their subtree

**Example structure:**
```
/AGENT-REVIEWERS.md                    # Agents: clarity-reviewer, dry-reviewer
                                       # Guidelines: general repo rules
/plugins/AGENT-REVIEWERS.md            # Agents: dry-reviewer (overrides root), plugin-structure-reviewer
                                       # Guidelines: plugin-specific rules (overrides root)
/plugins/auth/AGENT-REVIEWERS.md       # Agents: security-reviewer
                                       # Context: auth-specific context
```

**Result for a PR touching `plugins/auth/login.py` and `plugins/utils.py`:**

*Agents:*
- `clarity-reviewer` (from root) → sees all changes
- `dry-reviewer` (from `/plugins/`, overrides root) → sees all changes under `/plugins/`
- `plugin-structure-reviewer` (from `/plugins/`) → sees all changes under `/plugins/`
- `security-reviewer` (from `/plugins/auth/`) → sees only changes under `/plugins/auth/`

*Context for main review loop:*
- For `plugins/auth/login.py`: combines `# Guidelines` from `/plugins/` + `# Context` from `/plugins/auth/`
- For `plugins/utils.py`: uses `# Guidelines` from `/plugins/`

**Discovery algorithm** (implemented by `scripts/discover-agents.sh`):
1. Get changed files via `gh pr diff <PR> --name-only`
2. For each unique directory containing changed files, walk up to repo root collecting `AGENT-REVIEWERS.md` paths
3. Parse each file, building agent map (lower directory wins on name collision)
4. Track each agent's scope (directory where it was defined)
5. Filter changed files per agent to only those within the agent's scope

### When to Run Agent Reviewers

Agent reviewers run as **C3** — the last step of the COLLECT phase in each round, after C1 (Gemini) and C2 (other bots), and before any FIX-phase edits.

On the first round (or when new agents are discovered), discover agent reviewers:

```bash
scripts/discover-agents.sh <PR>
```

Each agent's `changed_files` list contains only the PR's changed files within that agent's scope. Pass this list to the agent.

Spawn non-retired agents **in parallel** at C3 of each round. Track per-agent state to avoid re-running retired agents.

### Spawning Agent Reviewers

For each agent in the merged list from `discover-agents.sh` (defaults + user agents per C+E), spawn a Task. Use the agent's declared `model` field if present; otherwise default to `sonnet`. The `instructions` field is the agent body — same shape for defaults (from `plugins/pr-review-loop/agents/*.md`) and user agents (from `AGENT-REVIEWERS.md`).

```yaml
Task tool:
  subagent_type: general-purpose
  model: <agent.model or "sonnet">
  description: <agent-name> review for PR #<PR>
  prompt: |
    You are the "<agent-name>" code reviewer for PR #<PR>.

    Your focus: <agent.instructions>

    **Your scope: <agent.scope>**
    You should ONLY review changes to the files listed below. Ignore all other files.

    **Changed files in your scope:**
    <agent.changed_files from discover-agents.sh output>

    ## Your workflow:

    1. **Check your prior comments** (if any):
       ```bash
       scripts/get-agent-comments.sh <PR> <agent-name> --with-replies
       ```

    2. **Evaluate replies to your prior comments**:
       - If the response is reasonable (good explanation, valid fix, or acceptable tradeoff), do NOT re-raise
       - If the response is UNREASONABLE (dismissive, incorrect, or ignores the issue), reopen:
         ```bash
         scripts/reopen-comment.sh <PR> <comment-id> <agent-name> "Reopening - <reason why response is insufficient>"
         ```

    3. **Review the PR diff** (only your changed_files):
       Read each file from your changed_files list directly, or filter the diff:
       ```bash
       gh pr diff <PR> -- <file1> <file2> ...
       ```

    4. **Post NEW findings** as line comments (only issues not already raised, only files in your scope):
       ```bash
       scripts/post-line-comment.sh <PR> <file> <line> <agent-name> "Issue description and suggestion"
       ```
       The script automatically adds `<!-- Agent: <agent-name> -->` signature.

    5. **Return** - Do NOT fix anything. Your job is review only.

    ## Important:
    - Be thorough but not pedantic - only flag real issues within your focus area
    - Consider project context - not all best practices apply everywhere
    - If you have no findings and all prior comments have reasonable responses, simply return "No issues found"

    Available scripts: See pr-review-loop skill documentation for full script reference.
```

**Spawn all agents in parallel** - use multiple Task tool calls in a single message.

### Main Loop Integration

Agent reviewers run as C3 — the last step of the COLLECT phase, after C1 (Gemini) and C2 (other bots). Within C3, the individual agent reviewers spawn in parallel. All COLLECT-phase findings — Gemini + other bots + agents — flow into the BATCH POINT before any FIX-phase action.

1. **After agent Tasks return** (in C3), their findings join the C1 + C2 findings at the BATCH POINT. Identify cross-source patterns and plan sweeps before staging any edit.

2. **In F3, address agent comments** using the same flow as Gemini:
   - Fix → reply "Fixed - ..."
   - Won't fix (bad) → reply "Won't fix - ..."
   - Out of scope (good) → create beads ticket if available, reply "Out of scope - tracked in BD-XXX"

3. **Update per-agent tracking** based on results (productive / final-verification / retired)

4. **In F4–F6**, commit + push the batched fixes once, wait for CI, and trigger the next review.

### Diminishing Returns for Agent Reviewers

Apply the same heuristic as Gemini, but **per agent**:

- Track each agent via `TaskCreate`: `"<agent-name>: final verification loop"`
- After 2-3 cycles where an agent produces only nitpicks or "Won't fix" responses, enter final verification for that agent
- If an agent's final verification produces actual fixes, reset its state
- If an agent's final verification produces no actionable feedback, **stop calling that agent**

Example tracking:
```
- "security-reviewer: 2 cycles, still productive" (keep calling)
- "dry-reviewer: final verification loop" (one more, then retire if no actionable feedback)
- "error-handling-reviewer: retired" (no longer called)
```

### Selective Agent Execution

As agents reach diminishing returns, stop calling them. The main loop should:

1. Parse `AGENT-REVIEWERS.md` to get all agent names
2. Track per-agent state (productive / final-verification / retired)
3. Only spawn Tasks for non-retired agents
4. Update state after each cycle based on results

This keeps the review loop efficient while ensuring all perspectives are heard at least once.

## Suggesting AGENT-REVIEWERS.md Creation or Updates

During the review loop, if you identify guidance that would improve review quality for the repo but isn't captured anywhere, suggest creating or updating an `AGENT-REVIEWERS.md` file.

**When to suggest creating AGENT-REVIEWERS.md:**
- The repo has no `AGENT-REVIEWERS.md` AND you identify specific guidance that would help — e.g., recurring review patterns, repo-specific conventions reviewers should know, or specialized review concerns (security, API compatibility) that warrant a custom agent reviewer.

**When to suggest updating an existing AGENT-REVIEWERS.md:**
- You notice review comments repeatedly flagging the same kind of issue that a `# Guidelines` entry could prevent.
- A new area of the codebase (e.g., a new subdirectory with different conventions) would benefit from scoped agents or guidelines.
- Existing agent definitions are missing context that would make their reviews more accurate.

**What NOT to suggest:**
- Don't suggest creating AGENT-REVIEWERS.md just because the file doesn't exist — only when you have concrete content that would go in it.
- Don't duplicate guidance that already exists in CLAUDE.md or other repo documentation.

**How to suggest it:** Present the recommendation to the user with the proposed content. Do not create or modify AGENT-REVIEWERS.md without user approval.

## Rate Limit Detection

The scripts automatically detect Gemini quota limits by checking for:
> "You have reached your daily quota limit"

When detected, the script suggests:
1. Use Cursor if available: `--cursor --wait`
2. Use Claude fallback: `--claude`

## Scripts

| Script | Purpose |
|--------|---------|
| `commit-and-push.sh "msg"` | **ALWAYS USE** - Never use raw git commit/push |
| `reply-to-comment.sh <PR> <id> "msg"` | **ALWAYS USE** - Reply and auto-resolve every comment |
| `get-review-comments.sh <PR> [--with-ids] [--wait]` | **USE --wait** - Fetch line comments (Gemini, Cursor), polls 5min if --wait |
| `get-pr-comments.sh <PR> [--with-ids] [--wait] [--author]` | Fetch PR-level comments (Claude, Copilot) with priority detection |
| `trigger-review.sh [PR] [--gemini\|--cursor\|--claude] [--wait]` | **USE --wait** - Trigger review and poll for response |
| `check-ci.sh <PR> [--wait] [--timeout N]` | **USE --wait** - Wait for CI, report failures with logs |
| `summarize-reviews.sh <PR> [--all]` | Summary of unresolved by priority/file |
| `watch-pr.sh <PR>` | Background monitor (optional, for long-running watches) |
| `claude-review.sh <PR>` | Generate Claude agent prompt for code review |
| `check-gemini-quota.sh <PR>` | Check if Gemini is rate-limited |
| `resolve-comment.sh <node-id> [reason]` | Manually resolve a thread |
| `post-line-comment.sh <PR> <file> <line> <agent> "msg"` | Post line comment with agent signature |
| `get-agent-comments.sh <PR> <agent> [--with-replies]` | Fetch agent's own comments and replies |
| `reopen-comment.sh <PR> <comment-id> <agent> "reason"` | Reply to resolved thread with Claude attribution |
| `discover-agents.sh <PR>` | Discover + merge agent reviewers (defaults + user agents per C+E); emits `configuration` block with `stale_pin` and (when no AGENT-REVIEWERS.md exists) the `language_detection` block driving the Language Template Offer |
| `detect-language.sh [--repo-root <path>]` | Scan repo for language manifests (go.mod, pyproject.toml, etc.); emits `[{language, subtree, manifest}, ...]`. Deterministic; called by discover-agents.sh |
| `install-template.sh [--repo-root <path>] <lang>:<subtree> [...]` | Install language template(s) at the given subtrees + merged # Configuration at root. Transactional; refuses existing AGENT-REVIEWERS.md. Bumps `defaults_version_checked` to current plugin version |
| `_load_defaults.sh` | Internal helper: load native default subagents from `plugins/pr-review-loop/agents/` |
| `_parse_configuration.sh <AGENT-REVIEWERS.md>` | Internal helper: parse the `# Configuration` JSON block; validates required `reason` in `overlap_acknowledged` |

## Permission Setup

To enable autonomous loops, user should grant access:
```
Bash(scripts/commit-and-push.sh:*)
Bash(scripts/reply-to-comment.sh:*)
Bash(scripts/trigger-review.sh:*)
Bash(scripts/check-ci.sh:*)
Bash(scripts/post-line-comment.sh:*)
Bash(scripts/get-agent-comments.sh:*)
Bash(scripts/reopen-comment.sh:*)
Bash(scripts/discover-agents.sh:*)
Bash(scripts/get-pr-comments.sh:*)
Bash(scripts/install-template.sh:*)
```

## Prerequisites

- `gh` CLI authenticated
- `jq` - JSON processor for parsing GitHub API responses
  Install with: `apt install jq` (Ubuntu/Debian) or `brew install jq` (macOS)
- `pre-commit` (optional) - If `.pre-commit-config.yaml` exists in the repo, pre-commit will be run.
  If pre-commit is not installed, a warning is shown but commits proceed.
  Install with: `pip install pre-commit && pre-commit install`
- `bd` (beads) (optional) - Issue tracker for capturing out-of-scope suggestions as tickets.
  If not installed, out-of-scope suggestions are handled with "Out of scope for this PR" replies.
  See: https://github.com/steveyegge/beads
