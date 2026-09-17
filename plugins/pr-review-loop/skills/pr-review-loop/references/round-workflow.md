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

**If Gemini is disabled** (`# Configuration .bots.gemini: false` — see `SKILL.md`), never post `/gemini review`. Whether to still wait depends on the *other* external bots:

- **Every external bot disabled** (gemini and cursor): drop `--wait` — run `get-review-comments.sh <PR> --with-ids` to pick up existing threads and move straight to C2/C3. (`get-review-comments.sh` enforces this itself: it only skips the poll when both are off.)
- **Gemini off, Cursor on**: keep `--wait` — Cursor still auto-reviews on push, so there is a real review to wait for.

The `--with-ids` flag outputs comment IDs needed for replies. Example output:
```
=== Comment ID: 2710906366 | Node ID: PRRC_kwDOD3ZsRc6hlSX- ===
File: pfsrd2/equipment.py:84
Priority: high

The function appears to duplicate functionality...
```

**Use the Node ID (PRRC_...) when replying to comments.** The Node ID is required for `reply-to-comment.sh` to properly attach your reply to the review thread.

**Then run the per-bot reported check** — after the `--wait` above, never before
it: the wait is what gives the bot time to review, and checking first reads a bot
that has simply not answered yet as not-reported. It belongs in COLLECT rather
than at report time, because head is only the commit the reviewers are reviewing
until F4 pushes this round's fixes. See [`reviewer-reported.md`](reviewer-reported.md).

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

**Gate**: every finding in this round's fix set corresponds to a posted PR thread (Gemini, bot, or agent) with a reply **that actually landed**. If any fix has no thread, go back to F3 — a commit message is not an audit trail.

Verify each thread rather than trusting the sends, and do it per thread — a count tells you how many replies are missing, never which. A thread is settled only when **you** spoke last and did not sign it: this skill signs every finding and every reopen it posts, and `<you>` is the login your token authenticates as:

```bash
( set -o pipefail
  ME=$(gh api user --jq .login) || { echo "reply check failed - rerun it" >&2; exit 2; }
  gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/comments" \
    | jq -rs --arg me "$ME" 'add | group_by(.in_reply_to_id // .id)
        | map(select( (sort_by(.id) | last | .body | startswith("🤖 **Claude Code** ("))
                      or (sort_by(.id) | last | .user.login != $me)
                      or length == 1 ))
        | .[] | "\(.[0].in_reply_to_id // .[0].id) \(.[0].path):\(.[0].line // .[0].original_line)"' \
    || { echo "reply check failed - rerun it" >&2; exit 2; } )
```

Every id it prints needs a reply from you. Repost to those specifically, then run
it again.

Three disjuncts, and each exists because leaving it out lost a real thread:

- **signed last** — a reviewer reopened it. A root-only test goes blind to that
  thread after your first reply.
- **someone else spoke last** — checking "unsigned" alone tests the *body*, not
  the *author*, and "not signed by this skill" is a far larger set than "written
  by you". It includes a human reopening the thread by replying, which SKILL.md
  calls the user's reopen surface, and Gemini answering inside a thread it did not
  open — either of which would otherwise discharge your disposition for you.
- **`length == 1`** — an unreplied root from a source that does not sign: a bot,
  or a human.

**Delete this once `devon-claude-skills-cq0` lands** — the fix is `reply-to-comment.sh` adopting the `|| { ...; exit 1; }` that `post-line-comment.sh:49-53` already has, after which the exit status is trustworthy.

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

### F7. Count reporters, then apply the convergence rule

If F6 returned new comments, start the next COLLECT PHASE. Otherwise: count `D` reviewers dispatched against `R` that reported — see [`reviewer-reported.md`](reviewer-reported.md), which is where the per-class definition and the bot check live — then apply the convergence rule. `D` and `R` must match. One clean round converges; there is no round cap.

### End-of-round report

Post it to the PR so a restart can read the round history back:

```bash
gh pr comment <PR> --body "$(cat <<'EOF'
<!-- pr-review-loop:round-report -->
Round N: posted X findings across Y agents (A withdrawn by validator);
replied to Z threads (F fixed / W won't-fix / O out-of-scope).
Reported: <reviewer>=ok|ok(reads-only)|ok(undeclared)|failed(<reason>), per dispatched reviewer. D dispatched / R reported.
Roster: disabled=<...|none> retired=<...|none>.
EOF
)" || { echo "round report did not post - retry before starting the next round" >&2; exit 2; }
```

Read the history back with:

```bash
( set -o pipefail
  gh api --paginate "/repos/{owner}/{repo}/issues/<PR>/comments" \
    --jq '.[] | select(.body | startswith("<!-- pr-review-loop:round-report -->")) | .body' \
    || { echo "could not read round history - rerun it" >&2; exit 2; } )
```

`get-pr-comments.sh` will not find these — it filters to bot authors and you are
the operator.

**Nothing the convergence rule depends on lives in this report.** That was tried
— a strike counter, a carried-forward list, a roster progress count — and every
one of them needed a source, a base case and a gap detector it did not have. Each
is now derived from the PR when it is needed, so a missing report costs you the
narrative and nothing else:

- **Outstanding threads** — F4's gate, recomputed each round.
- **A finding you did not fix** — found by what the thread's *last* reply says:

  ```bash
  ( set -o pipefail
    gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/comments" \
      | jq -rs 'add | group_by(.in_reply_to_id // .id) | map(sort_by(.id) | last)
          | .[] | select(.body | test("^[*_>`~ -]*(Won.t fix|Out of scope|Deferred|Acknowledged)"; "i"))
          | "\(.in_reply_to_id // .id) \(.path):\(.line // .original_line)"' \
      || { echo "decline check failed - rerun it" >&2; exit 2; } )
  ```

  Each line is a finding disposed of by something other than a fix. **Look up
  each one's severity in its own thread** — the reply carries no priority, so the
  query cannot filter on it; only P1/P2 block convergence, and a declined nitpick
  is not a blocker. An `Out of scope - tracked in <id>` line is resolved once you
  confirm that ticket exists (`bd show <id>`); the finding lives there now. It matches all four non-fix dispositions the Reply Templates
  offer, not just "Won't fix": a P1/P2 answered "Acknowledged - as designed" is a
  decline whatever it is called, and that exact wording was used on this PR.

  **Last reply, not any reply.** Matching anywhere in the thread is a ratchet no
  escape valve can release: reclassifying, fixing later and signing off are all
  *later* replies, and an earlier "Won't fix" stays matched forever. **An empty
  result with a non-zero exit is a failed check, not a clean PR** — the same rule
  the bot check states, and the only difference between them is the exit status.

  **Do not use `isResolved` for this.** It was tried and it fails three ways:
  `reviewThreads(first:100)` truncates oldest-first, so a fresh decline is past
  the cutoff and the error runs toward "converged"; `reply-to-comment.sh` resolves
  best-effort and only warns on failure, so unresolved mostly means *the resolve
  no-op'd* rather than *the finding is open* — when this was measured, the two
  views disagreed on nearly half the threads on this PR; and `--no-resolve` cannot
  *un*-resolve, so a decline after a reopen is invisible. Reply text survives all
  three.

  A decline posted as part of a batch PR comment (the Claude-reviewer flow) lands
  in `/issues/<PR>/comments`, which this query does not read. Reply on the thread
  as well, or it is invisible here.

- **A reviewer that will not report** — re-run it inside the same round. Two
  failures in one round stops the loop, so nothing crosses a round boundary.
- **Retirement state** is the exception: best-effort, not PR-derived. A restart
  forgets it, and re-earning it costs the 2-3 quiet reported rounds plus the
  confirming round the Diminishing Returns rule requires.
