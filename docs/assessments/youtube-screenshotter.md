# Skill assessment: youtube-screenshotter

## Verdict
Ship with fixes — functional and well scoped, but SKILL.md misdescribed run-grouping, omitted a manifest field and the motion.py output, and carried duplicated or historical prose.

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `youtube-screenshotter`, 21 chars, `[a-z0-9-]`, no reserved words |
| description | pass | 704 chars (`wc -c` on the value, before fix); under 1,024, no XML tags |
| SKILL.md body | pass | 116 lines (`wc -l`) |
| reference depth | pass | no reference files; SKILL.md links none |
| TOC on long refs | pass | n/a, no reference files (SKILL.md is 116 lines) |
| paths | pass | `grep -n '\\' SKILL.md` returned nothing |
| unlinked files | pass | only `scripts/*.py`, all named in SKILL.md; all 6 pass `python -m py_compile` |

Inventory: SKILL.md; scripts/discover.py (324 lines), extract.py (103), frames.py (102), motion.py (501), phash.py (87), video.py (155). No tests or shipped evaluations.

## Findings
1. **P2** `SKILL.md:57` — says run-grouping merges consecutive thumbnails with Hamming distance <= threshold; `discover.py:group_runs` compares each thumbnail to the run's first thumbnail (drift-bounded), which behaves differently. Reword. *(measured: read group_runs, discover.py:140-168)*
2. **P2** `SKILL.md:28-44` — manifest shape omits `metadata.description`, which `video.py` emits (`VideoMetadata.description`). Add the field. *(measured: video.py:39, SKILL.md grep)*
3. **P2** `SKILL.md:63-70` — motion.py output is undocumented, unlike the other two manifests; also not stated that it needs a local file, not a URL. Add one line listing the keys. *(measured: motion.py:242-254, 473-478)*
4. **P2** `SKILL.md:14-19,66` — script paths are relative with no statement of what they are relative to; invoked from another cwd (a downstream skill) they fail. State "relative to this skill's directory". *(judgement)*
5. **P3** `SKILL.md:3,63` — one concept, three names: "sprite strip" (description), "Brady-Bunch grid", "sprite" (body); the code composites a grid (`compose_sprite_grid`). Use "sprite grid". *(measured: grep)*
6. **P3** `SKILL.md:8-10,63,70,101` — prose repeats itself and carries motivation and cross-skill detail (duplicate of the description; "Brady-Bunch ... take in at a glance"; Phase A.5 asides; "additive" band that no script emits). Shorten. *(judgement)*
7. **P3** `SKILL.md:105` — "Same as `youtube-transcript`" makes the reader follow another skill for a list that is then given anyway. Drop the reference. *(judgement)*
8. **P3** `SKILL.md:3` — description is 704 chars and packs four capabilities into one run-on; trigger terms are present but the "when" is thin for a user typing "grab a screenshot at 5:30 of this video". Left (see owner items). *(judgement)*
9. **P3** `scripts/motion.py:~456` — stale comment says "horizontal strip" while the code builds a grid. Comment only. *(measured: motion.py:456 vs compose_sprite_grid)*
10. **P3** `SKILL.md:112-116` — Prerequisites do not mention that `ffprobe` (bundled with ffmpeg) is used by discover.py for local files, nor that motion.py pulls opencv via the uv header (automatic). Neither blocks use. No change. *(judgement)*

## Description test
Should trigger: "grab frames at 1:30 and 8:20 from this YouTube video" — yes ("extract frames at specified timestamps"); "find where the slides change in this lecture video" — yes ("discovers candidate timestamps"); "show the motion arc of the animation between 2:10 and 2:25" — yes ("optical flow ... sprite").
Should not trigger: "get the transcript of this video" — no (transcript skill; description says frames/PNG); "summarize this video into my Obsidian vault" — likely no, though "youtube-synthesizer" is named in the description and could cause co-loading (harmless, it is the downstream caller).

## Evaluations
```json
[
  {
    "skills": ["youtube-screenshotter"],
    "query": "Get me screenshots at 0:10, 1:00 and 2:30 of https://youtu.be/dQw4w9WgXcQ and give me the perceptual hashes.",
    "files": [],
    "expected_behavior": [
      "Runs scripts/extract.py with -t 10 -t 60 -t 150 (seconds, not mm:ss) and a -o directory",
      "Output contains a manifest with three entries, each with timestamp, frame_path and a 16-hex-char phash",
      "Does not call discover.py or motion.py"
    ]
  },
  {
    "skills": ["youtube-screenshotter"],
    "query": "I have a downloaded lecture at ./lecture.mp4. Find the timestamps where the slide changes, but only stretches lasting at least 5 seconds.",
    "files": ["lecture.mp4"],
    "expected_behavior": [
      "Runs scripts/discover.py with ./lecture.mp4 as the target (no download) and --min-run 5",
      "Reports timestamps from the candidates list, not only scene_detect",
      "Does not run extract.py, which needs a URL"
    ]
  },
  {
    "skills": ["youtube-screenshotter"],
    "query": "Between 130s and 150s of ./demo.mp4 a small icon slides across a static slide. Make me one image showing the whole movement in 6 frames, 3 columns.",
    "files": ["demo.mp4"],
    "expected_behavior": [
      "Runs scripts/motion.py with --start 130 --end 150 --sprite-out <path> --sprite-frames 6 --sprite-cols 3",
      "Produces a PNG at the sprite path, manifest sprite_layout shows cols 3, rows 2, frames 6",
      "Does not use discover.py for this"
    ]
  }
]
```
Not run (instructed: no baseline runs, no downloads).

## Not assessed
- Script runtime behaviour (no video downloads, no evaluation runs); only syntax-checked with `python -m py_compile`.
- Haiku/Sonnet/Opus model fit: not measured. Judgement: the usage block is short and exact, so Haiku should cope; the main risk is the relative-path issue (finding 4).
- Fetching the Anthropic best-practices page (optional).

## Changes made
1. (P2 run-grouping wording) fixed - SKILL.md now says distance to the run's first thumbnail.
2. (P2 description field) fixed - added `"description": "..."` to the manifest shape.
3. (P2 motion output) fixed - one sentence names the motion.py local-file requirement and manifest keys.
4. (P2 relative paths) fixed - one line: "Script paths below are relative to this skill's directory."
5. (P3 sprite naming) fixed - description now says "sprite grid"; body uses "grid".
6. (P3 prose) fixed - intro, motion paragraph and pHash tail shortened; "additive" aside removed.
7. (P3 youtube-transcript reference) fixed - now "Accepted inputs:".
8. (P3 description length/trigger terms) left for owner - rewriting the description is a taste decision (what trigger phrases to target); only the "strip" to "grid" wording was changed.
9. (P3 stale comment in motion.py) left for owner - comment-only, but outside the SKILL.md prose; trivial edit, skipped to keep script files untouched.
10. (P3 prerequisites) left for owner - no failure observed; adding ffprobe note is optional.
