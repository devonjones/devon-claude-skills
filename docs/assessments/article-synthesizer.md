# Skill assessment: article-synthesizer

## Verdict
Ship with fixes — the procedure is clear and well-guarded against fabrication, but the original carried duplicated sections, roadmap prose, and an undefined `<work_dir>` placeholder.

## Mechanical checks
Measured on the original file.

| Check | Result | Value |
|---|---|---|
| name | pass | `article-synthesizer`, 19 chars, `[a-z0-9-]` only |
| description | pass | 443 chars (`sed -n 3p ... \| wc -c`) |
| SKILL.md body | pass | 320 lines (`wc -l`) |
| reference depth | pass | no reference files; single SKILL.md (`find`) |
| TOC on long refs | pass | n/a, no references |
| paths | pass | `grep -c '\\' SKILL.md` = 0 |

Inventory: one file, SKILL.md. No scripts, no tests, no evaluations. The plugin has no `.claude-plugin/plugin.json` (sibling `youtube-synthesizer` has one); `marketplace.json` still lists it.

## Findings

1. **P2** `SKILL.md:3` — description opens in imperative ("Turn..."), not third person; it spends its length on "sibling of youtube-synthesizer... no frame pipeline" (not trigger terms) and lacks a near-miss exclusion and verbs users type (save, clip). Rewrite in third person with triggers and exclusions. *(judgement)*
2. **P2** `SKILL.md:311-320` — "Failure modes" restates Phase A.3 almost verbatim, plus the D.2 refusal (10 lines duplicated). Delete the section. *(measured: compare lines 59-65 with 313-320)*
3. **P2** `SKILL.md:8,10,33,84,103,164,171,270` — roadmap and rationale prose that a reader needs nothing from to act: "future sqlite3 indexer", "future cross-source linker", "power the future FTS index", channel-grouping analogy, "highest-leverage section", long D.5 history. Cut to the actionable rule. *(judgement)*
4. **P2** `SKILL.md:29-35` vs `D.4:262` — the `<sanitized-title>` / date-prefix rule and the "images linked, not downloaded" rule are stated in Output and again in D.3/D.4. Keep one statement each. *(measured: grep "date prefix", "remote")*
5. **P2** `SKILL.md:293-301` — Discipline section restates C.1 "Avoid" list and the Phase C intro in 9 lines of loosely worded prose. Compress. *(judgement)*
6. **P2** `SKILL.md:52` — `<work_dir>` is never defined, so Claude must invent a path. Use a concrete path. *(measured: `grep -n work_dir` finds one use, no definition)*
7. **P3** `SKILL.md:281,284` — `DRAIN-DONE` path is "relative to `~/ObsidianVaults`", which is undefined when `<vault>` is an absolute path outside that directory. Product decision. *(judgement)*
8. **P3** `SKILL.md:200` — domain sanitization maps dots to spaces, then strips non `[a-z0-9 ]`, so a hyphenated host (`my-site.com`) becomes `mysite-com`. May be intended; changing it changes output paths. *(judgement)*
9. **P3** `plugins/article-synthesizer/` — no `.claude-plugin/plugin.json`, and the `marketplace.json` description duplicates the old skill description. Outside the allowed edit scope. *(measured: `find`)*
10. **P3** `SKILL.md:23` — `--no-sync` is a documented flag that does nothing. Keep or drop is the owner's call. *(judgement)*
11. **P3** `SKILL.md` terminology — "entry", "entry directory", "note", "literature note" and "file" all denote the same artifact; "agent" and "you" both address Claude. Minor. *(judgement)*

## Description test
Should trigger: "save this blog post to my Obsidian vault" (yes, "ingest/save/clip ... blog post"); "ingest https://martinfowler.com/... into Programming vault" (yes); "clip this docs page as a literature note" (yes).
Should not trigger: "summarize this YouTube video into my vault" (no, routed to youtube-synthesizer by the exclusion); "extract text from this PDF" (no, PDFs excluded).
The original description would also have separated these, but only via the sibling-name aside.

## Evaluations
Not run (per instructions). Proposed:

```json
[
  {
    "skills": ["article-synthesizer"],
    "query": "Ingest https://example.com/members-only-post into the Programming vault",
    "files": [],
    "expected_behavior": [
      "Reports the page is paywalled or login-walled and stops",
      "Writes no .md file and creates no entry directory",
      "No invented TL;DR or takeaways appear in the output"
    ]
  },
  {
    "skills": ["article-synthesizer"],
    "query": "Ingest https://www.martinfowler.com/articles/example.html into ~/ObsidianVaults/Programming, no questions (headless). The entry already exists, no --rerun.",
    "files": ["~/ObsidianVaults/Programming/sources/articles/martinfowler-com/<today>-example/example.md"],
    "expected_behavior": [
      "Does not fetch the page or modify the existing file",
      "Final line is DRAIN-DONE: Programming/sources/articles/martinfowler-com/<today>-example/example.md",
      "Asks no interactive questions"
    ]
  },
  {
    "skills": ["article-synthesizer"],
    "query": "Ingest a technical article with code blocks and a title like \"That's Not My Job: Parsing & Validating\" into ~/ObsidianVaults/Programming --why \"parser study\"",
    "files": [],
    "expected_behavior": [
      "Directory is <today>-thats-not-my-job-parsing-validating under the sanitized domain",
      "Code blocks are verbatim with language tags",
      "Frontmatter parses as YAML, why_ingested is \"parser study\", tags are kebab-case (3-8) and topics 1-4",
      "References are real linked URLs with one-line annotations, none invented"
    ]
  }
]
```

## Not assessed
Evaluations and baseline runs (not run by design). Behaviour on Haiku/Opus not tested.

## Changes made
1. fixed - description rewritten in third person with triggers (ingest, save, clip) and exclusions; 443 -> 323 chars.
2. fixed - "Failure modes" section deleted (A.3 and D.2 carry it).
3. fixed - roadmap/rationale cut in the intro, B, C.1, C.4, C.5, D.5.
4. fixed - removed the repeated date-prefix sentence in Output and the long image scope sentence.
5. fixed - Discipline section compressed from 9 to 5 lines, same rules.
6. fixed - `<work_dir>/page.html` replaced with `/tmp/page.html`.
7. left for owner - product decision on the relative-path contract with the drain worker.
8. left for owner - changing sanitization changes output paths.
9. left for owner - outside the allowed edit scope (plugin.json absent; marketplace.json untouched).
10. left for owner - keep or remove the no-op flag.
11. left for owner - cosmetic; renaming terms across the file risks changing meaning without owner taste.

Result: SKILL.md 320 -> 303 lines (19532 -> 16557 bytes). No scripts or tests exist, so no `bash -n` or test run applied.
