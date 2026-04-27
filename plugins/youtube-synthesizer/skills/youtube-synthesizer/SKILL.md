---
name: youtube-synthesizer
description: Turn a YouTube video into a faithful-capture literature note in an Obsidian vault. Use when the user wants to ingest a video (explainer, howto, lecture) into their personal source notes corpus. Combines transcript + canonical visual scenes + structured extraction.
---

# YouTube Synthesizer

Orchestrates `youtube-transcript` and `youtube-screenshotter` to produce an Obsidian literature note for a video. Drives the bisection + visual-diff judgment loop using your own native vision capability — no separate API calls, no extra billing.

You — the agent running this skill — do the visual judgment inline as you follow the procedure below. The skill produces faithful capture of the source; downstream synthesis into the user's mental model is their job, not yours.

## Invocation

Required inputs from the user:

- **`<URL>`** — YouTube video URL or 11-character video ID
- **`<vault>`** — absolute path to the target Obsidian vault. The skill writes to `<vault>/sources/videos/<ingested-date>-<sanitized-title>/`.

Optional:

- **`--rerun`** — overwrite an existing entry at the target path. Without this flag, the skill refuses to overwrite (Phase D.2).
- **`--why <reason>`** — populate the `why_ingested` frontmatter field. If omitted, leave it as an empty string; the user can fill it in after.

If any required input is missing, ask the user before starting work — do not guess the vault path.

## Output

A single Obsidian literature note at `<vault>/sources/videos/<ingested-date>-<sanitized-title>/` containing:

- `index.md` — frontmatter + body (TL;DR, key takeaways, scenes with embedded frames, references, commands & code)
- `scene-NN.png` siblings — the canonical frame for each consolidated scene

The four-phase procedure that produces this output is below.

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

Output a sorted list of `(timestamp, frame_path, transcript_span, verdict)` triples covering the full video. This is the input to Phase B.

---

## Phase B — Scene consolidation + frontmatter

This phase walks the verdict list from Phase A, collapses runs of `same`/`additive` into discrete scenes, and assembles the YAML frontmatter from the screenshotter's metadata block.

### B.1. Walk the verdict list to form scenes

A scene is a maximal run of consecutive frames that the next-frame verdict joins. The boundary between scenes is a `different` verdict.

Algorithm:

1. Start a new scene at the first frame `F0`. Set `canonical = F0`.
2. For each pair `(F_i, F_{i+1})` in order:
   - If verdict is `same`: `F_{i+1}` is in the same scene; `canonical` does not change (or set to `F_{i+1}` — they're equivalent).
   - If verdict is `additive`: `F_{i+1}` is in the same scene; **set `canonical = F_{i+1}`** (the additive build-up brings more content; the later frame wins).
   - If verdict is `different`: close the current scene; start a new scene at `F_{i+1}` with `canonical = F_{i+1}`.
3. Close the final scene at end of list.

For each closed scene, record:

```
{
  "canonical_frame_path": "...",
  "start_time": <timestamp of first frame in run>,
  "end_time": <timestamp of last frame in run>,
  "transcript_text": <concatenation of transcript snippets in [start_time, end_time]>,
  "chapter_title": <chapter_markers entry whose [start_time, end_time] contains the scene midpoint, or null>
}
```

**Drop intermediate frames within additive runs.** Only the canonical (terminal-state) frame survives; the build-up frames are noise in the wiki.

### B.2. Generate frontmatter from metadata

Use the metadata block from the screenshotter manifest (it carries everything yt-dlp returned). The frontmatter has two parts:

**Base schema** (shared with future article/pdf/substack source-skills — keep field names and shapes identical so the future sqlite3 indexer joins on a single contract):

```yaml
source_type: youtube
source_url: <metadata.source_url>
source_title: <metadata.source_title>
source_author: <metadata.source_author>           # channel display name for YouTube
source_published_date: <metadata.source_published_date>   # YYYY-MM-DD
ingested_date: <today's date in YYYY-MM-DD>
tags: []         # populated by Phase C
topics: []       # populated by Phase C
why_ingested: "" # optional; prompted from the user at invocation time
```

**YouTube-specific extras** (alongside the base, not nested):

```yaml
video_id: <metadata.video_id>
channel: <metadata.channel>            # mirror of source_author for in-context clarity
channel_id: <metadata.channel_id>      # stable handle, survives channel renames
playlist_id: <metadata.playlist_id>    # null unless invoked via playlist URL
playlist_title: <metadata.playlist_title>
duration_seconds: <metadata.duration_seconds>
chapter_markers:                       # if present in metadata; otherwise omit
  - title: "..."
    start_time: 0.0
    end_time: 153.0
```

**Frontmatter discipline:** strict key-value, no nested prose. Narrative content goes in the body, never in frontmatter. The frontmatter is the contract for the future sqlite3 indexer; treat it as machine-parseable.

### B.3. Output of Phase B

You now hold:

- A list of consolidated scenes (each with canonical frame, transcript, time range, chapter)
- A frontmatter dictionary keyed for YAML emission

---

## Phase C — Structured extraction

This phase produces the body sections of the wiki entry. Source-faithful: extract what the video communicated, do not interpret or synthesize. Use only the transcript text and (for Commands & Code) what's visible in the canonical scene frames.

### C.1. TL;DR

1–2 sentences capturing the video's central claim or thesis. The highest-leverage section for re-discovery six months later — the user reads this to remember what the video was about.

Source: transcript only. Look for explicit thesis statements (often in the first 60s and the final 60s), the chapter titles (especially the first), and the title.

Avoid: editorializing ("an interesting take on..."), interpretation ("the video argues that... but..."), framing for any particular use case.

### C.2. Key takeaways

3–5 bullets, each a single sentence, capturing the points the video makes that the user will want to remember.

Source: transcript. A takeaway is a substantive claim the presenter makes — not a section header. "Three days is the maximum economic distance for hauling grain by ox" is a takeaway; "The presenter discusses grain hauling" is not.

Avoid: meta-statements about the video itself, restating the title, padding the list to hit a count (3 strong bullets beat 5 weak ones).

### C.3. References / Mentioned

A list of every external thing the video cites or points at: people, papers, books, tools, organizations, other videos, websites. Plain text only — **no auto-generated wikilinks in Phase 1.** A future cross-source linker will resolve names to wikilinks once the corpus has matching `sources/` entries; capturing the names cleanly now is what makes that linker possible later.

Format each entry as a short identifier + a one-line note about what it was cited for:

```
- Paul Sellers — referenced when discussing hand-cut dovetail technique
- "Bread and Circuses" (book) — cited as source for medieval grain-haul economics
- youtube.com/watch?v=... — linked in description as related video
```

Source: transcript primarily; pinned chapter descriptions and on-screen text from canonical frames if they show citations or URLs.

### C.4. Commands & Code

For howto / technical videos: every shell command, code block, or configuration the presenter demonstrates or types out, captured as code blocks with the language tag.

Source: canonical frames where code is visible (read the image, transcribe verbatim) plus transcript where the presenter narrates a command.

For non-technical videos (worldbuilding, history, design discussion), this section is omitted entirely — do not pad with pseudo-commands.

Format:

```python
# from scene 4 — main loop the presenter demonstrates
for x in range(10):
    process(x)
```

Each block gets a one-line lead-in noting the scene it came from, so the reader can locate the visual context.

### C.5. Tags + topics

Populate the frontmatter `tags` and `topics` fields with a controlled list extracted from the video's content.

- **`topics`** — broad subject categories (e.g. `worldbuilding`, `medieval-history`, `economics`, `joinery`, `python`). 1–4 entries. Helps the user filter the corpus along the major axes they think about. Match the user's existing vocabulary if you can see prior entries in the same vault.
- **`tags`** — finer-grained markers (e.g. `grain-supply`, `oxen`, `radius-of-effect`, `dovetails`, `unit-tests`). 3–8 entries. These power the future sqlite3 FTS index more than topics do.

Both lists must be kebab-case strings, no spaces, no special characters. Do not invent vague tags (`interesting`, `useful`); every entry should map to a concrete subject.

### C.6. Output of Phase C

You now hold, in addition to Phase B's outputs:

- A TL;DR string
- A key-takeaways bullet list
- A references / mentioned list (or empty)
- A commands-and-code block list (or empty)
- Populated `tags` and `topics` arrays for the frontmatter

These are consumed by Phase D (output writing).

---

## Phase D — Output writing

Assemble everything from Phases B and C into the Obsidian literature note and write it to the user's vault.

### D.1. Resolve the entry path

Given the user-supplied vault path `<vault>` and `metadata.source_title`:

1. Sanitize the title: lowercase, replace spaces with hyphens, strip anything that isn't `[a-z0-9-]`, collapse repeated hyphens, trim leading/trailing hyphens. Truncate at 80 characters.
2. Today's date in `YYYY-MM-DD` format (this is `ingested_date`).
3. Compose the entry directory: `<vault>/sources/videos/<ingested_date>-<sanitized_title>/`

Example: `~/Obsidian/worldbuilding/sources/videos/2026-04-27-the-ox-thats-breaking-your-fantasy-map/`

### D.2. Skip-or-overwrite check

If the entry directory already exists and the user did not pass `--rerun`:

- Print a clear message: *"Entry already exists at `<path>`. Pass --rerun to overwrite."*
- Stop. Do not modify existing content.

If `--rerun`, remove the existing directory's contents before writing (preserve nothing — full regeneration).

### D.3. Copy canonical frames

Create the entry directory. For each scene in order, copy its `canonical_frame_path` to `<entry_dir>/scene-NN.png`, where `NN` is a 2-digit zero-padded index starting at `01`. Use 3 digits if the scene count exceeds 99.

Track the mapping `scene_index → relative_filename` for use in the body.

### D.4. Decide structure: hierarchical vs flat

- **Flat** if any of:
  - `metadata.duration_seconds <= 180` (≤ 3 min — short howto, no chapter structure helps)
  - `metadata.chapter_markers` is empty or null
- **Hierarchical (chapter → scenes)** otherwise

In hierarchical mode, group scenes by their `chapter_title` and emit the chapters in source order. Scenes whose `chapter_title` is null (e.g. they fall in a gap between chapters) go in a `## Uncategorized` section at the end.

### D.5. Compose the markdown body

Emit `index.md` with this top-level structure:

```markdown
---
<frontmatter from Phase B / C, YAML>
---

# <metadata.source_title>

**Source:** [<metadata.source_url>](<metadata.source_url>) — <metadata.channel> — <duration formatted as MM:SS or HH:MM:SS>

## TL;DR

<TL;DR string from Phase C.1>

## Key takeaways

- <bullet 1>
- <bullet 2>
- ...

## Scenes

<flat or hierarchical, see below>

## References

<list from Phase C.3, or omit the section if empty>

## Commands & Code

<consolidated list from Phase C.4, or omit the section if empty>
```

**Scene rendering — flat mode:**

```markdown
### Scene 1 — 00:00 to 00:30

![[scene-01.png]]

<transcript text for this scene, reflowed into paragraphs at sensible breaks; words verbatim>

<inline code block here if Phase C.4 attributed any commands to this scene>
```

**Scene rendering — hierarchical mode:**

```markdown
### <chapter_title>

#### Scene 1 — 00:00 to 00:30

![[scene-01.png]]

<transcript ...>

#### Scene 2 — 00:30 to 01:15

![[scene-02.png]]

<transcript ...>

### <next chapter_title>

#### Scene 3 — ...
```

Notes on scene rendering:

- Image embed uses Obsidian's wikilink form `![[scene-NN.png]]` since the file is in the same per-note folder. This renders inline in Obsidian and remains a valid relative reference if the entry is moved.
- Transcript reflow into paragraphs is allowed (sentences shouldn't be cut mid-clause). **Do not change words.**
- Times are formatted as `MM:SS` for videos under an hour, `HH:MM:SS` otherwise.
- Inline code blocks for commands attributed to a scene appear after the transcript paragraph that introduces them. The same code blocks also appear in the consolidated `## Commands & Code` section at the bottom — duplication is intentional, the bottom section is the user's quick-reference index.

### D.6. Write the file

Write `<entry_dir>/index.md`. Verify the file is non-empty and contains valid YAML frontmatter (parse-check it after writing — if YAML fails, you have a quoting bug to fix before declaring success).

Print a clear success message with the absolute path to `index.md` so the user knows where to open it.

### D.7. Failure-mode degradations (Phase 1 scope)

Apply the failure-mode rules from the bottom of this document:

- Re-running on existing entry without `--rerun`: print message, exit (D.2)
- Very short video (≤ 3 min): force flat structure regardless of chapter_markers (D.4)
- Live stream / unavailable / no transcript: handled in Phase A; Phase D is unreachable in those cases

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

*All four phases (A — sampling, B — consolidation + frontmatter, C — structured extraction, D — output writing) are now covered by this SKILL.md. End-to-end validation against the grain-haul test video is the next step (see beads issue ih2.10).*
