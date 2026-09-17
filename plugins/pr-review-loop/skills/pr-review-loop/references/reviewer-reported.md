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
in `SKILL.md`.

## Checking a bot

**Do not use a wrapper script's exit status, and do not use `--latest`.** Exit 0
means "nothing went visibly wrong", not "the bot reviewed this commit", and
`--latest` compares SHAs with `>=`, a lexicographic compare on hex. Both are
tracked in `devon-claude-skills-4gw`; until it lands, run this yourself, once per
configured bot:

```bash
set -o pipefail
SHA=$(gh pr view <PR> --json headRefOid --jq .headRefOid)
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "check failed: no head SHA" >&2; exit 2; }
COUNT=$(gh api --paginate "/repos/{owner}/{repo}/pulls/<PR>/reviews" \
  | jq -s --arg sha "$SHA" \
      'add | [.[] | select((.user.login == "gemini-code-assist[bot]"
                            or .user.login == "gemini-code-assist")
                           and .commit_id == $sha)] | length') \
  || { echo "check failed: could not query reviews" >&2; exit 2; }
echo "$COUNT"
```

Non-zero means that bot reported on this commit. Match **every login spelling the
bot posts under** — Gemini uses two, and five call sites in this skill carry both.

**A failed check is not a zero**, and it takes both guards to keep it that way.
`pipefail` is what makes a mid-pagination `gh` failure visible at all — without
it the pipeline reports `jq`'s status and a truncated page set yields a confident
wrong number. The explicit `|| { ...; exit 2; }` is what stops it: `set -e` does
**not** abort a failed assignment when this snippet runs as an agent's tool call
rather than as `bash script.sh`, so relying on ambient errexit leaves the bad
value assigned and execution continuing. Verified both paths.

Exit 2 means *the check failed*. Re-run **the check** — not the reviewer — and do
not spend a reviewer strike on it: the two-strike rule in `SKILL.md` counts rounds
where a reviewer did not report, not rounds where your tooling fell over.

## A bot whose login you cannot establish

**Stop and ask the user — do not guess, and do not spend two rounds finding
out.** This is a first-contact stop, ahead of the two-strike rule, because a
guessed login returns `0` forever and the strikes would expire against a bot that
may be working fine.

This skill knows Gemini's two literals and no others. Cursor's login appears
nowhere in it; the one place Cursor is identified (`get-pr-comments.sh`) matches a
substring over *issue* comments, which carry no `commit_id`. Record the answer
here when you get it.
