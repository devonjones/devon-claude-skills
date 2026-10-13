# Skill assessment: dream-reviewers

## Verdict
Ship with fixes — discoverable and accurate against the scripts, with some repeated prose and a non-third-person description (fixed in this worktree).

Assessment progress: 1 inventory, 2 mechanical, 3 read, 4 judge, 5 evals designed (not run), 6 report: all done.

Inventory: one file, `SKILL.md` (93 lines before fixes, 91 after). It links one file outside the skill dir, `../../references/MARKER-CONTRACT.md` (75 lines, no outbound links). No scripts in the skill; it drives `plugins/dream/scripts/dream`. Subcommands (`reviews-synth --source markers|github|all`, `reviews-distill`, `reviews-coverage`, `reviews-harvest`) and output filenames (`SCORECARDS-<source>.md`, `scorecards-<source>.json`, `COVERAGE.md`, `coverage.json`) were checked against `scripts/dreamlib/cli.py`; all match.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `dream-reviewers`, 16 chars, `[a-z0-9-]` |
| description | pass | 663 chars before fix (value measured with `wc -c`), no XML tags |
| SKILL.md body | pass | 93 lines (`wc -l`) before fix |
| reference depth | pass | MARKER-CONTRACT.md has no links (`grep '\]('` empty) |
| TOC on long refs | pass | only ref is 75 lines (<100) |
| paths | pass | `grep -c '\\'` = 0 |
| unlinked files | pass | none in skill dir |

## Findings
1. **P2** `SKILL.md:3-5` — description is imperative ("Validate… Mine… propose"), not third person. Rewrite as "Validates… Mines… proposes". *(measured: first words of the value)*
2. **P2** `SKILL.md:18-20,90-93` — "propose-only / user approves" is stated four times (lines 19-20, 59 heading context, 67, 90-93). Keep the opening statement and one consolidated line in step 3. *(judgement)*
3. **P2** `SKILL.md:78-80` — the `~/.dream/<slug>/reviews/` artifact list is given twice (lines 52 and 78-79) in different orders, and the line 52 list omitted `scorecards-<source>.json` and `coverage.json`, which step 2 reads. Merge into one list at line 52. *(measured: grep of filenames)*
4. **P3** `SKILL.md:18-20` — opening restates the skill's purpose already in the description ("The PR review loop is the project's main quality gate"). Shorten. *(judgement)*
5. **P3** `SKILL.md:51` — example "fired 353× but only N findings posted" is an unexplained magic number. Drop it. *(judgement)*
6. **P3** `SKILL.md:32` and `argument-hint` — the `(optional) project dir` argument is never connected to any instruction. Say it maps to `DREAM_PROJECT_DIR`. *(judgement)*
7. **P3** `SKILL.md:29-31` — Glob block runs straight into prose; add a blank line. *(judgement)*
8. **P3** `SKILL.md:22` — links `../../references/MARKER-CONTRACT.md`, outside the skill directory; if the skill is copied alone the link breaks. Fix needs files outside the skill dir or a packaging decision. *(judgement)*
9. **P3** `SKILL.md:61,84` — two near-identical directories: `reviews/` (backing data) vs `review/pending/` (proposals, read by the SessionStart hook). Both are correct per `reviews.py` and `hooks/session-start-proposals.sh`, but easy to confuse; renaming is a product change. *(judgement)*
10. **P3** `SKILL.md:59` — "YOU, or a spawned Opus Task" hard-codes a model choice and leaves the fork unresolved (no default). Which one is the default is the owner's call. *(judgement)*
11. **P3** `SKILL.md:37-46` — step 1 has no verify step (e.g. confirm `scorecards-all.json` exists before step 2; `reviews-synth` already errors when no findings). Adding it is behaviour/taste. *(judgement)*

Degrees of freedom: commands are exact where order matters, step 2 is heuristic judgement; appropriate. Model fit: Haiku would manage steps 0-1 but step 2's guardian-KEEP reasoning needs a stronger model; Opus is not over-explained.

## Description test
Should trigger: "audit my PR reviewers", "should we retire the complexity-reviewer?", "tune AGENT-REVIEWERS.md" — yes, all match the "Use when" terms.
Should not trigger: "mine my session logs for lessons" — no, description defers to `dream`; "review this PR" — no (pr-review-loop territory), though "PR reviewers" phrasing gives mild overlap risk. *(judgement)*

## Evaluations
Not run (no baseline runs requested). Proposed:

```json
[
  {
    "skills": ["dream-reviewers"],
    "query": "Validate our PR reviewers. Markers exist for the last month but older PRs only live on GitHub.",
    "files": ["fixture ~/.dream/<slug>/markers/pr-review-loop.jsonl"],
    "expected_behavior": [
      "runs reviews-synth --source markers, then reviews-distill, reviews-synth --source all, reviews-coverage",
      "reads scorecards-all.json and coverage.json, not a bare scorecards.json",
      "notes that github-only counts under-count and cites coverage"
    ]
  },
  {
    "skills": ["dream-reviewers"],
    "query": "silent-failure-hunter has a 10% fix rate but DECISIONS.md says errors must never be swallowed. Keep or retire?",
    "files": ["DECISIONS.md", "AGENT-REVIEWERS.md", "scorecards fixture"],
    "expected_behavior": [
      "classifies it as a guardian KEEP citing the decision",
      "does not edit AGENT-REVIEWERS.md or config"
    ]
  },
  {
    "skills": ["dream-reviewers"],
    "query": "Run the reviewer health pass again, same day as this morning's run.",
    "files": ["existing ~/.dream/<slug>/review/pending/<today>-reviewers.md"],
    "expected_behavior": [
      "overwrites the same-day file rather than appending",
      "file is self-contained and lives in review/pending/",
      "reviewers with fewer than ~5 findings are not recommended for retirement"
    ]
  }
]
```

## Not assessed
Runtime behaviour (no runs); correctness of the dream scripts themselves (out of scope, shared plugin code).

## Changes made
1. fixed - description rewritten in third person (Validates / Mines / proposes).
2. fixed - propose-only repeated text cut; step 3 now one sentence ("The user approves every ...").
3. fixed - one artifact list at line 52 including `scorecards-<source>.json` and `coverage.json`; duplicate sentence in step 2 removed.
4. fixed - opening paragraph shortened.
5. fixed - "353×" example removed.
6. fixed - added "set `DREAM_PROJECT_DIR` to the optional project-dir argument".
7. fixed - blank line after the Glob block.
8. left for owner - link leaves the skill directory; fixing means moving/duplicating the contract or changing packaging.
9. left for owner - directory naming is a product decision.
10. left for owner - choosing the default executor/model is the owner's taste.
11. left for owner - adding a verify step changes behaviour.
