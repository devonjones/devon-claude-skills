# Skill assessment: rodney

## Verdict
Ship — a tight single-file skill whose rules target the CLI's real failure modes; only polish findings.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `rodney`, 6 chars, `[a-z0-9-]`, no reserved words |
| description | pass | 539 chars (frontmatter lines 4-10 joined, `wc -c`), no XML tags |
| SKILL.md body | pass | 106 lines (`wc -l`) |
| reference depth | pass | no reference files; one external link (github.com/simonw/rodney) |
| TOC on long refs | pass | n/a, no files >100 lines besides SKILL.md itself (106 lines, short enough to scan) |
| paths | pass | `grep -c '\\' SKILL.md` = 0 |
| unlinked files | pass | directory holds only SKILL.md |

## Findings

1. **P3** `SKILL.md:101` — Names the owner ("have Devon pass the check"); in a shared skill the reader is "the user". Fixed. *(judgement)*
2. **P3** `SKILL.md:21-22` — The `rodney --version` prints `dev` / `go version -m` aside is trivia not needed to act, unless a version check is expected. Candidate to delete. *(judgement)*
3. **P3** `SKILL.md:50` — "Chrome's memory keeps growing" is rationale; the instruction ("always finish with `rodney stop`") stands alone. Minor. *(judgement)*
4. **P3** `SKILL.md:88-89` — Warm-up step in the example writes a file then opens it; rule 4 already says to do this. Acceptable as a complete runnable example; no change. *(judgement)*
5. **P3** `SKILL.md:3-10` — Description is imperative/neutral rather than strictly third person, but it states what and when with concrete triggers and names the neighbouring skills to defer to. Passes in substance. *(judgement)*

## Description test
Should trigger: "scrape the prices from this JS-rendered page", "screenshot my dev server's login page", "click through this form and tell me what the dashboard shows" — yes, each matches a listed use.
Should not trigger: "fetch this JSON API with curl", "write a Playwright test that stubs network requests" — yes, the description routes these to curl and playwright-skill. Residual risk: overlap with playwright-skill on generic "test this website" requests.

## Evaluations
```json
[
  {
    "skills": ["rodney"],
    "query": "Log into http://localhost:3000/login with test@example.com and screenshot the dashboard.",
    "files": [],
    "expected_behavior": [
      "Every rodney call is prefixed with a non-default RODNEY_HOME and wrapped in timeout",
      "Runs rodney status before start and a local-file open before the first real URL",
      "Waits (waitstable/wait) before screenshotting, then Reads the PNG",
      "Ends with rodney stop"
    ]
  },
  {
    "skills": ["rodney"],
    "query": "rodney status hangs and the next command times out with exit 124. Recover and carry on.",
    "files": [],
    "expected_behavior": [
      "Kills Chrome with pkill -f using the bracketed pattern on the session chrome-data path",
      "Does not use the default ~/.rodney session",
      "Restarts with start, then repeats the warm-up open"
    ]
  },
  {
    "skills": ["rodney"],
    "query": "Extract all product names from https://example.com/shop (rendered by JS); it may show a bot check.",
    "files": [],
    "expected_behavior": [
      "Checks title after open and reports a bot wall rather than scraping its content",
      "Uses rodney js and tests for null on a miss",
      "Does not pipe rodney into head/tail when relying on exit code"
    ]
  }
]
```

## Not assessed
Evaluations were designed, not run (no baseline runs). Whether `RODNEY_HOME` overrides a `./.rodney/state.json` auto-detected local session was not tested (`rodney --help` documents auto-detection).

## Changes made
1. fixed - replaced "Devon" with "the user" in SKILL.md.
2. left for owner - deleting the version aside is a taste call about whether the version hint is wanted.
3. left for owner - trimming the memory rationale is marginal; keeps the reason for the stop rule.
4. left for owner - none needed; no change (example kept deliberately complete).
5. left for owner - none needed; no change (passes in substance).
