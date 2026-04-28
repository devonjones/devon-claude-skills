---
name: youtube-synthesizer
description: Turn a YouTube video into a faithful-capture literature note in an Obsidian vault. Use when the user wants to ingest a video (explainer, howto, lecture) into their personal source notes corpus. Combines transcript + load-bearing visual frames + structured extraction.
---

# YouTube Synthesizer

Orchestrates `youtube-transcript` and `youtube-screenshotter` to produce an Obsidian literature note for a video. Drives image selection by *value-filter* — every candidate frame is classified by KIND, and only frames that communicate something the transcript words don't survive into the entry. All vision and reasoning runs on your own native capability — no separate API calls, no extra billing.

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

- `index.md` — frontmatter + body (TL;DR, key takeaways, chapter-level prose with inline images, references, commands & code)
- `image-NN.png` siblings — one per kept informational frame, in source order

---

## The value-filter principle

> **Images appear in the wiki entry only when they communicate something the transcript words don't, or when they help explain the narrative — even if that means several in a row.**

The skill does **not** treat visual change as the trigger for capturing a "scene." A typical explainer video is ~70% talking-head plus filler (title cards, pull-quote text cards, between-content transitions) and ~30% load-bearing visuals (diagrams, maps, charts, code, UI, b-roll). Only the load-bearing 30% should appear as images in the entry. Number of images per video is whatever the source has of substance: 0 in a pure-talking-head section, 4-in-a-row during an animated diagram explanation.

Phase A produces an ordered list of `(timestamp, frame_path, kind)` triples for the kept frames; Phase D renders them as inline image embeds inside chapter-level prose.

### Frame kinds

For each candidate frame, classify as exactly one of:

**Drop (never embed):**

- `talking-head` — presenter's face/torso with no overlaid content
- `blank` — empty background, between-content transition frame, near-uniform pixels
- `title-card` — text-only on illustrated background, where the text duplicates the transcript ("THE OXEN PARADOX," "CHAPTER 3," "THREE DAY RULE")
- `pull-quote-card` — emphasized restatement of what the presenter just said, with no additional information

**Keep (embed at the frame's timestamp):**

- `diagram` — abstract illustration explaining a concept (stick-figures, flowcharts, conceptual visuals)
- `map` — geographic or topological layout (in-world maps, real-world geography, network diagrams)
- `chart` — data visualization (bar/line/pie/scatter, tables, math plots)
- `code` — source code, terminal output, command lines, config files
- `ui` — software interface, dashboard, application screenshot
- `b-roll` — real-world footage that is itself the subject (e.g. demonstrating a tool's physical use)
- `animated-build-step` — one frame of a multi-step animated diagram where each step adds information; **keep all of them**, do not collapse to the terminal frame
- `hybrid-with-info-overlay` — talking-head with a substantive overlay (chart, code, callout) that adds information beyond what the words convey

When uncertain between drop-kinds and keep-kinds, prefer keep. Wasting one frame downstream is cheap; missing a real informational moment is expensive. When uncertain between two keep-kinds, pick the closer match — the kind tag is informational metadata only and does not change rendering in Phase D.

---

## Phase A — Value-filter sampling

Produces an ordered list of `(timestamp, frame_path, kind)` triples for the kept frames.

### A.1. Fetch transcript and metadata

- `<youtube-transcript scripts dir>/get_transcript.py "<URL>"` → transcript with timestamps
- `<youtube-screenshotter scripts dir>/video.py "<URL>" --no-download` → metadata (channel_id, chapter_markers, description, etc.)

If the video has no transcript, error with a clear message and stop. **Do not fabricate one.**

Save the metadata block; Phase B reads `description`, `chapter_markers`, `source_published_date`, etc. from it.

### A.2. Decide initial sample timestamps

Build a sorted unique list from:

- **A coarse stride across the duration.** Default to one sample every ~30 seconds, snapped to the nearest transcript snippet boundary. Auto-caption snippets are typically 1–3 seconds apart, so sampling every snippet would produce hundreds of frames per hour — too dense for the classification pass to be tractable. The 30s stride gives ~120 candidates per hour; bisection in A.5 fills in any informational frames the stride missed.
- Each chapter marker start (from metadata)
- **`t = 0.5` — always include this.** The video's opening frame (logo, title card, opening shot) is commonly distinct and load-bearing; the coarse stride alone won't catch it.
- Any silence gap > 10 seconds between consecutive snippets — anchor a sample at the gap midpoint

### A.3. Extract initial frames

```
<youtube-screenshotter scripts dir>/extract.py "<URL>" -t <ts1> -t <ts2> ... -o <work_dir>
```

Returns a manifest with `(timestamp, frame_path, phash)` per requested timestamp. The video downloads once to `<work_dir>/<video_id>.mp4`; subsequent calls hit the cache.

### A.4. Classify every frame by kind

For each candidate frame, do the visual judgment yourself:

1. Read the frame image (use the Read tool on `frame_path`)
2. Read the transcript text spoken in a small window around the frame's timestamp (e.g. ±5 seconds)
3. Pick exactly one of the eleven kinds from the value-filter principle above
4. If the kind is in the **drop** set, mark the frame dropped and move on. If in the **keep** set, record `(timestamp, frame_path, kind)` in the keep-list.

Process frames in batches per turn (typically 10–20 frames per batch) rather than one at a time. Use a single Read sequence to load each batch's frames, then classify them all in your reasoning before emitting the next batch's reads.

**Use transcript context.** The intended visual content is often signaled by the words around it:

- "As you can see," "let me show you," "here's the diagram" → expect a `diagram`/`chart`/`map`/`ui`/`code` frame
- "And now we add," "next we get," "step three" → expect `animated-build-step`
- Continuing to discuss the same conceptual point with no visual cues → likely `talking-head` (drop)

When a frame is genuinely ambiguous between a keep-kind and `talking-head`, prefer keep.

### A.5. Bisect gaps between consecutive keepers

After the initial classification pass, walk the keep-list in time order. For each consecutive pair `(K_i, K_{i+1})`:

- If `K_{i+1}.timestamp - K_i.timestamp > 15` seconds **and** the intervening transcript suggests visual content (the speaker says "as you can see," "let me show you," "here's the diagram," "and over here," etc.), schedule a midpoint sample.
- Re-call `extract.py` with the new timestamps (cached video file makes this fast).
- Classify the new frames by the same kind taxonomy. Drop-kinds → ignore; keep-kinds → insert into the keep-list and recurse on the new gaps.

Bisect when there's a **gap** that might contain a missed informational frame in a talking-head-dominated stretch, not when consecutive frames look different.

Stop bisecting a window when any of:

- Window < 5 seconds
- Midpoint frame classified as a drop-kind (no informational content found)
- The bisection has run twice in this window and produced no keepers

### A.6. Densely sample animated-build-step runs

When you classify a frame as `animated-build-step`, the video is in the middle of an animated diagram, equation, or build-up where each step adds information. Sample more densely inside this window: every 2–3 seconds, starting from the build-step frame's timestamp, until the kind transitions to something else (`diagram`/`talking-head`/`title-card`/etc.) or until the next chapter marker.

**Keep every animated-build-step frame.** Do not collapse to the terminal frame; intermediate steps are the point of the build-up. The result is multiple consecutive entries in the keep-list at close timestamps, which Phase D will render as a sequence of inline images.

### A.7. Dedup near-identical keepers via pHash

After bisection and dense sampling, walk the keep-list one more time. For each consecutive pair `(K_i, K_{i+1})`, compare their pHashes via:

```
<youtube-screenshotter scripts dir>/phash.py compare <K_i.frame_path> <K_{i+1}.frame_path>
```

If `hamming ≤ 5` (the `same` verdict), the two frames are visually near-identical — drop `K_{i+1}` from the keep-list.

This catches cases where dense sampling produced redundant captures (e.g. a long-held diagram caught at multiple boundaries). pHash's role here is as a cheap deduplication check applied after kind-classification, not as a sampling-decision signal.

### A.8. Emit the final keep-list

Output a sorted list of `(timestamp, frame_path, kind)` triples. This is the input to Phases C and D.

The expected size depends entirely on the video's information density. A 1hr lecture-with-slides might produce 30–50 kept frames; a 20-minute video that's 80% talking-head might produce 4–6. There is no target count — the value-filter rule sets the bar.

---

## Phase B — Frontmatter

This phase assembles the YAML frontmatter from the screenshotter's metadata block.

### B.1. Generate the frontmatter dictionary

The frontmatter has two parts: a base schema shared with future article/pdf/substack source-skills (so the future sqlite3 indexer joins on a single contract), and YouTube-specific extras alongside.

**Base schema:**

```yaml
source_type: youtube
source_url: <metadata.source_url>
source_title: <metadata.source_title>
source_author: <metadata.source_author>           # channel display name for YouTube
source_published_date: <metadata.source_published_date>   # YYYY-MM-DD
source_description: |
  <metadata.description verbatim from yt-dlp — author-written video description.
  Block-scalar YAML so multi-line is fine. Leave empty string if no description.>
ingested_date: <today's date in YYYY-MM-DD>
tags: []           # populated by Phase C
topics: []         # populated by Phase C
why_ingested: ""   # optional; from --why flag at invocation time
```

`source_description` is the verbatim author-written description. It is **not** rendered in the body — it would duplicate TL;DR / takeaways. It lives in frontmatter only, where it serves two purposes:

1. **Hallucination check** — Phase C compares the agent-generated TL;DR against this prose. If the TL;DR introduces framing not grounded in either the transcript or the description, the agent has drifted.
2. **Searchable reference** — the user (or a future re-run with an updated SKILL.md) can compare against the original.

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
transcript_corrections: []  # populated by Phase C / Phase D as soft-corrects are applied
```

`transcript_corrections` is a list of `{original, corrected, timestamp}` entries logging every soft-correct the synthesizer applied to the auto-caption text. Auditable; lets a future linter spot systematic captioner failures across the corpus. Empty list if no corrections were applied.

`channel_id` is the key for future "process all videos from this channel and cross-link them" runs — channels can rename themselves, IDs are stable.

**Frontmatter discipline:** strict key-value, no narrative prose. Structured data (lists of objects) is fine — `chapter_markers` and `transcript_corrections` are both lists of dicts. Narrative content goes in the body, never in frontmatter.

---

## Phase C — Structured extraction

Produces the body sections of the wiki entry plus the `tags` / `topics` frontmatter and the `transcript_corrections` log. Source-faithful: extract what the video communicated; do not interpret or synthesize. Use the transcript text, the video description, and (for Commands & Code) what's visible in kept frames.

### C.1. TL;DR

1–2 sentences capturing the video's central claim or thesis. The highest-leverage section for re-discovery six months later — the user reads this to remember what the video was about.

Source: transcript primarily. Look for explicit thesis statements (often in the first 60s and the final 60s), the chapter titles (especially the first), and the title.

Avoid: editorializing ("an interesting take on..."), interpretation ("the video argues that... but..."), framing for any particular use case.

### C.2. Key takeaways

3–5 bullets, each a single sentence, capturing the points the video makes that the user will want to remember.

Source: transcript. A takeaway is a substantive claim the presenter makes — not a section header. "Three days is the maximum economic distance for hauling grain by ox" is a takeaway; "The presenter discusses grain hauling" is not.

Avoid: meta-statements about the video itself, restating the title, padding the list to hit a count (3 strong bullets beat 5 weak ones).

### C.3. Hallucination check via description

Before finalizing the TL;DR and key takeaways, compare them against the verbatim video description (`source_description` from Phase B):

- Many channels include an "ABOUT THIS VIDEO" prose block in the description that summarizes the video's premise in the author's own words. This is ground truth for what the video is about.
- If the agent-generated TL;DR introduces framing or claims that aren't grounded in **either** the transcript **or** the description, the agent has drifted — re-do the TL;DR.
- Bias toward attribution-implicit voice rather than asserting claims as fact. An entry in `sources/videos/` is by definition a record of what the source said; the framing should make that clear without explicit "the video argues..." hedging on every sentence.

This is a check, not a copy. Do not paste the description prose into the TL;DR. Use it to detect drift.

### C.4. Description-driven references

Pull the references list from the video description, not from the transcript prose. The description is where authors put the actual URLs they're pointing at; the transcript contains the verbal mentions ("check out my Discord," "see the resources on my website") but rarely the URLs themselves.

**Where references come from (in priority order):**

1. **URLs in the video description** (`metadata.description`). Most cited resources live here. Extract via regex on `https?://` and `www.` prefixes.
2. **URLs spoken in-video and captured by the transcript** (rare, but worth catching).
3. **People / titles named in the video without explicit URLs** — emit as plain text (no fabricated URLs).

**URL classification** (kept vs dropped):

| Keep | Drop |
|---|---|
| Author's resource page / website (when video mentions specific content there) | Patreon / "support me" / tip jar |
| Project / tool homepages that are the topic of the video | Merch / store URLs |
| Cited papers, articles, books | Sponsor codes / affiliate links |
| GitHub / source code | Generic social media handles (X, IG, TikTok) |
| Related videos on the same topic | Newsletter signups (unless newsletter is itself the cited source) |
| Community spaces (Discord, forum) **only when video points at specific topical content there** | Generic "join my community" with no specific in-video reference |
| Standalone documentation links | Linktree / link-aggregator URLs (resolve to the destination if possible, drop if not) |

**Output format:** one bullet per kept reference, with the actual URL and a one-line annotation noting why it was cited:

```markdown
- [The Grainbound resources page](https://thegrainbound.com/resources/) — host of the worksheet and practice map referenced in chapter 4.
- [The Grainbound Discord](https://discord.gg/PTnt72aj8B) — community where the worksheet+map are pinned.
- A separate video on vassal/loyalty systems — referenced at workflow step 7 (no URL provided in description).
```

**Avoid auto-generated wikilinks at this skill version.** Cross-references between video entries should emerge organically as the corpus grows; auto-linking on heuristic guesses tends to produce noise. A future cross-source linker (sqlite3-backed) will resolve names to wikilinks once matching `sources/` entries exist.

### C.5. Commands & Code

For howto / technical videos: every shell command, code block, or configuration the presenter demonstrates or types out, captured as code blocks with the language tag.

Source: kept frames where code is visible (read the image, transcribe verbatim) plus transcript where the presenter narrates a command.

For non-technical videos (worldbuilding, history, design discussion), this section is omitted entirely — do not pad with pseudo-commands.

Format:

```python
# from frame at 04:32 — the main loop the presenter demonstrates
for x in range(10):
    process(x)
```

Each block gets a one-line lead-in noting the timestamp it came from, so the reader can locate the visual context.

### C.6. Tags + topics

Populate the frontmatter `tags` and `topics` fields with a controlled list extracted from the video's content.

- **`topics`** — broad subject categories (e.g. `worldbuilding`, `medieval-history`, `economics`, `joinery`, `python`). 1–4 entries. Helps the user filter the corpus along the major axes they think about. Match the user's existing vocabulary if you can see prior entries in the same vault.
- **`tags`** — finer-grained markers (e.g. `grain-supply`, `oxen`, `radius-of-effect`, `dovetails`, `unit-tests`). 3–8 entries. These power the future sqlite3 FTS index more than topics do.

Both lists must be kebab-case strings, no spaces, no special characters. Do not invent vague tags (`interesting`, `useful`); every entry should map to a concrete subject.

### C.7. Auto-caption soft-correct policy

YouTube's auto-captioner produces transcription errors that propagate verbatim into the wiki entry under a strict "do not change words" rule. Examples: *"kills for measurement"* (meant *"scales for measurement"* — homophone misread). This breaks future full-text search ("scales" matches no results) and produces gibberish in the rendered prose.

The synthesizer is allowed — and required — to **soft-correct** these obvious mis-transcriptions when composing the body prose in Phase D.

**Categories to correct:**

- **Homophones** — *kills↔scales, their↔there↔they're, write↔right, hear↔here, principle↔principal* — when the intended word is unambiguous from the surrounding sentence.
- **Garbled compound words** — caption merges or splits words wrongly (e.g. *"a head"* → *"ahead"* in motion contexts; *"every day"* vs *"everyday"* per usage).
- **Dropped articles** — when the sentence is otherwise grammatical and a missing *the/a/an* is obvious.

**Categories NOT to correct:**

- Paraphrasing or summarizing — the discipline of source-faithfulness applies to *what the presenter intended to say*, not to "improving" their delivery. Do not condense filler words, repair sentence fragments, or smooth out mid-sentence corrections the presenter made themselves.
- Ambiguous cases — when you're not confident which word the presenter meant, leave the caption verbatim. Better to have one piece of garbled text than to invent the wrong word.
- Domain jargon you don't recognize — a word you find unfamiliar isn't necessarily a mis-transcription.

**Logging corrections.** For every correction applied, append an entry to the `transcript_corrections` frontmatter list:

```yaml
transcript_corrections:
  - original: "kills"
    corrected: "scales"
    timestamp: 320.5
  - original: "their"
    corrected: "there"
    timestamp: 487.2
```

The timestamp is the transcript-snippet timestamp where the original word appears. Logging makes corrections auditable and lets a future linter spot systematic captioner failures across the corpus.

### C.8. Output of Phase C

You now hold:

- A TL;DR string (validated against `source_description`)
- A key-takeaways bullet list
- A references list (description-driven, filtered, with URLs)
- A commands-and-code block list (or empty)
- Populated `tags` and `topics` arrays for the frontmatter
- A `transcript_corrections` list of soft-corrects applied (so far — Phase D applies more during prose composition and appends to this list)

These are consumed by Phase D (output writing).

---

## Phase D — Output writing

Assemble everything from Phases B and C, plus the keep-list from Phase A, into the Obsidian literature note and write it to the user's vault.

### D.1. Resolve the entry path

Given the user-supplied vault path `<vault>` and `metadata.source_title`:

1. **Sanitize the title:** lowercase → strip anything not in `[a-z0-9 ]` (apostrophes vanish — produces `thats` not `that-s`; quotes, colons, em-dashes, ampersands all disappear) → collapse whitespace runs into single hyphens → trim leading/trailing hyphens → truncate at 80 characters.
2. Today's date in `YYYY-MM-DD` format (this is `ingested_date`).
3. Compose the entry directory: `<vault>/sources/videos/<ingested_date>-<sanitized_title>/`

Example: `~/Obsidian/worldbuilding/sources/videos/2026-04-27-the-ox-thats-breaking-your-fantasy-map/`

### D.2. Skip-or-overwrite check

If the entry directory already exists and the user did not pass `--rerun`:

- Print a clear message: *"Entry already exists at `<path>`. Pass --rerun to overwrite."*
- Stop. Do not modify existing content.

If `--rerun`, remove the existing directory's contents before writing (preserve nothing — full regeneration).

### D.3. Copy kept frames

Create the entry directory. For each entry in the keep-list (Phase A.8) in timestamp order, copy its `frame_path` to `<entry_dir>/image-NN.png`, where `NN` is a 2-digit zero-padded index starting at `01`. Use 3 digits if the keep-list count exceeds 99.

Track the mapping `keep_index → (timestamp, relative_filename, kind)` for use in body composition.

### D.4. Compose the body — chapter-level prose flow with inline images

The body is one continuous prose flow per chapter, with images embedded inline at their timestamps. Images are anonymous anchors inside the prose, not section dividers.

#### D.4.a. Decide structure

- **Flat (no chapter sections)** if any of:
  - `metadata.duration_seconds <= 180` (≤ 3 min)
  - `metadata.chapter_markers` is empty or null
- **Chaptered** otherwise — one `## <chapter title>` section per entry in `chapter_markers`, in source order.

#### D.4.b. Snap chapter boundaries to sentence ends

Before concatenating per-chapter, **adjust each non-final chapter's `end_time` to the nearest sentence-terminator-ending snippet within `[end_time − 5, end_time + 15]`** of the metadata boundary. Chapter markers in YouTube metadata are timed to visual transitions, not sentence ends — using them strictly produces "...the political map draws itself. Chapter / two." mid-clause splits. The next chapter's `start_time` then equals the previous chapter's snapped `end_time`.

Snapping rule: pick the closest snippet whose text ends with `.`, `!`, or `?` and whose timestamp lies in that window. If no such snippet exists in the window, leave the boundary at `end_time`.

This is also where the spoken "Chapter N." transition lines naturally land: with snapping, "Chapter 3." gets pulled into chapter 2's tail (since the boundary moves to just past it), so chapter 3 starts cleanly with its first content sentence.

#### D.4.c. Per-chapter (or whole-video, in flat mode) prose composition

For each chapter's snapped `[start_time, end_time)` span (or the full `[0, duration)` in flat mode):

1. **Concatenate all transcript snippets** whose timestamp falls inside the span.
2. **Apply soft-corrects** per Phase C.7 to the concatenated text. Append every correction made here to the `transcript_corrections` frontmatter list.
3. **Reflow into paragraphs at sentence boundaries.** Walk the corrected text and break a paragraph every ~3–6 sentences at the next sentence terminator (`. `, `! `, `? `) — choose the break point at a natural feeling pause rather than a fixed sentence count. **Do not change words** beyond the soft-corrects from step 2; do not paraphrase, summarize, or restructure.
4. **Embed kept frames inline.** For every keep-list entry whose `timestamp` falls inside this chapter's span, inject `![[image-NN.png]]` (on its own line, surrounded by blank lines) at the **nearest sentence boundary** to the timestamp in the reflowed prose. Multiple images in close succession (e.g. an animated-build-step run) appear consecutively, separated only by whatever prose falls between their timestamps if any.

The result, per chapter:

```markdown
## <chapter title verbatim from chapter_markers>

<reflowed paragraph 1>

<reflowed paragraph 2>

![[image-03.png]]

<reflowed paragraph 3>

![[image-04.png]]

![[image-05.png]]

<reflowed paragraph 4>
```

**Chapter title rule:** use the author's chapter titles **verbatim**, including placeholder titles like "Chapter 2," "Chapter 3," or numerically-prefixed titles like "1. Setup." The chapter structure is the author's deliberate framing of the video; do not synthesize "better" chapter titles from content. If `chapter_markers` is missing, fall back to flat mode.

**Flat-mode rendering:** same prose flow, no `## <chapter title>` heading. Render the prose under a single `## Body` heading after `## Key takeaways`.

**Gap handling (chaptered mode):** if `chapter_markers` doesn't cover the full duration, render the gap-time transcript under an `## Uncategorized` section after the last chapter, using the same reflow rules.

#### D.4.d. Top-level body skeleton

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

## <Chapter 1 title>

<reflowed prose with inline ![[image-NN.png]] embeds>

## <Chapter 2 title>

<reflowed prose with inline image embeds>

...

## References

<list from Phase C.4, or omit the section entirely if empty>

## Commands & Code

<consolidated list from Phase C.5, or omit the section entirely if empty>
```

In flat mode, replace the chapter sections with a single `## Body` containing all the reflowed prose.

Notes:

- Image embeds use Obsidian's wikilink form `![[image-NN.png]]` since the file is in the same per-note folder. This renders inline in Obsidian and remains a valid relative reference if the entry is moved.
- Times in the source line are formatted as `MM:SS` for videos under an hour, `HH:MM:SS` otherwise.
- Images appear inline at their timestamps inside the chapter prose. They do **not** appear in the consolidated `## Commands & Code` section — that section is text-only.
- Code blocks attributed to a specific timestamp may appear inline in the prose at that point (with a one-line lead-in) **and** are also collected in the `## Commands & Code` section at the bottom. Duplication is intentional: inline gives narrative context, the bottom section is the user's quick-reference index.

### D.5. Write the file

Write `<entry_dir>/index.md`. After writing, verify the file is non-empty and that the YAML frontmatter parses cleanly (if YAML fails, you have a quoting bug in `source_description` or elsewhere — fix it before declaring success). The block-scalar `|` form on `source_description` handles most cases, but watch for unescaped backticks or trailing whitespace in the description text.

Print a clear success message with the absolute path to `index.md` so the user knows where to open it.

### D.6. Failure-mode degradations (current scope)

- Re-running on existing entry without `--rerun`: print message, exit (D.2).
- Very short video (≤ 3 min) or no `chapter_markers`: force flat structure (D.4.a).
- Live stream / unavailable / no transcript: handled in Phase A; Phase D is unreachable in those cases.

---

## Previewing an entry

Wiki entries use Obsidian's wikilink syntax (`![[image-NN.png]]`) which doesn't render in standard markdown viewers. The `scripts/preview.py` helper renders any entry to HTML and serves the entry directory over HTTP — useful on a headless box where you can't open Obsidian directly.

```
<youtube-synthesizer scripts dir>/preview.py <entry-dir> [--port 8765] [--bind 0.0.0.0]
```

Pass either an entry directory (containing `index.md` + `image-NN.png`) or a `.md` file directly. The script writes a sibling `index.html` with wikilinks rewritten to `<img>` tags and YAML frontmatter shown as a collapsible block, then starts an HTTP server. Open `http://<host>:<port>/` in a browser.

Use `--no-serve` to render the HTML and exit without starting the server. Use `--bind 127.0.0.1` to restrict to localhost when working on a shared box.

The script is stdlib-only (no dependencies). It is generic over wiki entries — any future source-type skill that produces this same per-note folder structure can use it too.

---

## Discipline: faithful capture, no editorializing

The skill's job is to deliver "here is what this video said and showed, structured and searchable" — not to weave the content into the user's mental model. That weaving is downstream, in the vault root where the user (and you, in other tasks) builds permanent notes on top of these literature notes.

Concretely: do not reframe content for any particular use case (worldbuilding, debugging, learning), do not add interpretive headers, do not editorialize the presenter's claims. Capture what was said and shown.

The agent's voice should not blend with the presenter's voice. The synthesizer-generated TL;DR and takeaways describe the video's claims — they should attribute claims to the video implicitly through the document's framing (an entry in `sources/videos/` is by definition a record of what the source said) rather than asserting claims as undisputed facts.

The soft-correct policy (Phase C.7) is the one place the skill modifies words. It applies *only* to obvious auto-caption mis-transcriptions, never to paraphrasing or "improving" delivery. Every correction is logged in `transcript_corrections` for auditability.

---

## Prerequisites

- `youtube-transcript` skill installed
- `youtube-screenshotter` skill installed (transitively requires `uv` and `ffmpeg`)
- Network access to YouTube
- A target Obsidian vault path (writable) — used by Phase D

## Failure modes

- **No transcript available** (no captions, foreign language) → error early with a clear message; stop
- **Video unavailable** (private, members-only, age-restricted, geo-blocked) → error early; stop
- **Live streams** → refuse for now (no fixed endpoint to sample over)
- **Very short videos** (≤ 3 min) → flat-mode rendering, no chapter sections
- **Video has chapter markers but they don't cover the full duration** → see Phase D.4.c gap-handling rule
