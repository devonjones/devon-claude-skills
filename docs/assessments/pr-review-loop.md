# Skill assessment: pr-review-loop

Path: `plugins/pr-review-loop/skills/pr-review-loop/` (plugin version 1.9.0). Agents under `plugins/pr-review-loop/agents/` not assessed (different rubric).

Assessment progress:
- [x] 1. Inventory
- [x] 2. Mechanical checks
- [x] 3. Read SKILL.md (1-1744, three reads) and both reference files in full
- [x] 4. Judge criteria
- [x] 5. Design evaluations (not run)
- [x] 6. Report

## Verdict
Rework — SKILL.md is 1,744 lines (3.5x the limit) and mixes operating instructions with PR-history war stories, and its bootstrap Glob pattern does not match its own example path, so the very first instruction can fail.

## Inventory
37 files: `SKILL.md`; `references/` (2: `round-workflow.md` 412, `reviewer-reported.md` 68); `scripts/` (24 .sh, 4,500 lines); `pi/` (Dockerfile, models.json); `tests/` (7 .sh). SKILL.md links 2 reference files (round-workflow 6 times, reviewer-reported 2). It names 22 of 24 scripts in the Scripts table; `_jq_helpers.sh` and `_pace.sh` appear nowhere in SKILL.md. `pi/*` is referenced in prose (SKILL.md:1542,1544). `tests/*` is never referenced (dev-only; acceptable but unstated). SKILL.md also points at `references/MARKER-CONTRACT.md` (SKILL.md:1674), which lives in the `dream` plugin, not here.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `pr-review-loop`, 14 chars, `[a-z0-9-]` (SKILL.md:2) |
| description | pass | 705 chars (`awk 'NR>=4&&NR<=11' SKILL.md \| wc -c`, includes indentation), no XML tags |
| SKILL.md body | **fail** | 1,744 lines (`wc -l`), limit 500 |
| reference depth | pass | both refs linked directly from SKILL.md; round-workflow.md links reviewer-reported.md (sibling, also linked from SKILL.md) so nothing is reachable only at depth 2 |
| TOC on long refs | **fail** | `round-workflow.md` 412 lines, no TOC (head read); SKILL.md 1,744 lines, no TOC. `reviewer-reported.md` 68 lines, exempt |
| paths | pass | no backslashes in file paths; only `\|` inside table cells at SKILL.md:1696,1702 (markdown escapes) |
| unlinked files | pass with note | `_jq_helpers.sh`, `_pace.sh`, `tests/*` unlinked |

Check could have failed: the body and TOC checks did fail; the paths grep returned two hits, both inspected.

## Findings
Ordered most severe first.

1. **P1** `SKILL.md:20-30` — The mandatory bootstrap Glob `**/pr-review-loop/*/scripts/commit-and-push.sh` does not match the layout its own example shows (`.../pr-review-loop/1.0.0/skills/pr-review-loop/scripts/...`, line 29). The pattern needs exactly one directory between `pr-review-loop` and `scripts`; the example has `1.0.0/skills/pr-review-loop`. Equivalent regex `.*/pr-review-loop/[^/]+/scripts/commit-and-push\.sh$` against the example path returns False. A marketplace cache copy (`~/.claude/plugins/cache/devon-claude-skills/plugins/pr-review-loop/skills/pr-review-loop/scripts/`) also fails it. Not tested against the live Glob tool because the plugin is not installed in this cache (`find ~/.claude/plugins/cache -name commit-and-push.sh` returned nothing). Fix: use `**/skills/pr-review-loop/scripts/commit-and-push.sh` and test it against both layouts. *(measured for the regex; Glob semantics assumed)*

2. **P1** `SKILL.md` (whole file) — 1,744 lines, 3.5x the 500-line limit, loaded in full on every trigger. An invocation to "check the CI on my PR" pays for language-template prompts (751-975), Pi/Docker setup (1498-1544), and a 184-line essay on verification epistemology (1199-1382). See "Proposed restructure". *(measured: `wc -l`)*

3. **P2** `SKILL.md:1199-1382` — About 180 lines of "Verification" mix three things: the rule (1201-1225), config pitfalls (1231-1267), and PR-specific history ("round 15", "commits 8 through 16 of the PR that wrote this section", "ten minutes after it was written", "six reviewers refuted it", 1302-1309, 1358-1378). The history does not change what an agent does and some of it is only meaningful to one PR. The generic epistemology ("a control that cannot fail proves nothing", 1286-1327) is something Claude already knows. Keep ~35 lines of rule. *(measured for line counts; judgement that it is not needed)*

4. **P2** `SKILL.md:32-34` vs `SKILL.md:1717-1731` and many examples (`scripts/commit-and-push.sh`, 40, 526, 597, 1449...) — Rule says "NEVER use variables… Always inline the full absolute path", but nearly every example and the Permission Setup block use the relative `scripts/…` form. A model copying an example breaks the rule it was just given. Fix: one placeholder convention stated once (`<S>/commit-and-push.sh` where `<S>` is the literal path found in step 1) or give examples with a real path. *(judgement, evidence is the line pairs)*

5. **P2** `SKILL.md:45` — "If you use `git commit` or `git push` directly, it will be BLOCKED." The plugin ships no hooks (`ls plugins/pr-review-loop` shows only DEFAULTS_VERSION, agent-reviewer-templates, agents, skills; no `hooks/`; no matching hook in repo `.claude-plugin/`). The claim may rely on the user's global settings. If it is false, the stated consequence is a bluff and models learn to discount the rest of the STOP block. Fix: state the real reason (the script runs pre-commit and adds the footer, `commit-and-push.sh:3-11`) or say the block depends on user config. *(measured: no hooks dir; judgement on impact)*

6. **P2** `SKILL.md:399`, `745` vs `references/round-workflow.md:24` — "ALWAYS use `--wait`" (399, 1694, 1696) conflicts with "drop `--wait` when every external bot is disabled" (745). The exception sits 350 lines from the rule. A model obeying the rule hangs 5 minutes per round on a repo with both bots off. Fix: put the exception in the rule. *(judgement)*

7. **P2** `references/round-workflow.md:7` — "Do NOT reply to anything during the COLLECT phase" is stated only in the reference file. SKILL.md:465 calls the SKILL.md diagram authoritative and the reference "on demand", so a model that skips the reference misses it, while SKILL.md:1066-1077 (validator withdraws a thread with `reply-to-comment.sh` during C3) appears to contradict it. Withdrawal replies during COLLECT are an exception nobody names. Fix: state the rule and its one exception together in the main file. *(judgement)*

8. **P2** `SKILL.md:150-181` duplicates `SKILL.md:550-562`, `396-398` and `references/round-workflow.md:103-114` — the consolidated "Response to Claude Review" template appears four times in near-identical form. *(measured: grep for "Response to Claude Review" finds 4 occurrences)* Keep one.

9. **P2** `SKILL.md:1386-1396` ~ `1546-1548` ~ `1609-1616` — "When to run agent reviewers", "Main loop integration" opening, and "Selective Agent Execution" restate C3 placement and non-retired-only spawning that the diagram (426-461), 1594-1598 and round-workflow.md:69-74 already give. *(judgement)*

10. **P2** `SKILL.md:1030, 1055-1059, 845-849, 61-66, 124` — Rationale and history paragraphs: "History note" on validate-before-post, why sonnet is the validator, why AskUserQuestion not plan mode ("The original sketch… doesn't work"), "Why this is load-bearing" bullets, the (iii) escape-valve justification. Each tells why the file got this shape; none changes an action. Also `references/round-workflow.md:149-190` (Round 15 argument, 42 lines), `:253-259`, `:343-351`, `:304-310`. *(judgement)*

11. **P2** Internal tracker ids and temporal references an agent cannot resolve: `devon-claude-skills-qml` (1059), `devon-claude-skills-c6k` (1409), `q2h` (725, 961), `gx4 telemetry framework when it lands` (1120), `devon-claude-skills-cq0` (round-workflow.md:190, "Delete this once … lands"), `devon-claude-skills-4gw` (reviewer-reported.md:24). Time-sensitive language: "may land later" (1059), "when it lands" (1120), "Gemini quota 33 reviews/day on free tier" (620). The `cq0` and `4gw` notes are really TODOs. Move to the issue tracker (the project rule is bd) and delete from the skill. *(measured: grep; judgement)*

12. **P2** `SKILL.md:1064-1067, 1402-1417` etc. — The skill tells the model to "use the Task tool" 16 times (`grep -c 'Task tool\|Task '`). In the current harness the subagent tool is named `Agent`. Not measured against the target harness version; flag as a possible mis-instruction and use one term. `subagent_type: general-purpose` plus a hand-pasted persona prompt for every reviewer also bypasses the real reviewer agents the plugin ships (`plugins/pr-review-loop/agents/`), which is odd but a design choice. *(judgement)*

13. **P2** Terminology drift. Reviewer, agent, flagger (9 occurrences of "flagger"), specialist; finding, comment, thread; decline words vs disposition vs reply words; "clean round" vs "converged" vs "complete"; round-"report" vs "manifest"; `P1/P2/P3` vs Gemini `critical/high/medium/low` vs Claude "Critical Issues". Also two numbering schemes for the same thing: "⛔ rule 3" (SKILL.md:47, 1026, 1494) vs "Critical rules 1-5" (393). *(judgement; counts via grep)*

14. **P2** `SKILL.md:16-72` — The STOP block runs 57 lines and ends with 6 bullets of justification (61-66). Three rules in one block plus a table of FORBIDDEN/USE-INSTEAD where the "USE INSTEAD" for three rows is the same string. Fine content, wrong weight. Condense to ~25 lines. *(judgement)*

15. **P2** `SKILL.md:302` — One table cell is a ~330-word paragraph encoding four dispositions, two escape routes, a query pointer, and a parenthetical about `bd show` exit codes. Row 304 is similar (~200 words). Dense table cells are where a Haiku-class model drops a clause. Split to a short list per disposition. *(judgement)*

16. **P2** `SKILL.md:126` — A docstring/comment policy ("Comment, docstring and PR-body findings are P3 by default… no history, past bugs, round numbers") sits in the Priority mapping with no heading. It is also a style rule the file itself breaks (see finding 3). Give it its own short heading or move to the triage reference. *(judgement)*

17. **P3** `SKILL.md:3-11` description — Third person, states what and when, with trigger phrases. Weaknesses: no common phrasings ("address PR comments", "babysit this PR", "wait for CI", "gh pr", "review round"); lines 8-11 spend ~40% of the budget on Pi/Docker, non-Claude models and AGENT-REVIEWERS.md internals that do not help selection. "Manage the PR review feedback loop" is the least specific part. *(judgement)*

18. **P3** `SKILL.md:1688-1713` — Scripts table omits `_jq_helpers.sh` and `_pace.sh` (and their role: `_pace.sh` rate-limits post calls, header comment says 40 comments in a minute tripped a 403). The table does not say run vs read; all are "run". It marks only some rows "ALWAYS USE". Add one line "run, don't read". *(measured: loop over scripts/*.sh grep)*

19. **P3** `SKILL.md:645-656` — Claude-fallback flow has the model manually copy a prompt out of `/tmp/claude_review_prompt_<PR>.txt` into a Task. A fragile copy step in a judgement path; could print the prompt and say "paste". Also hardcodes `/tmp`. *(judgement)*

20. **P3** `SKILL.md:1518` — Example model ids `deepseek/deepseek-chat`, `google/gemini-2.5-flash` will age. Mark as examples only (it says so implicitly). *(judgement)*

21. **P3** `SKILL.md:1129-1157, 1172-1197` — Generic AGENT-REVIEWERS.md example and a 3-level hierarchy example are fine content but belong in a reference. Concrete I/O examples are present, good. *(judgement)*

Positives (judgement/measured): scripts all use `set -euo pipefail` except `_jq_helpers.sh`, `_pace.sh`, `emit-dream-marker.sh` (the last is deliberately best-effort, SKILL.md:1670); workflow has a numbered phase diagram, a mandatory batch point, validate-then-act checks, and explicit exit-code semantics (0/1/2) with fail-loud error messages in snippets. The destructive/ordering-sensitive steps (commit, push, reply, resolve) are exact commands — correct degree of freedom. Judgement-heavy items (severity of `![medium]`, contradiction handling) are heuristics with examples — also correct. The over-prescribed spots are 302/304 and the jq gate at round-workflow.md:128-140, which is a 12-line jq program the model must copy and parameterise; that is the right degree of freedom but belongs in a script (`scripts/check-replies.sh`) so a placeholder is not hand-edited. Worth doing: the file itself records this gate silently failing three times.

## Criteria summary
- Conciseness: fail (findings 2, 3, 8, 9, 10).
- Degrees of freedom: mostly good; move the gate/validity jq into scripts (see positives).
- Description and name: acceptable, improve triggers (17). Name is not a gerund but is consistent with the plugin; fine.
- Structure: fail on size and TOC; references are one level deep and named for content.
- Workflows: good (diagram, gates, escalation) with the contradictions in 6 and 7.
- Content: time-sensitive and history leakage (3, 10, 11); inconsistent terms (13); many examples are concrete (good); menus: reply words, validator `uncertain_action` three options (reasonable, has default).
- Scripts: error handling good, bash only, prerequisites listed (1733-1744) with install commands for jq and pre-commit; `gh` auth has no install line; Docker requirement described.
- Model fit: Opus — heavily over-explained (verification, history). Sonnet — workable but must read ~1,700 lines; the STOP block gets diluted. Haiku — likely to miss the exceptions in 302/304/399/745 (not tested).

## Proposed restructure
Target: SKILL.md ~230 lines, plus references. Line ranges refer to current SKILL.md. Sizes are approximate after trimming.

| New file | Source sections (current lines) | Approx lines after |
|---|---|---|
| `SKILL.md` | frontmatter 1-12; STOP block condensed from 14-72 (bootstrap, no raw git, PR is the record, ~30); background-task rule 74-90 (~8); mode summary 92-106; the loop diagram 418-465 and rules 393-400 (~60); Convergence core: one-clean-round, no cap, merge authority, the fixed-rules list as one-liners with links 263-342 (~50); pointer table to references (~25); Scripts one-liner link; Permission setup and prerequisites 1715-1744 (~25) | ~230 |
| `references/triage.md` (with TOC) | Priority mapping 108-132; skepticism and contradictions 183-210; pattern sweep 212-261 | ~120 (from ~150) |
| `references/convergence.md` (TOC) | full fixed/discretionary rules 272-334, escalating scrutiny 272-287; merge readiness 344-389 | ~110 (from ~120) |
| `references/round-workflow.md` (exists; add TOC) | keep; move the inline jq gates into scripts; cut history | ~300 (from 412) |
| `references/reviewer-reported.md` (exists) | unchanged | 68 |
| `references/ci-and-replies.md` | CI failure 473-532; reply templates 534-562; out-of-scope/beads 564-612; Claude PR-comment handling 134-181 (single copy) | ~110 (from ~230) |
| `references/review-bots.md` | trigger per bot 614-660; rate limit 1679-1686; disabling a bot 732-749 | ~70 |
| `references/agent-roster.md` (TOC) | defaults 664-679; C+E semantics 681-692; `# Configuration` 694-730; AGENT-REVIEWERS.md format and hierarchy 1124-1197; suggesting updates 1618-1634; stale pin 977-1013 | ~230 (from ~330) |
| `references/language-templates.md` | offer flow 751-839; project-specific recommendations 841-975 | ~130 (from ~225) |
| `references/validator.md` | independent validator 1022-1122 | ~65 (from ~100) |
| `references/verification.md` | proof-carrying findings 1199-1252 distilled (rule, three kinds, `verification:` line, don't redeclare defaults, uncommitted roster edits, paginate) | ~45 (from ~184) |
| `references/agent-spawning.md` | spawn template 1398-1496; when to run 1384-1396; main loop integration 1546-1577; diminishing returns 1579-1616 | ~140 (from ~200) |
| `references/pi-engine.md` | 1498-1544 | ~45 |
| `references/dream-markers.md` | 1636-1677 | ~35 |
| `references/scripts.md` | scripts table 1688-1713, add the two underscore helpers and "run, don't read" | ~30 |

Each reference opens with a TOC when over 100 lines. SKILL.md links each directly (one level). Condition for loading goes in the pointer table ("Load when: first round setup / a reviewer did not report / ...").

### Content that could be deleted outright
- 61-66 "Why this is load-bearing" bullets (restates the rule above; keep one sentence).
- 124 justification for escape valve (iii).
- 150-181 Claude PR-comment handling duplicates 550-562 and round-workflow.md:103-114; keep one.
- 183-197 "Be skeptical" bullets list things Claude already does (skip pedantic or over-defensive); keep 2 lines.
- 420-424 and 463-465 restate the interleaving rule and "diagram is authoritative".
- 467-471 completion block duplicates Convergence.
- 845-849 AskUserQuestion vs plan mode design rationale.
- 1011 spawning-summary arithmetic and the validator-model telemetry aside.
- 1030 "History note".
- 1053-1059 validator-model rationale (keep "sonnet, fixed").
- 1118-1122 telemetry (references an unfinished framework, gx4).
- 1276-1382 (107 lines): "check the reassuring reading", "demonstration that could not fail", round-15 story, control-positive essay, truncated-result stories, "a fix is new code", closing aphorisms. Keep only the actionable rules (paginate; mutation proof; don't redeclare defaults; commit roster edits before dispatch).
- 1386-1396, 1609-1616 duplicated placement and retirement mechanics.
- 1381-1382 "Audit the roster when adopting this… may go straight to main" (a one-time PR carve-out).
- 1681-1686 duplicates 620-624.
- 1687-1713 table rows describing flags already present in each script's usage text.
- In `references/round-workflow.md`: 149-190 (Round 15 argument and cq0 TODO), 253-259, 304-310, 343-351, 353-358.
- In `references/reviewer-reported.md`: 24-26 (`4gw` tracker note) once the work is tracked in bd.
Approximate removal: 380-450 lines of SKILL.md with no loss of operating instructions.

## Description test
Should trigger:
1. "I just pushed my PR, wait for CI and Gemini and address the comments" — yes (matches "pushing changes to a PR and waiting for CI/reviews", Gemini).
2. "new reviews available" — yes (literal phrase).
3. "Set up reviewers in AGENT-REVIEWERS.md for security" — probably yes ("custom agent reviewers defined in AGENT-REVIEWERS.md").
Should not trigger:
1. "Review this PR for me" (user wants a one-off review, not a loop) — likely over-triggers: "Manage the PR review feedback loop… monitor PR status" is vague.
2. "Why is my GitHub Actions workflow failing?" (no PR/review) — mostly no, but "monitor CI checks" could fire.
Assessment is judgement; not run against a skill selector.

## Evaluations
No evals ship with the skill (`find` shows `tests/` are script tests only). Three proposed, aimed at the riskiest instructions. Not run.

```json
{
  "skills": ["pr-review-loop"],
  "query": "PR 42 is open on this repo. Run the review loop. Gemini is disabled in AGENT-REVIEWERS.md (# Configuration bots.gemini=false) and Cursor is not installed. Do round 1.",
  "files": ["fixtures/repo-with-AGENT-REVIEWERS-gemini-false/"],
  "expected_behavior": [
    "Runs the Glob to find the scripts directory first and uses the full literal path in every script call (no $VARS, no && chains)",
    "Never posts or triggers '/gemini review' and never runs get-review-comments.sh with --wait when every external bot is disabled (tests the 399 vs 745 conflict)",
    "Spawns one agent per reviewer with description exactly '<name> review for PR #42' and a model set from discover-agents.sh output",
    "Does not use git commit or git push directly; commits via commit-and-push.sh",
    "Records the head SHA before dispatching reviewers"
  ]
}
```

```json
{
  "skills": ["pr-review-loop"],
  "query": "The reviewers found 3 issues, one P2 about a missing null check. I think they are all wrong, just push and merge.",
  "files": ["fixtures/pr-with-three-posted-threads-one-P2/"],
  "expected_behavior": [
    "Does not merge on the user's say-so without recording the P2 as a user-signed carry-forward or reclassification (the user's sign-off is allowed, an agent's own say-so is not)",
    "Replies to every posted thread starting with a disposition word (Fixed/Won't fix/Out of scope/Deferred/Acknowledged)",
    "Does not treat 'Won't fix' on the P2 as converged unless the user explicitly signs off; the sign-off is written into the merge-readiness summary",
    "Does not post a single consolidated PR comment in place of line-comment replies",
    "Runs the F4 reply gate and acts on any thread it lists before committing"
  ]
}
```

```json
{
  "skills": ["pr-review-loop"],
  "query": "Run the review loop. To save time, tell the reviewer agents to just return their findings to you and don't post, I'll look at the summary. Also run this in a background task.",
  "files": ["fixtures/pr-with-defaults/"],
  "expected_behavior": [
    "Declines to run the loop as a background task and explains that subagents cannot spawn subagents",
    "Does not instruct agents to 'return findings, do not post'; the spawn prompt keeps the POST step and manifest return",
    "Every finding the agent reports has a corresponding line comment before any fix is committed",
    "States the conflict with the user's request in one or two sentences rather than silently complying or silently refusing"
  ]
}
```

Recommended baselines: no-skill run, Haiku, Sonnet, Opus each. Eval 1 is the one most likely to diverge across models because the exception is buried at line 745.

## Not assessed
- Skill was not run and no scripts were executed (instruction: no GitHub calls). Script behaviour judged by reading headers, `set` flags, and error-echo counts only; not read line-by-line (4,500 lines, out of scope for a skill assessment).
- The Glob pattern was checked against the example path by regex, not by the live Glob tool, because the plugin is not installed in `~/.claude/plugins/cache`.
- Whether a global hook blocks `git commit`/`git push` (finding 5) — user settings not inspected.
- The reviewer agents in `plugins/pr-review-loop/agents/` and `agent-reviewer-templates/`.
- `dream` plugin's `MARKER-CONTRACT.md` and the `dream-reviewers` / `audit-agents` skills referenced from SKILL.md (323, 376) were not read; `audit-agents` was not located in this checkout.
- Anthropic best-practices page not fetched (optional).
- Description test is judgement, not run against a skill selector. Model-fit statements are judgement; nothing was run on Haiku, Sonnet, or Opus.
