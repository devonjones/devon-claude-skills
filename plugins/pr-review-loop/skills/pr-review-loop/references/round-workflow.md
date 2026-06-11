# Round Workflow — Step-by-Step

This file is the operational companion to the round-structure diagram in `SKILL.md`'s "The Loop" section. The diagram is the source-of-truth for phase order; this file gives the per-step bash commands and example outputs.

---

**Do NOT reply to anything during the COLLECT phase (C1–C3) — all replies happen in the FIX phase (F1–F3).**

## COLLECT Phase

### C1. Check for unresolved Gemini line comments

ALWAYS use `--wait` for first check after PR creation or push:

```bash
scripts/summarize-reviews.sh <PR>
scripts/get-review-comments.sh <PR> --with-ids --wait
```

The `--wait` flag polls every 30s for up to 5 minutes, waiting for Gemini to respond. Do NOT skip this or use a shorter timeout.

The `--with-ids` flag outputs comment IDs needed for replies. Example output:
```
=== Comment ID: 2710906366 | Node ID: PRRC_kwDOD3ZsRc6hlSX- ===
File: pfsrd2/equipment.py:84
Priority: high

The function appears to duplicate functionality...
```

**Use the Node ID (PRRC_...) when replying to comments.** The Node ID is required for `reply-to-comment.sh` to properly attach your reply to the review thread.

### C2. Check for other bot PR comments (Claude, Cursor, Copilot)

These bots post single PR comments (not line comments) containing multiple issues. Use `get-pr-comments.sh` (handles priority detection and author filtering):

```bash
scripts/get-pr-comments.sh <PR> --with-ids --author claude
```

For each issue in the comment, parse the structured markdown (numbered issues, file:line references) and note it for the BATCH POINT.

### C3. Run agent reviewers

The merged default + user agent set comes from pre-loop setup:

- Spawn non-retired agents as parallel Tasks (defaults always spawn unless overridden or disabled per C+E), using the spawning template from `SKILL.md` VERBATIM on the posting steps — each agent POSTS its own findings as line comments via `post-line-comment.sh` and returns a posting manifest (`severity | file:line | title` per finding). Do NOT rewrite the template into "return findings, don't post" (⛔ rule 3: the PR is the system of record; unposted findings break the audit trail AND next round's `get-agent-comments.sh` dedup).
- Wait for all agents to return their manifests
- **For each POSTED finding, run the independent validator** against the posted comment (per "Independent Validator Pipeline" in `SKILL.md`). VALID findings flow to the BATCH POINT below; INVALID are withdrawn ON-THREAD (`reply-to-comment.sh <PR> <id> "Withdrawn — validator refuted: <reason>"`) and excluded from the batch; UNCERTAIN handled per `independent_validator.uncertain_action` (default: annotate the thread). Skip validation for any flagger named in `independent_validator.skip_for`. Skip validation entirely unless `independent_validator.enabled` is explicitly true (validation is OPT-IN; the default is off). Validation never deletes or delays posting — refutations are part of the audit trail.

## BATCH POINT (required before FIX Phase)

Apply **"Batch Before Acting"** (see Pattern Analysis section in `SKILL.md`):

- List all C1 + C2 + C3 comments as a single set
- Identify cross-source patterns (same issue type across multiple comments or files) — plan sweeps, not individual fixes
- For each planned fix, re-read the new text through each active agent's lens before staging: would code-reviewer flag this? Would comment-analyzer flag a stale assertion? Revise until the fix itself wouldn't draw a new comment
- Record deliberate trade-offs for the commit message body (so reviewers see reasoning and don't re-flag the concern)

## FIX Phase

### F1. Apply + reply to Gemini line comments

MANDATORY — reply to every comment.

- Apply the planned fixes from BATCH POINT (or decide to skip)
- **ALWAYS reply using the script with the Node ID** — this resolves the thread:

```bash
# Use the Node ID (PRRC_...) from C1 output
scripts/reply-to-comment.sh <PR> PRRC_kwDOD3ZsRc6hlSX- "Fixed - description"
# OR for bad/inappropriate suggestions:
scripts/reply-to-comment.sh <PR> PRRC_kwDOD3ZsRc6hlSX- "Won't fix - reason"
# OR for good suggestions outside PR scope — see "Out of Scope Suggestions" in SKILL.md:
scripts/reply-to-comment.sh <PR> PRRC_kwDOD3ZsRc6hlSX- "Out of scope - tracked in BD-XXX"
```

### F2. Apply + reply to other bot comments

Reply to the PR comment with a consolidated response covering all issues from C2:

```bash
gh pr comment <PR> --body "## Response to Claude Review

**Issue 1 (name):** Fixed - description
**Issue 2 (name):** Won't fix - reason
**Issue 3 (name):** Out of scope - tracked in BD-XXX
"
```

### F3. Apply + reply to agent comments

- Same fix/wontfix/out-of-scope flow as Gemini (use `reply-to-comment.sh` with the Node ID) — EVERY surviving agent thread gets a reply, exactly like Gemini threads
- If a finding you're fixing has no posted thread (an agent failed to post), post it yourself via `post-line-comment.sh` with that agent's name BEFORE committing — no fix lands without a thread
- Track per-agent diminishing returns; see "Agent Reviewers" section in `SKILL.md` for retirement logic

### F4. Commit and push

**Gate**: every finding in this round's fix set corresponds to a posted PR thread (Gemini, bot, or agent) with a reply. If any fix has no thread, go back to F3 — a commit message is not an audit trail.

ALWAYS use the script, NEVER raw git — ONCE per round, if any fixes were made:

```bash
scripts/commit-and-push.sh "$(cat <<'EOF'
fix: address review comments

Trade-offs from BATCH POINT:
- [reasoning for choice X — pre-empts re-flag from agent Y]
EOF
)"
```

This script runs pre-commit, commits with proper footer, and pushes. Include deliberate trade-offs in the commit body so reviewers see reasoning rather than re-flagging the concern.

### F5. Wait for CI checks and fix failures (if any)

```bash
scripts/check-ci.sh <PR> --wait
```

### F6. Trigger next review and wait for response

```bash
scripts/trigger-review.sh <PR> --wait
```

The `--wait` flag polls every 30s for up to 5 minutes waiting for new comments. Do NOT use sleep or manual polling.

### F7. Inspect F6's output BEFORE applying exit conditions

If F6 returned new comments, start the next COLLECT PHASE. Otherwise apply the quality-weighted exit condition and Hard Round Ceiling check (see ONE MORE LOOP Rule in `SKILL.md`'s Stopping Heuristics section).

### End-of-round report (every round)

Emit a short status block so posting-protocol drift is visible immediately:

```
Round N: posted X findings across Y agents (A withdrawn by validator);
replied to Z threads (F fixed / W won't-fix / O out-of-scope); Gemini: G comments.
```

A round that fixed findings but shows zero posted/replied threads is broken — correct it before the next round (post the missing threads per F3's recovery rule) and note the violation in the merge-readiness summary.
