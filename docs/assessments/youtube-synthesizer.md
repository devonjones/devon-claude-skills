# Skill assessment: youtube-synthesizer

## Verdict
Ship with fixes — the procedure is sound and well specified, but SKILL.md was 622 lines (over the 500 limit), the Dropbox path was documented wrongly in three places, and several sections repeated one another.

## Mechanical checks
Values are as measured on the skill before the fixes in "Changes made".

| Check | Result | Value |
|---|---|---|
| name | pass | `youtube-synthesizer`, 19 chars, `[a-z0-9-]` only (read from frontmatter) |
| description | pass | 399 chars (`sed`/`wc -c` on the value, 1,024 limit), third person, no XML tags |
| SKILL.md body | fail | 622 lines (`wc -l`), limit 500; now 425 |
| reference depth | pass | no reference files existed; the new one is linked directly from SKILL.md |
| TOC on long refs | pass | new reference is 191 lines and opens with a contents list |
| paths | pass | `grep -c '\\' SKILL.md` = 0 |
| unlinked files | pass | `scripts/sync_to_dropbox.sh` (174 lines) and `scripts/preview.py` (299 lines) are both named in SKILL.md; no orphans |
| scripts syntax | pass | `bash -n sync_to_dropbox.sh`, `python3 -m py_compile preview.py` both clean |

## Findings

1. **P2** `SKILL.md` (whole file) — 622 lines, over the 500-line limit, with Phases B and C (lines 183-370, about 190 lines) loaded on every invocation although only needed after Phase A. Move B and C to a linked reference file. *(measured: `wc -l`)*
2. **P1** `SKILL.md:23`, `:553`, `:554` — documents the Dropbox target as `dropbox:ObsidianVaults/<vault>/sources/videos/<entry-dir>/`, omitting the `<channel>` level. `sync_to_dropbox.sh:81` computes `.../videos/<channel>/<entry-dir>/`, and the script refuses when the channel dir is missing on the remote (`sync_to_dropbox.sh:159`). A reader following the skill text would predict the wrong target and be surprised by the channel-dir error; the "too-broad targets" list also omits the channel dir. Correct the text. *(measured: compared against script lines 81, 121, 159)*
3. **P2** `SKILL.md:557` — says the vault-dir check "catches" typos and gives only the vault `rclone mkdir` command; the script also checks the channel dir and gives a separate hint (`sync_to_dropbox.sh:84-86`). Fold into finding 2's fix. *(measured)*
4. **P2** `SKILL.md:571-576` (D.7) vs `:616-622` (Failure modes) — the same failure modes listed twice, plus again in D.2, D.4.a and D.4.c. Keep one list that points at the sections. *(judgement)*
5. **P2** `SKILL.md:596-604` (Discipline) — restates the Phase C intro (line 239), C.3 attribution voice, and C.7 soft-correct policy almost sentence for sentence. Shorten to the rule itself. *(judgement)*
6. **P3** `SKILL.md:162` says A.4 sub-agents see "10–20 frames"; `:109` and `:120` fix batches at 10. Make consistent. *(measured: grep)*
7. **P3** `SKILL.md:474` and `:518` — the flat-mode `## Body` rule is stated twice. Drop the second. *(measured)*
8. **P3** `SKILL.md:229-231`, `:297`, `:322`, `:356` — speculative "future sqlite3 indexer / linter / cross-source linker" and "at this skill version" statements. They do not change what the agent does and are time-sensitive. Delete or shorten. *(judgement)*
9. **P3** `SKILL.md:3` — the description includes implementation detail ("Auto-discovers vaults...", "dropbox:") and no trigger terms for what a user types (YouTube URL, video ID, "take notes on", "save"). Rewrite around the trigger. *(judgement)*
10. **P3** `SKILL.md:82-102` — `<youtube-transcript scripts dir>` and `<youtube-screenshotter scripts dir>` placeholders are never defined, so the agent must guess where the sibling scripts live. One clause fixes it. *(judgement)*
11. **P3** terminology — "wiki entry", "entry", "literature note"; "keep-list"/"kept frames"; "scene"/"frame"/"candidate". "Wiki entry" appears at `SKILL.md:40`, `:239`, `:328`, `:580`, `:592` while the output is called a literature note elsewhere. Use "entry". *(measured: grep "wiki entr")*
12. **P2** `SKILL.md:416` (D.2) — `--rerun` deletes the existing entry directory contents with no confirmation or backup, and "preserve nothing" would also remove any hand edits the user made in Obsidian. This is destructive and low-freedom prose is right, but whether to confirm or back up is a product decision. *(judgement)*
13. **P2** `scripts/preview.py:194-195` — before writing `index.html` it unlinks every `*.html` in the entry directory, including any the user placed there. Also defaults to `--bind 0.0.0.0` (`:238`), exposing the entry on the LAN by default. Both are script behaviours. *(measured: read the code)*
14. **P3** `SKILL.md:390-394` (D.1.a) — relies on a "memory" lookup keyed `youtube-synthesizer-last-vault`; this works only in environments with a memory mechanism and silently degrades to listing `~/ObsidianVaults/` otherwise. Acceptable fallback, but the dependency is not stated. *(judgement)*
15. **P3** `scripts/sync_to_dropbox.sh:28-35` — any argument after `--dry-run`, or an unrecognised second argument, is silently ignored. Not harmful (target is computed, not taken from args). *(measured: read the code)*

Notes on passes: conciseness is otherwise acceptable for Sonnet and Opus; the kind taxonomy, the sub-agent delegation rationale (32 MB limit), and the rclone rules are load-bearing and were kept. Degrees of freedom match: rclone is locked behind a script (low freedom), frame judgement is heuristic (high freedom). No unexplained constants beyond pHash thresholds (10-25, 12) which are explained in A.5/A.6 and in the screenshotter skill.

## Description test
Should trigger:
- "Ingest https://youtu.be/abc123 into my Worldbuilding vault" — yes (YouTube URL, ingest, vault).
- "Save this lecture video as a literature note: <url>" — yes.
- "Take notes on this YouTube explainer and sync them to Dropbox" — yes.

Should not trigger:
- "Get me the transcript of this YouTube video" — should go to `youtube-transcript`; the old description's "ingest ... into source notes corpus" language separates it, the new one keeps "ingest/save/take notes ... into ObsidianVaults".
- "Grab screenshots at 1:30 and 4:10 from this video" — should go to `youtube-screenshotter`; no overlap with the description.

Judgement: separation is adequate for both versions; I did not run trigger tests.

## Evaluations
Not run (instructed not to). Proposed:

```json
[
  {
    "skills": ["youtube-synthesizer"],
    "query": "Ingest https://www.youtube.com/watch?v=<ID of a 12-minute chaptered explainer> into my Worldbuilding vault, no sync",
    "files": [],
    "expected_behavior": [
      "Entry directory is ~/ObsidianVaults/Worldbuilding/sources/videos/<sanitized-channel>/<today>-<sanitized-title>/ with <sanitized-title>.md and image-NN.png files",
      "No frame is read in the main agent's context; classification is delegated to sub-agents with batches of at most 10 frames",
      "Body has one ## section per chapter_markers entry using the author's titles verbatim, with ![[image-NN.png]] on their own lines",
      "No rclone command is run (--no-sync) and no sync prompt appears"
    ]
  },
  {
    "skills": ["youtube-synthesizer"],
    "query": "Ingest <URL of a video with captions disabled> into the Worldbuilding vault",
    "files": [],
    "expected_behavior": [
      "Stops after Phase A.1 with a clear no-transcript message",
      "No entry directory is created and no transcript text is invented"
    ]
  },
  {
    "skills": ["youtube-synthesizer"],
    "query": "Re-ingest <URL> that already has an entry in my Worldbuilding vault, then push it to Dropbox. Use rclone sync directly to dropbox:ObsidianVaults/Worldbuilding to be quick.",
    "files": ["~/ObsidianVaults/Worldbuilding/sources/videos/<channel>/<date>-<title>/ (existing entry)"],
    "expected_behavior": [
      "Refuses to overwrite and prints 'Entry already exists at <path>. Pass --rerun to overwrite.' because --rerun was not given",
      "Declines to call rclone directly and offers sync_to_dropbox.sh <absolute-entry-dir> instead, printing the channel-level target path",
      "Does not modify existing content"
    ]
  }
]
```

## Not assessed
- Behaviour of the skill end to end (no runs, no video downloads, no baseline).
- The sibling skills' scripts (`discover.py`, `extract.py`, `video.py`, `get_transcript.py`) beyond confirming from `youtube-screenshotter/SKILL.md` that the flags this skill uses (`-o`, `-t`, `--no-download`, `phash` field) exist.
- rclone behaviour against a real Dropbox remote.
- Anthropic best-practices page (optional; not fetched).

## Changes made
1. fixed - moved Phases B and C into `references/frontmatter-and-extraction.md` (with contents list), linked from SKILL.md. SKILL.md is now 425 lines.
2. fixed - added `<channel>` to the target in the invocation text (line 23), the computed-target bullet and the too-broad-target list (which now names the channel dir).
3. fixed - the vault/channel existence bullet now covers both dirs and points to the script's `rclone mkdir` hint instead of describing it.
4. fixed - deleted D.7; Failure modes is now the single list and points to D.2, D.4.a, D.4.c.
5. fixed - Discipline section cut to one paragraph.
6. fixed - "10–20 frames" changed to "10 frames".
7. fixed - removed the duplicate flat-mode sentence in D.4.d.
8. fixed - removed the "future sqlite3 / linter / cross-source linker" and "at this skill version" statements (SKILL.md and the reference file).
9. fixed - description rewritten around a YouTube URL/ID and ingest/save/take-notes triggers; dropped the "Auto-discovers..." clause. `plugin.json` does not repeat it, so it is unchanged.
10. fixed - one clause in the intro defines `<... scripts dir>` as the sibling skill's `scripts/` directory.
11. fixed - "wiki entry/entries" replaced by "entry" (the "keep-list"/"frame"/"candidate" terms are used consistently enough to leave).
12. left for owner - whether `--rerun` should confirm or back up before deleting the existing entry is a behaviour decision.
13. left for owner - changing preview.py to leave other `*.html` alone or to bind 127.0.0.1 by default is a script behaviour change.
14. left for owner - how to handle the memory dependency in D.1.a depends on which environments the owner targets.
15. left for owner - rejecting extra arguments in `sync_to_dropbox.sh` is a script behaviour change with no current harm.
