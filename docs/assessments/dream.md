# Skill assessment: dream

## Verdict
Ship with fixes — discovery and workflow are sound; the cost is duplicated prose (corpus definition, scheduling) and an unclear marker instruction.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `dream`, 5 chars, `[a-z0-9-]`, no reserved words |
| description | pass | 674 chars before fix (python length of the folded value); 520 after |
| SKILL.md body | pass | 135 lines before fix (`wc -l`); 121 after |
| reference depth | pass | the 3 referenced files (DESIGN, MARKER-CONTRACT, SCHEDULING) link no further files (`grep -n '](' ` finds only DESIGN -> MARKER-CONTRACT, a sibling reference) |
| TOC on long refs | fail | SCHEDULING.md is 203 lines (`wc -l`), no TOC (`grep -n '^#'` shows headings only after line 1); others <100 |
| paths | pass | no backslashes in SKILL.md (`grep '\\'` empty) |
| unlinked files | pass | skills/dream holds only SKILL.md; scripts/hooks/tests are the plugin's runtime, called by name from SKILL.md |

## Findings
1. **P2** `skills/dream/SKILL.md:3-13` — description opened with an imperative ("Mine this project's...") not third person, and spent ~140 chars on mechanism ("friction-focused digests..."). Rewrite in third person, shorter, same triggers. *(measured: 674 chars; judgement on voice)*
2. **P2** `SKILL.md:121-135` — scheduling section restated the headless command, permission-mode rationale, platform list and staggering, all already in `references/SCHEDULING.md:13-40,199`. Cut to a pointer. *(measured, duplicated text)*
3. **P2** `SKILL.md:33-36` vs `64-68` — the known corpus is defined twice. Step 3 now refers to step 0. *(measured)*
4. **P2** `SKILL.md:22-24` — mandatory "read DESIGN.md for the why"; DESIGN.md is rationale/history (hard-won findings, why markers exist) that the agent does not need to act. Removed the instruction. *(judgement)*
5. **P2** `SKILL.md:22-24` / `references/MARKER-CONTRACT.md:48-60` — SKILL.md says to "fold in any structured markers" but gives no step for it; no code reads generic `insight/correction/decision/friction` markers (only `reviews-synth --source markers` reads reviewer findings, `grep marker` in distill.py/synth.py/cli.py), and the contract mentions a `/dream-mark` command that does not exist in the plugin. Which behaviour is intended is the owner's call. *(measured via grep; intent is judgement)*
6. **P2** `references/SCHEDULING.md` — 203 lines with no table of contents. Shared with `dream-reviewers`, so outside this skill's directory. *(measured)*
7. **P3** `SKILL.md:102,62` — Task-spawn advice stated in the heading and again after step 4, and the closing "Done." was filler. Tightened. *(judgement)*
8. **P3** `SKILL.md:18,59` — "Opus" hard-coded as the consolidation model. Fine today, but ties the skill to a model name. *(judgement)*

## Description test
Should trigger: "dream over my logs for this repo" — yes (quoted phrase); "mine my past sessions for CLAUDE.md rules" — yes; "set up a nightly self-improvement pass over my sessions" — yes.
Should not trigger: "tune my PR reviewer roster" — no, explicitly routed to `dream-reviewers`; "summarize what I did today" — probably no (no friction/memory/doc terms), some risk since "learn from past sessions" is broad.

## Evaluations
```json
[
  {
    "skills": ["dream"],
    "query": "Dream over my logs for this project and tell me what to add to CLAUDE.md.",
    "files": ["fixture project with 3 distilled digests, two sharing one lesson, and a DECISIONS.md already recording another lesson"],
    "expected_behavior": [
      "Reads DECISIONS.md in full before consolidating",
      "Drops the lesson already in DECISIONS.md and cites it",
      "Routes the 2-session lesson to CLAUDE.md and the 1-session lesson to memory",
      "Writes only ~/.dream/<slug>/review/pending/<YYYYMMDD>-dream.md and does not edit CLAUDE.md"
    ]
  },
  {
    "skills": ["dream"],
    "query": "Run dream again, it already ran today.",
    "files": ["existing review/pending/<today>-dream.md"],
    "expected_behavior": [
      "Overwrites today's pending file rather than appending",
      "Does not write into review/reviewed/",
      "Reports per-bucket counts including decisions-log: 0 when nothing qualifies"
    ]
  },
  {
    "skills": ["dream"],
    "query": "Dream over my logs; the DECISIONS.md log looks fully up to date.",
    "files": ["well-maintained DECISIONS.md, sessions with no new decisions"],
    "expected_behavior": [
      "Proposes zero decisions-log entries and says so",
      "Does not invent entries for merely undocumented items",
      "Never edits DECISIONS.md"
    ]
  }
]
```
Not run (no baseline runs requested).

## Not assessed
Script logic and the plugin's pytest suite beyond a re-run after edits (no scripts were changed); behaviour on Haiku/Sonnet; evaluations were designed, not run. Best-practices page not fetched.

## Changes made
1. fixed - description rewritten in third person, 674 -> 520 chars; triggers kept.
2. fixed - scheduling section cut to a 4-line pointer to SCHEDULING.md.
3. fixed - step 3 now points to step 0 for the corpus definition.
4. fixed - removed the "read DESIGN.md" instruction (file left in place).
5. left for owner - decide whether the session miner should consume generic markers (add a step) or drop the sentence, and whether `/dream-mark` should exist; behaviour decision.
6. left for owner - adding a TOC edits `plugins/dream/references/SCHEDULING.md`, shared with `dream-reviewers`.
7. fixed - Task-spawn wording tightened; trailing "Done." removed.
8. left for owner - whether to name a model at all is a taste/product call.
