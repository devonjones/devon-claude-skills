---
name: youtube-synthesizer
description: Turn a YouTube video into a faithful-capture literature note in an Obsidian vault. Use when the user wants to ingest a video (explainer, howto, lecture) into their personal source notes corpus. Combines transcript + canonical visual scenes + structured extraction.
---

# YouTube Synthesizer

Orchestrates `youtube-transcript` and `youtube-screenshotter` to produce an Obsidian literature note for a video. Drives the bisection + visual-diff judgment loop using your own native vision capability — no separate API calls, no extra billing.

You — the agent running this skill — do the visual judgment inline as you follow the procedure below. The skill produces faithful capture of the source; downstream synthesis into the user's mental model is their job, not yours.

---

## Phase A — Sampling: bisection + visual-diff judgment

This phase produces a list of `(timestamp, frame_path, transcript_span, verdict)` triples that downstream phases consume to build the wiki entry. It is the smart core of the skill.

### A.1. Fetch transcript and metadata

- `<youtube-transcript scripts dir>/get_transcript.py "<URL>"` → transcript with timestamps
- `<youtube-screenshotter scripts dir>/video.py "<URL>" --no-download` → metadata (channel_id, chapter_markers, etc.)

If the video has no transcript, error with a clear message and stop. **Do not fabricate one.**

### A.2. Decide initial sample timestamps

Build a sorted unique list from:

- Each transcript snippet boundary
- Each chapter marker start (from metadata)
- The video start (`t = 0.5`)
- Any silence gap > 10 seconds between consecutive snippets — anchor a sample at the gap midpoint

### A.3. Extract initial frames

```
<youtube-screenshotter scripts dir>/extract.py "<URL>" -t <ts1> -t <ts2> ... -o <work_dir>
```

Returns a manifest with `(timestamp, frame_path, phash)` per requested timestamp. The video downloads once to `<work_dir>/<video_id>.mp4`; subsequent calls hit the cache.

### A.4. Classify consecutive pairs

For each consecutive pair `(A, B)` in the manifest, compute the Hamming distance between their pHashes (you can do this in your head from the hex strings, or use `<youtube-screenshotter scripts dir>/phash.py compare`).

| Hamming distance | Verdict | Action |
|---|---|---|
| ≤ 5 | `same` | No further work |
| ≥ 20 | `different` | No further work |
| 6–19 | ambiguous → needs visual judgment | See below |

For ambiguous pairs, do the visual judgment yourself:

1. Read both frame images (use the Read tool on `frame_path`)
2. Read the transcript text spoken between `A.timestamp` and `B.timestamp`
3. Decide the verdict — exactly one of:
   - **`same`** — no meaningful change. The frames may differ in talking-head pose, camera shake, or compression noise, but slides/diagrams/charts/code are unchanged.
   - **`different`** — meaningful new visual element. New slide, scene cut, new chart, B-roll cut.
   - **`additive`** — frame B contains everything in A plus more. Slide animating in further bullets, code being typed line-by-line, equation revealed step-by-step, highlight/arrow/label added on top of unchanged content.

**Bias toward false positives.** When uncertain between `same` and `different`/`additive`, pick the latter. Wasting a frame downstream is cheap; missing a real visual change is expensive.

**Use transcript context.** Match expected change against observed change:
- "As you can see in this new diagram" / "let me show you" → expect `different`
- "And now we add" / "next we get" → expect `additive`
- Continuing to discuss the same visible content → expect `same`
- Silent windows often correlate with `different` or `additive` — presenter pausing while showing something visual

Process ambiguous pairs in batches per turn (typically 10–20 pairs per batch) rather than one at a time. Use a single Read sequence to load each batch's frames, then classify them all in your reasoning before emitting the next batch's reads.

### A.5. Bisect interesting windows

For each pair `(A, B)` whose verdict is `different` or `additive`:

- If `B.timestamp - A.timestamp > 1` second, schedule an additional timestamp at the midpoint
- Re-call `extract.py` with the new timestamps (cached frames are free; only fresh ones cost ffmpeg time)
- Re-classify the new pairs `(A, M)` and `(M, B)`

For `additive` runs specifically, keep bisecting **forward** in time until the next pair lands on `same` (build-up settled — terminal frame found) or `different` (new scene). The terminal frame of the additive run is the canonical capture for that scene; intermediate build-up frames are discarded.

### A.6. Terminal conditions

Stop bisecting a window when any of:

- Window < 1 second
- Endpoints judged `same`
- A forward-bisecting `additive` run hits `same` or `different`

### A.7. Emit the final tuple list

Output a sorted list of `(timestamp, frame_path, transcript_span, verdict)` triples covering the full video. This is the input to Phase B (scene consolidation), Phase C (structured extraction), and Phase D (output writing) — added in subsequent SKILL.md sections as those phases land.

---

## Discipline: faithful capture, no editorializing

The skill's job is to deliver "here is what this video said and showed, structured and searchable" — not to weave the content into the user's mental model. That weaving is downstream, in the vault root where the user (and you, in other tasks) builds permanent notes on top of these literature notes.

Concretely: do not reframe content for any particular use case (worldbuilding, debugging, learning), do not add interpretive headers, do not editorialize the presenter's claims. Capture what was said and shown. The user reads the entry to remember what the video communicated, then synthesizes elsewhere.

---

## Prerequisites

- `youtube-transcript` skill installed
- `youtube-screenshotter` skill installed (transitively requires `uv` and `ffmpeg`)
- Network access to YouTube
- A target Obsidian vault path (writable) — used by Phase D

## Failure modes

- **No transcript available** (no captions, foreign language) → error early with a clear message; stop
- **Video unavailable** (private, members-only, age-restricted, geo-blocked) → error early; stop
- **Live streams** → refuse for now (no fixed endpoint to bisect over)
- **Very short videos** (≤ 3 minutes) → skip Phase A bisection refinement; transcript-aligned sampling alone is sufficient

---

*This SKILL.md currently covers Phase A (sampling). Phase B (scene consolidation + frontmatter), Phase C (structured extraction), and Phase D (output writing) are added in subsequent revisions.*
