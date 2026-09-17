# What counts as "reported"

Companion to the **Every configured reviewer must have reported** rule in
`SKILL.md`'s Convergence section. Read this when computing `D dispatched /
R reported` at F7.

"Reported" means a different artifact per reviewer class — an agent has a
manifest to return, a bot does not.

| Reviewer | Reported means | Not reported |
|---|---|---|
| **Agent reviewer (C3)** | Returned a posting manifest, including the literal "No issues found" | Task failed, returned nothing, or returned an off-shape answer that names no findings and does not say it found none |
| **External bot (C1/C2)** | A review by that bot exists whose commit matches the current head SHA | No such review, or you could not establish one either way |
| **Disabled bot, disabled agent, retired agent** | Outside the denominator — deliberately not dispatched | n/a |

A zero result is "not reported" — route it to "A reviewer that will not report"
in `SKILL.md`. That is also what an enabled-by-default bot that was never
installed on the repo looks like.

## Checking a bot

**Do not use a wrapper script's exit status, and do not use `--latest`.** Exit 0
means "nothing went visibly wrong", not "the bot reviewed this commit", and
`--latest` compares SHAs with `>=`, a lexicographic compare on hex. Both are
tracked in `devon-claude-skills-4gw`; until it lands, run this yourself:

```bash
set -euo pipefail
SHA=$(gh pr view <PR> --json headRefOid --jq .headRefOid)
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "could not establish head SHA" >&2; exit 1; }
gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/reviews" \
  | jq -s --arg sha "$SHA" \
      'add | [.[] | select((.user.login == "gemini-code-assist[bot]"
                            or .user.login == "gemini-code-assist")
                           and .commit_id == $sha)] | length'
```

Non-zero means that bot reported on this commit. Run it once per configured bot.

**Three ways this check lies if you shorten it:**

- **Match every login spelling the bot posts under.** Gemini posts as both
  `gemini-code-assist[bot]` and `gemini-code-assist`; five call sites in this
  skill carry both. Matching one spelling when a bot uses two reads a real review
  as "not reported" and deadlocks the round.
- **Fail loudly, not to zero.** Without `set -euo pipefail` and the SHA guard, a
  `gh` failure mid-pagination or an empty `$SHA` produces `0` — indistinguishable
  from "the bot did not review". A failed *check* is "could not establish", which
  is not reported, but it must be recorded as `failed(check-error)` in the
  `Reported:` line rather than as a clean zero, or the re-run counts a tooling
  outage as reviewer silence.
- **One bot per query.** A fused result cannot produce the per-reviewer
  `Reported:` line, and one bot's review would certify the other.

**A bot whose login you cannot establish cannot be checked.** This skill only
knows Gemini's literals; Cursor's login string appears nowhere in it, and the one
place Cursor is identified (`get-pr-comments.sh`) does a substring match over
*issue* comments, which carry no `commit_id`. Guessing a login yields `0`, which
is indistinguishable from a bot that never ran and deadlocks the loop at the
two-strike rule. If a configured bot's login is unknown, stop and ask rather than
guessing — and record the answer here.
