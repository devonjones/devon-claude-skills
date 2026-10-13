# Local Mode

One review pass against a local branch, posting nothing to GitHub. Use it before
opening a PR, or before pushing a large change. Review, fix, push; there is no loop.

1. Commit your work. Reviewers read committed code.
2. `scripts/discover-agents.sh --base <ref>` (usually `origin/main`) diffs
   `<ref>...HEAD`. Choose the roster as in SKILL.md "Choosing the Roster".
3. Spawn the reviewers with the normal template, substituting `local` for the PR
   number, skipping step 1 (no prior comments), and reading
   `git diff <ref>...HEAD -- <files>` in step 3.
4. `scripts/post-findings.sh local --local` prints the merged report and posts
   nothing.
5. Fix with the BATCH POINT's judgement, commit (⛔ rule 2), push.
