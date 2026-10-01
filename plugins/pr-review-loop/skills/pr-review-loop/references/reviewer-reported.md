# What counts as "reported"

Companion to the **Every configured reviewer must have reported** rule in
`SKILL.md`'s Convergence section. Read this when computing `D dispatched /
R reported` at F7.

"Reported" means a different artifact per reviewer class — an agent has a
manifest to return, a bot does not.

| Reviewer | Reported means | Not reported |
|---|---|---|
| **Agent reviewer (C3)** | Returned a posting manifest, including the literal "No issues found" | Task failed, returned nothing, or returned an off-shape answer that names no findings and does not say it found none |
| **External bot (C1/C2)** | A review by that bot exists on the commit the round reviewed | No such review. A check that *failed* is a third case — see below. |
| **Disabled bot, disabled agent, retired agent** | Outside the denominator — deliberately not dispatched | n/a |

A zero result is "not reported" — route it to "A reviewer that will not report"
in `SKILL.md`.

## Checking a bot

**Do not use a wrapper script's exit status, and do not use `--latest`.** Exit 0
means "nothing went visibly wrong", not "the bot reviewed this commit", and
`--latest` compares SHAs with `>=`, a lexicographic compare on hex. Both are
tracked in `devon-claude-skills-4gw`; until it lands, run this yourself, once per
configured bot:

```bash
( set -o pipefail
# Run this during COLLECT, AFTER C1's --wait - not before it (a bot that has not
# answered yet would read as not-reported) and not at report time. Head is the
# commit the reviewers are reviewing only until F4 pushes the round's fixes.
SHA=$(gh pr view <PR> --json headRefOid --jq .headRefOid) \
  || { echo "check failed: no head SHA" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "check failed: no head SHA" >&2; exit 2; }
COUNT=$(gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/reviews" \
  | jq -s --arg sha "$SHA" \
      'add | [.[] | select((.user.login == "gemini-code-assist[bot]"
                            or .user.login == "gemini-code-assist")
                           and .commit_id == $sha)] | length') \
  || { echo "check failed: could not query reviews" >&2; exit 2; }   # the only thing that catches this
echo "$COUNT" )
```

Non-zero means that bot reported on this commit.

**A failed check is not a zero.** Exit 2 means the check broke, not that the
reviewer is silent. Re-run **the check**, not the reviewer.

**One counter, both causes, within the round.** A reviewer accumulates a strike
for *any* attempt that produced no usable report — whether it did not report or
the check for it failed. Do not keep the two separate: alternating them would trip
neither. Two strikes **in the same round** stops the loop and asks the user, which
is what keeps the count off your memory and out of the round report — nothing
crosses a round boundary, so nothing has to survive one.

## A bot whose login you cannot establish

**Stop and ask the user — do not guess, and do not spend two rounds finding
out.** This is a first-contact stop, ahead of the two-strike rule, because a
guessed login returns `0` forever and the strikes would expire against a bot that
may be working fine.

This skill knows Gemini's two literals and no others. It never records Cursor's
actual login: the one place Cursor is named (`get-pr-comments.sh`) substring-matches
`"cursor"` against issue-comment authors, and issue comments carry no `commit_id`,
so it cannot answer "did this bot review this SHA". Record the real login here
when you get it.
