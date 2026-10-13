# Skill assessment: handoff

## Verdict
Ship with fixes: the skill is clear and appropriately scoped, but it gives two contradictory instructions about where the output path goes and leaves the filename timestamp format unspecified.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `handoff`, 7 chars, `[a-z0-9-]`, no reserved words (frontmatter read; yaml parse) |
| description | pass | 488 chars (python `len` on the parsed value), no XML tags (grep) |
| SKILL.md body | pass | 146 lines (`wc -l`) |
| reference depth | pass | no reference files; `find` shows only SKILL.md (plus plugin.json) |
| TOC on long refs | pass | n/a, no references; SKILL.md is under 500 lines |
| paths | pass | `grep -c '\\' SKILL.md` = 0 (the grep would match a backslash, so it could have failed) |
| unlinked files | pass | none |

Inventory: `plugins/handoff/.claude-plugin/plugin.json`, `plugins/handoff/skills/handoff/SKILL.md`. No scripts, no evaluations shipped.

## Findings
1. **P2** `SKILL.md:29` vs `SKILL.md:140-144` — Two instructions conflict: the path is "the last line of your response", but "After saving" lists path first and the Resume command last. Claude must break one. Drop the "last line" clause and let "After saving" govern. *(measured: both lines quoted; judgement on impact)*
2. **P2** `SKILL.md:24,37,96` — Filename says `<UTC-timestamp>`, frontmatter says ISO-8601 (contains colons), the only example is `2026-05-21T14-30Z`. The filename format is never stated, so colons or inconsistent formats are likely. State the colon-free format once. *(judgement)*
3. **P3** `SKILL.md:27` — "collision-free" is an overclaim (two handoffs on the same topic in the same minute collide); it also adds nothing actionable. Delete the claim. *(judgement)*
4. **P3** `SKILL.md:19` — Restates the output location that the next section gives. Shorten to a pointer. *(judgement)*
5. **P3** `SKILL.md:80` vs `SKILL.md:101-103` — "Do NOT duplicate" appears in section 4 and again as the "Reference, don't duplicate" rule. Keep the rule, trim section 4. *(judgement)*
6. **P3** `SKILL.md:3-12` — Description has no trigger phrases a user would type ("handoff", "hand off", "pass this to another agent", "/handoff"); it relies on paraphrase. Adding them changes triggering and is the owner's call. *(judgement)*
7. **P3** whole file — The concept is called "handoff document", "doc", "handoff" and "the doc" interchangeably. Low risk. *(judgement)*
8. **P3** `SKILL.md:19-29` — Output goes to the OS temp dir, which does not survive reboot or a different machine, yet the description lists "different machine" as a use case. Product decision. *(judgement)*
9. **P3** `SKILL.md:86-89` — Suggested-skills list hardcodes names (`gcp-oauth`) that may not be installed. The text already says "what's actually installed", so this is minor. *(judgement)*

## Description test
Should trigger: "hand off this work to a fresh session" (yes); "write up where we are so Codex can continue" (yes); "I'm ending for the day, save state for tomorrow" (probably, via "parking work for later").
Should not trigger: "summarize this conversation for me" (borderline, "compact the conversation" overlaps; the "handoff" context separates it only weakly); "compact my context" (the `/compact` command overlaps with "Compact the current conversation"). Risk noted under finding 6.

## Evaluations
```json
[
  {
    "skills": ["handoff"],
    "query": "/handoff finish the review fixes on PR 25",
    "files": [],
    "expected_behavior": [
      "File is written under $TMPDIR/claude-handoffs/ (or /tmp/claude-handoffs/) with a colon-free timestamp and sanitized slug",
      "Frontmatter has created, source-cwd, source-branch, next-focus with the user's argument",
      "Sections appear in order 1-6 and the one-line summary reflects the review-fix focus",
      "Final message gives path, one-line confirmation and Resume command, and does not print the doc body"
    ]
  },
  {
    "skills": ["handoff"],
    "query": "/handoff ../../etc/cron.d/my PR: fix 'auth' (token ghp_abc123 used in curl)",
    "files": [],
    "expected_behavior": [
      "Slug contains only alphanumerics and hyphens; no '/', '.', or whitespace; file stays inside claude-handoffs/",
      "The ghp_ token does not appear in the saved file; it is replaced with <redacted> or '<redacted: contact user for value>'"
    ]
  },
  {
    "skills": ["handoff"],
    "query": "/handoff",
    "files": [],
    "expected_behavior": [
      "next-focus is '(unspecified)' and the doc is a general handoff of in-flight work",
      "A background job started earlier in the session is listed with task ID, what it waits for, and output location",
      "Done/In flight/Blocked: empty buckets omitted; each in-flight item has a concrete next action",
      "No TL;DR section and no replayed conversation history"
    ]
  }
]
```
Not run (design only, no baseline runs).

## Not assessed
Actual behaviour on any model (evaluations not run). Haiku fit: the six-section template is explicit enough; Opus: modestly over-explained (finding 5, "Keep it scannable"), judgement only.

## Changes made
1. fixed - removed the "last line of your response" clause; "After saving" now alone defines output order.
2. fixed - filename now specifies a colon-free UTC timestamp such as `2026-05-21T14-30Z`.
3. fixed - removed the "collision-free" claim.
4. fixed - line 19 shortened to point at the output location.
5. fixed - removed the duplicate "Do NOT duplicate" paragraph from section 4, shortened the quote sentence.
6. left for owner - changing the description alters triggering (taste).
7. left for owner - trivial terminology choice; pick one term and sweep.
8. left for owner - changing storage location or persistence is a behaviour change.
9. left for owner - choosing which skills to name is a taste call.
