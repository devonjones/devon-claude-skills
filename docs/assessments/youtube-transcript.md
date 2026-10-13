# Skill assessment: youtube-transcript

## Verdict
Ship with fixes — small and well-scoped, but SKILL.md made two false claims about the script (language fallback, "timedtext endpoint").

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass | `youtube-transcript` (18 chars, `[a-z0-9-]`, no reserved words) |
| description | pass | 250 chars (`sed -n 3p SKILL.md`), no XML tags |
| SKILL.md body | pass | 54 lines (`wc -l`) |
| reference depth | pass | no reference files; only `scripts/get_transcript.py` |
| TOC on long refs | pass | n/a, no references >100 lines |
| paths | pass | `grep -c '\\' SKILL.md` = 0 |
| unlinked files | pass | script is named in SKILL.md; no other files |

## Findings

1. **P1** `SKILL.md:19` — "falls back to default if unavailable" is false. `get_transcript.py:97` calls `fetch(video_id, languages=[lang])`, which raises when that language is missing; `main` prints the error and exits 1 (lines 123-125). Claude would tell the user a fallback transcript was returned. Say it errors. *(measured: read of code; judgement on library behaviour, not run)*
2. **P2** `SKILL.md:54` — "calls the public timedtext endpoint directly" is wrong; the script calls `YouTubeTranscriptApi`. Misleads network debugging. Reword. *(measured: no timedtext reference in script)*
3. **P2** `SKILL.md:49` — says the error occurs only when there are no captions at all; the `--lang` miss (finding 1) also errors. Cover it. *(judgement)*
4. **P3** `SKILL.md:8` — the script path is never tied to the library sentence; the Usage block uses bare `scripts/get_transcript.py`. Name the script up front. *(judgement)*
5. **P3** `SKILL.md:28-34` — URL list omits `youtube.com/v/ID`, which the regex accepts (`get_transcript.py:75`). *(measured)*
6. **P3** `SKILL.md:26` — "either print to stdout or save as `<VIDEO_ID>-transcript.txt`" offers two defaults with no rule for choosing. Needs the owner to pick a default. *(judgement)*
7. **P3** `SKILL.md:36-39` — `-t` short flag and `-o -` (stdout) exist in the script but are undocumented; harmless. *(measured)*
8. **P3** `scripts/get_transcript.py:123` — blanket `except Exception` prints only the message, no hint (e.g. which video ID, whether language or captions failed). Acceptable; changing it alters behaviour. *(judgement)*

Name is not a gerund, but it matches sibling skills (`youtube-synthesizer`, `youtube-screenshotter`); fine. Dependencies and `uv` install line are present. Freedom level is right: low-freedom script, with a clear rule on not altering transcripts. Model fit: Haiku has enough guidance; nothing over-explained for Opus.

## Description test
Should trigger: "get the transcript of https://youtu.be/dQw4w9WgXcQ"; "subtitles for this video ID abc123XYZ_-"; "save captions from this YouTube link to a file" — yes, all hit transcript/subtitles/captions plus URL/ID.
Should not trigger: "summarize this YouTube video into my Obsidian vault" (belongs to youtube-synthesizer; "transcript" not requested, but overlap risk is moderate); "grab a frame at 2:30 from this video" — no.

## Evaluations
```json
[
  {
    "skills": ["youtube-transcript"],
    "query": "Get the German transcript of https://www.youtube.com/watch?v=<id of a video with only English captions>",
    "files": [],
    "expected_behavior": [
      "Runs scripts/get_transcript.py with --lang de",
      "Reports the script's error to the user",
      "Does not claim a fallback-language transcript was produced and does not fabricate text"
    ]
  },
  {
    "skills": ["youtube-transcript"],
    "query": "Transcript with timestamps for https://youtube.com/shorts/<11-char id>, tidy it into paragraphs",
    "files": [],
    "expected_behavior": [
      "Runs the script with --timestamps",
      "Keeps one [MM:SS] segment per line, no reflow",
      "Words are unchanged from the script output"
    ]
  },
  {
    "skills": ["youtube-transcript"],
    "query": "Save the transcript of dQw4w9WgXcQ to a file",
    "files": [],
    "expected_behavior": [
      "Uses -o with a file named dQw4w9WgXcQ-transcript.txt",
      "Reports the path written"
    ]
  }
]
```
Not run (per instructions).

## Not assessed
Script was not run (no network, no baseline runs); findings 1-2 rest on reading the code and the library's documented API.

## Changes made
1. fixed - SKILL.md Usage comment now reads "errors if no transcript in that language".
2. fixed - replaced "public timedtext endpoint" with "the library fetches captions from YouTube".
3. fixed - When Captions Aren't Available now says exit 1 with a message, including for the requested `--lang`.
4. fixed - intro names `scripts/get_transcript.py` and drops the redundant phrasing.
5. fixed - added `youtube.com/v/VIDEO_ID` to the URL list.
6. left for owner - choosing stdout vs file default is a behaviour/taste decision.
7. left for owner - documenting `-t` / `-o -` is optional polish; skipped to keep the skill short.
8. left for owner - changing error handling alters script behaviour.
