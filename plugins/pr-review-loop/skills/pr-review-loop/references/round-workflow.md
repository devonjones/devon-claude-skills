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

**Record the head SHA before you spawn anything.** The round-validity check
compares against it, and it is the only moment the value exists — by F4 the
branch has moved under your own commit.

```bash
gh pr view <PR> --json headRefOid --jq .headRefOid \
  || { echo "cannot read head SHA - do not dispatch blind" >&2; exit 2; }
```

Carry it to the BATCH POINT and into the round report's `Dispatched against`
line. Also confirm the tree is clean before dispatching: reviewers read the
pushed head, so an uncommitted change is invisible to them.

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
                      or (sort_by(.id) | last | .body
                          | test("^[*_>`~ -]*(Fixed|Won.t fix|Out of scope|Deferred|Acknowledged)"; "i") | not)
                      or length == 1 ))
        | .[] | "\(.[0].in_reply_to_id // .[0].id) \(.[0].path):\(.[0].line // .[0].original_line)"' \
    || { echo "reply check failed - rerun it" >&2; exit 2; } )
```

Every id it prints needs a reply from you. Repost to those specifically, then run
it again.

The subshell keeps `pipefail` from leaking into the rest of the call you paste
this into, where a later `| head` would exit 141. Every `( set -o pipefail ... )`
in this file and in `reviewer-reported.md` is wrapped for that reason.

Four disjuncts, and each exists because leaving it out lost a real thread:

- **signed last** — a reviewer reopened it. A root-only test goes blind to that
  thread after your first reply.
- **someone else spoke last** — checking "unsigned" alone tests the *body*, not
  the *author*, and "not signed by this skill" is a far larger set than "written
  by you". It catches Gemini answering inside a thread it did not open, and a
  collaborator replying from their own account — either of which would otherwise
  discharge your disposition for you.
- **`length == 1`** — a root nobody has answered. It is the only disjunct that
  fires on a thread *you* opened and left alone, which happens whenever you post
  a finding on behalf of a reviewer that failed to post its own.

- **last word is not a disposition** — the one that covers a human on your own
  login. The author test compares *logins*, so it cannot fire when the person and
  the automation authenticate as one GitHub account, which is the ordinary
  single-maintainer setup. A hand-typed reopen then looks exactly like your own
  reply: same author, unsigned prose. What separates them is that *your*
  dispositions lead with a disposition word and a human's pushback does not.

Round 15 argued the opposite — that no content signal existed, so the remedy had
to be procedural — and shipped **Lead with the disposition word** in the same
commit, which is that signal being made mandatory. Two reviewers measured the
correction independently against every thread on the PR and agreed on the shape:
the overwhelming majority of last replies lead with a disposition word, the
handful that do not are all operator dispositions in off-template vocabulary
("Noted…", "Reopen accepted…"), and **none is a human reopen**. Re-measure rather
than trusting that ratio — it is a property of how disciplined the replies have
been, not a constant.

So this disjunct's misses are false positives costing one cleanup reply each, and
it never waves a real reopen through, which is the direction a gate should fail
in.

The procedural remedy could not have worked anyway: it told the human to use
`reopen-comment.sh`, and the case the fixture was built from is a reply typed in
the web UI, where no script is in the loop to carry a marker.

This disjunct and the "lead with the disposition word" rule hold each other up.
Break the template convention and the gate goes blind again.

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
Reported: <reviewer>=ok(mutation|evidence-query|judgement|mixed|undeclared)|failed(<reason>), per dispatched reviewer. D dispatched / R reported.
Roster: disabled=<...|none> retired=<...|none> overridden=<...|none>.
Dispatched against <head SHA at dispatch>.
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

### Was the round valid?

Run this at the **BATCH POINT** — after the last manifest, before F1. Not at F7:
F4 commits and pushes and F5 pushes CI fixes, so by F7 the head is the round's
own fix commit and the comparison is against a value your own loop moved. Round
15 shipped it at F7 and it printed `ROUND INCOMPLETE` on 15 of 15 healthy
rounds; three reviewers demonstrated it independently, one by observing that
round N's dispatch SHA *is* round N-1's F4 commit, so the two can never match.

```bash
( set -o pipefail
  DISPATCHED=<SHA recorded at C3>
  [[ "$DISPATCHED" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "no dispatch SHA recorded at C3 - round validity unknown, not valid" >&2; exit 2; }
  NOW=$(gh pr view <PR> --json headRefOid --jq .headRefOid) \
    || { echo "round-validity check failed - rerun it" >&2; exit 2; }
  if [[ "$NOW" == "$DISPATCHED" ]]; then
    echo "round valid: all reviewers read $NOW"
  else
    echo "ROUND INCOMPLETE: dispatched against $DISPATCHED, head is now $NOW - re-dispatch" >&2
    exit 1
  fi )
```

Three exits, three meanings, and they must stay distinct: **0** valid, **1** the
branch moved, **2** the check could not run. Round 15's version returned 0 for
both of the first two, which is the silent-failure class inside the detector
written to catch a silent failure.

The unsubstituted-placeholder case is why the regex guard is there. Without it,
`[[ "$NOW" == "<SHA recorded at C3>" ]]` is a string compare against literal
angle brackets, so forgetting to record a SHA produces output identical to a
genuinely moved branch — a missing input indistinguishable from the defect.

A mismatch means the reviewers did not all read the same commit. Discard the
round and re-dispatch against the new head. It is not a finding to be
dispositioned and it is not the agent's call.

**Reconstructing it for a round you did not record.** Every review comment
carries `original_commit_id`, so the SHAs a round's findings were written
against are recoverable after the fact:

```bash
( set -o pipefail
  gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/comments" \
    | jq -rs 'add | map(select(.in_reply_to_id == null)) | group_by(.original_commit_id)
        | map({sha: .[0].original_commit_id, n: length,
               first: (min_by(.id).created_at), last: (max_by(.id).created_at)})
        | sort_by(.first) | .[] | "\(.sha[0:8]) \(.n) \(.first) \(.last)"' \
    || { echo "could not read comment SHAs - rerun it" >&2; exit 2; } )
```

**Filter to roots.** A reply inherits its thread's `original_commit_id`, so
without `select(.in_reply_to_id == null)` each group carries dispositions posted
rounds later: on this PR, round 1's group came out as 22 findings plus 23 replies
spanning three hours across thirteen later rounds, and 8 of 14 consecutive pairs
overlapped in time. Filtered, every round's findings span ≤ 5 minutes and no two
rounds overlap. Round 15 shipped the unfiltered version and cited its output as
evidence the detector worked.

Read it as: each row is one round's findings, `n` is how many, and the two
timestamps bound the round. **Two rows whose windows overlap** is a round
dispatched against a moving branch.

What this cannot see, and it matters: a round that pushes nothing leaves the head
where it was, so its findings land on the previous row's SHA and the two collapse
into one. That is exactly the clean converging round — the one whose validity
decides the merge. Reconstruction is a forensic tool for rounds nobody recorded;
it is not a substitute for recording the SHA at C3.

**Working-tree edits are the same hazard one step earlier**, with a different
remedy: a reviewer reads the pushed head, so an uncommitted change is invisible
both to it and to `git diff main...HEAD` and cannot be reviewed at all. It
**does not invalidate the round** — nobody read it either way — but it must not
land in the round's F4 commit as though it had. `commit-and-push.sh` runs
`git add -A`, so clearing the tree is something you do before calling it:

```bash
( set -o pipefail
  DIRTY=$(git status --porcelain -- ':(exclude).beads') \
    || { echo "tree check failed - rerun it" >&2; exit 2; }
  if [[ -z "$DIRTY" ]]; then
    echo "tree clean - safe to commit the round"
  else
    echo "unreviewed edits present - commit or stash before F4:" >&2
    echo "$DIRTY" >&2
    exit 1
  fi )
```

`.beads/` is excluded because the ticket rule *requires* a reviewer to run
`bd show`, and the export can restage `issues.jsonl` underneath it. Two round-16
reviewers tested the mechanism and it is narrower than round 15 claimed: `bd
show` alone is a read and leaves the file byte-identical — seven invocations, no
change, positive control verified first. What restages it is a read *after an
unexported write*, because `.beads/export-state.json` keys on `last_dolt_commit`.
In round 15 a `bd create` advanced Dolt and the next reviewer's `bd show`
exported someone else's write. Both observations were true and the reason given
was wrong, which matters because the next reader uses the reason to diagnose a
dirty tree — one round-16 reviewer already repeated the wrong mechanism back.

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
  confirm that ticket exists **and is open** — `bd show <id>` exits 0 on a
  closed ticket, so existence alone is not the check:

  ```bash
  ( set -o pipefail
    OUT=$(bd show "$TICKET" 2>/dev/null) || { echo "ticket $TICKET does not exist" >&2; exit 1; }
    grep -q 'CLOSED' <<<"$OUT" && { echo "ticket $TICKET is closed - it cannot carry a live P1/P2" >&2; exit 1; }
    echo "ticket $TICKET exists and is open" )
  ```

  The finding lives there now. It matches all four non-fix dispositions the Reply Templates
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
