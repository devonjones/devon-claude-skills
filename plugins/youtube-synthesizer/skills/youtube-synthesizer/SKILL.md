---
name: youtube-synthesizer
description: Turn a YouTube video into a faithful-capture literature note in an Obsidian vault (transcript, load-bearing visual frames, structured extraction), with optional Dropbox sync via rclone. Use when the user gives a YouTube URL or video ID and wants to ingest, save, or take notes on it (explainer, howto, lecture) into their ObsidianVaults source notes.
---

# YouTube Synthesizer

Orchestrates `youtube-transcript` and `youtube-screenshotter` (each `<... scripts dir>` below is that skill's `scripts/` directory) to produce an Obsidian literature note for a video. Drives image selection by *value-filter* — every candidate frame is classified by KIND, and only frames that communicate something the transcript words don't survive into the entry. All vision and reasoning runs on your own native capability — no separate API calls, no extra billing.

You — the agent running this skill — do the visual judgment inline as you follow the procedure below. The skill produces faithful capture of the source; downstream synthesis into the user's mental model is their job, not yours.

## Invocation

Required inputs from the user:

- **`<URL>`** — YouTube video URL or 11-character video ID

Optional:

- **`<vault>`** — absolute path to the target Obsidian vault, **or** a vault name relative to `~/ObsidianVaults/`. The skill writes to `<vault>/sources/videos/<ingested-date>-<sanitized-title>/`. If omitted, see Phase D.1 for the discovery flow.
- **`--rerun`** — overwrite an existing entry at the target path. Without this flag, the skill refuses to overwrite (Phase D.2).
- **`--why <reason>`** — populate the `why_ingested` frontmatter field. If omitted, leave it as an empty string; the user can fill it in after.
- **`--no-sync`** — skip the post-write Dropbox sync prompt (Phase D.6). Otherwise the skill asks after a successful write whether to push the new entry to `dropbox:ObsidianVaults/<vault-name>/sources/videos/<channel>/<entry-dir>/`.

If `<URL>` is missing, ask the user before starting work — do not guess. `<vault>` resolution is described in Phase D.1; do not guess that either.

## Output

A single Obsidian literature note at `<vault>/sources/videos/<sanitized-channel>/<ingested-date>-<sanitized-title>/` containing:

- `<sanitized-title>.md` — frontmatter + body (TL;DR, key takeaways, chapter-level prose with inline images, references, commands & code). Same `<sanitized-title>` as the parent directory's title segment, without the date prefix (the directory carries the date already).
- `image-NN.png` siblings — one per kept informational frame, in source order

Grouping by channel keeps a creator's videos together — opening `<vault>/sources/videos/the-grainbound/` shows every Grainbound entry side-by-side.

---

## The value-filter principle

> **Images appear in the entry only when they communicate something the transcript words don't, or when they help explain the narrative — even if that means several in a row.**

The skill does **not** treat visual change as the trigger for capturing a "scene." A typical explainer video is ~70% talking-head plus filler (title cards, pull-quote text cards, between-content transitions) and ~30% load-bearing visuals (diagrams, maps, charts, code, UI, b-roll). Only the load-bearing 30% should appear as images in the entry. Number of images per video is whatever the source has of substance: 0 in a pure-talking-head section, 4-in-a-row during an animated diagram explanation.

Phase A produces an ordered list of `(timestamp, frame_path, kind)` triples for the kept frames; Phase D renders them as inline image embeds inside chapter-level prose.

### Frame kinds

For each candidate frame, classify as exactly one of:

**Drop (never embed):**

- `talking-head` — presenter's face/torso with no overlaid content
- `blank` — empty background, between-content transition frame, near-uniform pixels
- `title-card` — text-only on illustrated background, where the text duplicates the transcript ("THE OXEN PARADOX," "CHAPTER 3," "THREE DAY RULE")
- `pull-quote-card` — emphasized restatement of what the presenter just said, with no additional information

**Conditional (keep only when informational):**

- `map-overview` — establishing shot of geography with no annotations or overlays. **Drop unless** the surrounding transcript prose specifically discusses "this region" or "this part of the map," **or** it is the very first map shown (intro establisher). Most repeat-views of the same world map are noise.

**Keep (embed at the frame's timestamp):**

- `diagram` — abstract illustration explaining a concept (stick-figures, flowcharts, conceptual visuals)
- `map-with-overlay` — map plus drawn-in markers (red dots, dashed lines, labels, route arrows, radius circles, etc.). The overlays carry the information.
- `chart` — data visualization (bar/line/pie/scatter, tables, math plots)
- `code` — source code, terminal output, command lines, config files
- `ui` — software interface, dashboard, application screenshot
- `b-roll` — real-world footage that is itself the subject (e.g. demonstrating a tool's physical use)
- `animated-build-step` — one frame of a multi-step animated diagram where each step adds information; **keep all of them**, do not collapse to the terminal frame
- `hybrid-with-info-overlay` — talking-head with a substantive overlay (chart, code, callout) that adds information beyond what the words convey

When uncertain between drop-kinds and keep-kinds, prefer keep. Wasting one frame downstream is cheap; missing a real informational moment is expensive. When uncertain between two keep-kinds, pick the closer match — the kind tag is informational metadata only and does not change rendering in Phase D. When uncertain between `map-overview` and `map-with-overlay`, default to `map-with-overlay` (keep) — visible overlays the agent missed are still informational.

---

## Phase A — Value-filter sampling

Produces an ordered list of `(timestamp, frame_path, kind)` triples for the kept frames.

### A.1. Fetch transcript and metadata

Pick one scratch `<work_dir>` for the run (e.g. `mktemp -d`); every phase below reads and writes there.

- `<youtube-transcript scripts dir>/get_transcript.py "<URL>" -t -o <work_dir>/transcript.txt` → transcript with timestamps (D.5 checks the body against this file)
- `<youtube-screenshotter scripts dir>/video.py "<URL>" --no-download` → metadata (channel_id, chapter_markers, description, etc.)

If the video has no transcript, error with a clear message and stop. **Do not fabricate one.**

Save the metadata block; Phase B reads `description`, `chapter_markers`, `source_published_date`, etc. from it.

### A.2. Discover candidate timestamps

```
<youtube-screenshotter scripts dir>/discover.py "<URL>" -o <work_dir>
```

Returns a manifest with two source signals (`scene_detect` and `phash_runs`) and a unioned `candidates` list. Typical output for an 18-minute video is 60–140 candidates, depending on visual density.

The candidate list is high-recall: every sustained content stretch ≥ 3 seconds plus every sharp cut shows up. Most candidates will be drop-kinds (talking-head, title-cards) — the agent's job is to filter them down to the informational subset in A.4.

### A.3. Extract candidate frames at full resolution

```
<youtube-screenshotter scripts dir>/extract.py "<URL>" -t <ts1> -t <ts2> ... -o <work_dir> > <work_dir>/extract.json
```

Pass the timestamp list from `discover.py`'s `candidates` array. The video file is already cached (discover downloaded it); only the per-timestamp PNG extraction happens here.

### A.4. Classify every frame by kind

Tile the A.3 manifest into labeled 3×3 contact sheets:

```
<youtube-screenshotter scripts dir>/grid.py <work_dir>/extract.json -o <work_dir>/sheets
```

**Delegate classification to sub-agents — do not load sheets or frames into your own context.** Use the Agent tool (`subagent_type: general-purpose`) with up to 5 sheets (45 frames) per agent. Inline in the prompt the kind taxonomy and the value-filter principle (the sub-agent has no memory of this SKILL.md), the batch's entries from `grid.py`'s JSON (each `sheet` path with its cells' `label`, `timestamp` and `frame_path`), and the transcript spoken within ±5 seconds of each cell's timestamp, keyed by label.

For each batch, the sub-agent:

1. Reads each sheet (Read tool on `sheet`).
2. Picks exactly one kind per cell from the value-filter principle above, using the transcript snippet for that label.
3. Reads a cell's full-resolution `frame_path` only when the cell is too small to call — fine text, a possible `hybrid-with-info-overlay`, a `map-overview` vs `map-with-overlay` question. When still unsure, it keeps the frame.
4. Returns a JSON array `[{timestamp, frame_path, kind, note}, ...]` covering every cell — drop-kinds tagged `drop` with a brief `drop_reason`, keep-kinds with their kind tag and a one-line `note` describing what the frame shows.

The main agent collates the per-batch JSON into the running keep-list without ever reading the images itself.

**Use the discover.py `source` and `run_duration` hints.** They're informational signals, not classification rules:

- `source: phash_run` with `run_duration ≥ 5s` → likely sustained content; if the transcript at that timestamp doesn't explain a visual, often a sustained talking-head pose (drop).
- `source: phash_run` with `run_duration` 3–5s + transcript hint of visual content ("as you can see," "here's") → likely a real diagram.
- `source: scene_detect` with no `run_duration` → sharp cut; could be diagram, transition, or pose change.

**Use transcript context.** The intended visual content is often signaled by the words around it:

- "As you can see," "let me show you," "here's the diagram" → expect a `diagram`/`chart`/`map-with-overlay`/`ui`/`code` frame
- "And now we add," "next we get," "step three" → expect `animated-build-step`
- Continuing to discuss the same conceptual point with no visual cues → likely `talking-head` (drop)

When a frame is genuinely ambiguous between a keep-kind and `talking-head`, prefer keep.

### A.5. Build-up sequence detection

After the per-frame classification, walk the keep-list in time order. Detect animated build-ups by adjacent same-kind frames whose pHashes are similar-but-distinct:

For each consecutive pair `(K_i, K_{i+1})` in the keep-list:

- If both are the same keep-kind (e.g. both `diagram` or both `map-with-overlay`)
- AND their pHashes have Hamming distance in the range 10–25 (visually related but not identical)
- AND `K_{i+1}.timestamp - K_i.timestamp ≤ 10` seconds

…then this is an animated build-up sequence. The presenter is layering information onto the same canvas (e.g. wheat → wheat+sheep → wheat+sheep+wool, or a map gaining radii circles).

**Re-extract intermediate seconds inside the sequence.** Sample every 2 seconds between `K_i.timestamp` and `K_{i+1}.timestamp` via `extract.py`, classify each, and keep all build-up steps in the keep-list. Re-tag the original frames as `animated-build-step` if appropriate.

### A.6. Cross-time pHash dedup

Walk the entire keep-list (not just adjacent pairs) and drop any frame whose pHash is within Hamming ≤ 12 of an earlier-kept frame.

This catches the case where the same world-map appears at chapter 1's opening **and** at chapter 3's opening — visually identical but separated by minutes.

**Exclude `animated-build-step` frames from this pass.** A.5 deliberately keeps multiple frames of a single build-up sequence; their pHashes are similar by design, and re-pruning them here would undo A.5's work.

When a near-duplicate is detected, **keep the earlier frame** (it's the establisher) and drop the later one.

### A.7. Whole-list audit pass

Re-read every frame in the keep-list as a curated set and ask, for each one, "is this image actually useful in the entry?" This is a separate pass from per-frame classification (A.4): the per-batch sub-agents in A.4 each see only their own batch, so cross-batch redundancy and accumulated drift are invisible there.

**Delegate this to a single audit sub-agent** (Agent tool, `subagent_type: general-purpose`). The main agent passes the audit-agent the full keep-list (timestamp + frame_path + kind + note for every entry) and asks it to re-read the frames and return a JSON `[{timestamp, decision: "keep"|"drop", reason}, ...]`. The audit-agent reads the frames in its own context — the main agent never loads them. If the keep-list is large enough that even one sub-agent can't fit all the frames in 32 MB, partition by chapter or by index range and run several audit-agents in parallel.

For each frame, the audit-agent decides:

- **Keep** — the image communicates something specific (a concept, a build-up state, a map overlay, a piece of code). The entry is better with it than without it.
- **Drop** — the image is talking-head, a transition cartoon with no figures or labels, an empty title-card overlay, or visually redundant with another kept frame.

The audit-agent is told it is allowed to drop frames previously classified as keep-kinds — the audit's purpose is precisely to catch that drift. When dropping, prefer dropping later frames in a build-up sequence over earlier ones (the earlier frame usually carries the concept). For redundant maps, keep the one with the richest overlay.

The main agent then applies the audit-agent's decisions to produce the final keep-list.

### A.8. Emit the final keep-list

Output a sorted list of `(timestamp, frame_path, kind)` triples. This is the input to Phases C and D.

The expected size depends entirely on the video's information density. A 1hr lecture-with-slides might produce 30–50 kept frames; a 20-minute video that's 80% talking-head might produce 4–6. There is no target count — the value-filter rule plus the audit pass set the bar.

---

## Phases B and C — Frontmatter and structured extraction

Read [references/frontmatter-and-extraction.md](references/frontmatter-and-extraction.md) before starting Phase B. It defines the frontmatter schema (B.1) and the body sections: TL;DR, key takeaways, description check, references, commands and code, tags and topics, and the auto-caption soft-correct policy (C.1-C.8). Phase D cites those section numbers.

---


## Phase D — Output writing

Assemble everything from Phases B and C, plus the keep-list from Phase A, into the Obsidian literature note and write it to the user's vault.

### D.1. Resolve the entry path

#### D.1.a. Resolve `<vault>` if not supplied

The convention is that the user keeps Obsidian vaults under `~/ObsidianVaults/<vault-name>/`. The vault that hosts this entry depends on the video's topic, which the user picks per-run.

If `<vault>` was supplied at invocation:

- If it's an absolute path, use it directly.
- If it's a bare name (no `/`), resolve to `~/ObsidianVaults/<name>/`.

If `<vault>` was *not* supplied:

1. Recall the user's last picked vault from memory (search for a memory keyed under `youtube-synthesizer-last-vault` or similar — repo memory keys use hyphenated kebab-case, no spaces). If found, ask the user to confirm — *"last run wrote to `<recalled vault>`; same vault for this entry?"* — and use that on a yes.
2. If no recall (or the user said no), `ls ~/ObsidianVaults/` and present the list. Ask the user to pick one.
3. If `~/ObsidianVaults/` doesn't exist or is empty, ask the user for an absolute vault path.

After the user picks, save the chosen vault to memory so the next run can recall and confirm rather than re-prompt.

#### D.1.b. Compose the entry directory

Given the resolved `<vault>`, `metadata.channel`, and `metadata.source_title`:

1. **Sanitize the title:** lowercase → strip anything not in `[a-z0-9 ]` (apostrophes vanish — produces `thats` not `that-s`; quotes, colons, em-dashes, ampersands all disappear) → collapse whitespace runs into single hyphens → trim leading/trailing hyphens → truncate at 80 characters.
2. **Sanitize the channel name** with the same rule applied to `metadata.channel` (e.g. `"The Grainbound"` → `the-grainbound`).
3. Today's date in `YYYY-MM-DD` format (this is `ingested_date`).
4. Compose the entry directory: `<vault>/sources/videos/<sanitized_channel>/<ingested_date>-<sanitized_title>/`

Example: `~/ObsidianVaults/Worldbuilding/sources/videos/the-grainbound/2026-04-27-the-ox-thats-breaking-your-fantasy-map/`

The channel directory is created on-demand if it doesn't exist yet locally; the same convention must already exist on Dropbox before sync (see Phase D.6.a — `sync_to_dropbox.sh` refuses if the channel dir on the remote isn't there, so a typo'd channel name can't silently create a new dir on Dropbox).

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

Snapping rule: pick the closest snippet whose text ends with `.`, `!`, or `?` and whose timestamp lies in that window. If no such snippet exists in the window, leave the boundary at `end_time`. Unpunctuated captions (D.4.c step 3) have no terminators yet: place the boundary at the sentence end you restore nearest `end_time`, in the same window.

This is also where the spoken "Chapter N." transition lines naturally land: with snapping, "Chapter 3." gets pulled into chapter 2's tail (since the boundary moves to just past it), so chapter 3 starts cleanly with its first content sentence.

#### D.4.c. Per-chapter (or whole-video, in flat mode) prose composition

For each chapter's snapped `[start_time, end_time)` span (or the full `[0, duration)` in flat mode):

1. **Concatenate all transcript snippets** whose timestamp falls inside the span.
2. **Apply soft-corrects** per Phase C.7 to the concatenated text. Append every correction made here to the `transcript_corrections` frontmatter list.
3. **Restore punctuation if the captions have none.** Treat the transcript as unpunctuated when it has fewer than one `.`, `?` or `!` per 50 words. Then add sentence punctuation and capitalization as you write the prose: punctuation and letter case only, never a word added, dropped or changed. Set `punctuation_restored: true` in the frontmatter.
4. **Reflow into paragraphs at sentence boundaries.** Walk the corrected text and break a paragraph every ~3–6 sentences at the next sentence terminator (`. `, `! `, `? `) — choose the break point at a natural feeling pause rather than a fixed sentence count. **Do not change words** beyond the soft-corrects from step 2; do not paraphrase, summarize, or restructure.
5. **Embed kept frames inline.** For every keep-list entry whose `timestamp` falls inside this chapter's span, inject `![[image-NN.png]]` (on its own line, surrounded by blank lines) at the **nearest sentence boundary** to the timestamp in the reflowed prose. Multiple images in close succession (e.g. an animated-build-step run) appear consecutively, separated only by whatever prose falls between their timestamps if any.

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

Notes:

- Image embeds use Obsidian's wikilink form `![[image-NN.png]]` since the file is in the same per-note folder. This renders inline in Obsidian and remains a valid relative reference if the entry is moved.
- Times in the source line are formatted as `MM:SS` for videos under an hour, `HH:MM:SS` otherwise.
- Images appear inline at their timestamps inside the chapter prose. They do **not** appear in the consolidated `## Commands & Code` section — that section is text-only.
- Code blocks attributed to a specific timestamp may appear inline in the prose at that point (timestamp comment per C.5) **and** are also collected in the `## Commands & Code` section at the bottom. Duplication is intentional: inline gives narrative context, the bottom section is the user's quick-reference index.

### D.5. Write the file

Write `<entry_dir>/<sanitized-title>.md`, where `<sanitized-title>` is the same sanitization applied to `metadata.source_title` as in D.1.b but **without** the date prefix (the directory carries the date already). For *"The Ox That's Breaking Your Fantasy Map"* in dir `2026-04-29-the-ox-thats-breaking-your-fantasy-map/`, the file is `the-ox-thats-breaking-your-fantasy-map.md`.

After writing, verify the file is non-empty and that the YAML frontmatter parses cleanly (if YAML fails, you have a quoting bug in `source_description` or elsewhere — fix it before declaring success). The block-scalar `|` form on `source_description` handles most cases, but watch for unescaped backticks or trailing whitespace in the description text.

Then check the body against the transcript:

```
<youtube-synthesizer scripts dir>/check_fidelity.py <work_dir>/transcript.txt <entry_dir>/<sanitized-title>.md
```

It fails on any word in the chapter prose that differs from the transcript and isn't a logged `transcript_corrections` entry; case, punctuation and paragraph breaks don't count. On failure, restore the transcript's words at each reported spot (or log the soft-correct, if it is one under C.7) and re-run until it passes.

Print a clear success message with the absolute path to the .md file so the user knows where to open it.

### D.6. Optional Dropbox sync via rclone

After D.5 writes the entry successfully, ask the user whether to push the new entry directory to Dropbox.

**Skip this entire phase if `--no-sync` was passed at invocation.**

#### D.6.a. NEVER call rclone directly — use `scripts/sync_to_dropbox.sh`

`rclone sync` is destructive: it deletes anything in the target that isn't in the source. A wrong target path could wipe arbitrary amounts of the user's Dropbox.

The synthesizer ships a wrapper script that is the **only** sanctioned way to invoke rclone from this skill:

```
<youtube-synthesizer scripts dir>/sync_to_dropbox.sh <absolute-entry-dir> [--dry-run]
```

The script enforces the convention in code:

- Source must resolve under `~/ObsidianVaults/<vault>/sources/videos/<entry-dir>/` with exactly that path shape (`<vault>/sources/videos/<channel>/<entry-dir>/`); anything else is rejected before rclone runs.
- Target is *computed* by the script as `dropbox:ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>/`; the agent does not get to specify it. Targets at the Dropbox root, the `ObsidianVaults/` parent, the vault root, the `sources/` dir, the `videos/` dir, or the channel dir are explicitly refused.
- The destination vault dir (`dropbox:ObsidianVaults/<vault>/`) and channel dir must already exist on Dropbox before the sync runs, verified via `rclone lsd`, so a misspelled name cannot silently create a new dir. For a genuinely new vault or channel, the error message gives the one-time `rclone mkdir` command; run it, then retry the sync.
- Missing rclone or unconfigured `dropbox:` remote → the script reports the issue and exits non-zero without invoking rclone.

The agent **must not** invoke `rclone` directly anywhere in this skill — there is no situation where calling rclone outside this script is correct. Users with a different vault layout or remote name should run rclone manually outside the skill rather than try to subvert the script.

#### D.6.b. The flow

1. Print the planned source path and the target path the script will compute.
2. Ask: *"Sync this entry to Dropbox now?"*
3. On yes, run:
   ```
   <youtube-synthesizer scripts dir>/sync_to_dropbox.sh ~/ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>
   ```
   Block on completion; report success or the script's error message verbatim.
4. On no, print *"Skipped sync. Run later with: sync_to_dropbox.sh <absolute-entry-dir>"* so the user has the exact command if they change their mind.

---

## Previewing an entry

Entries use Obsidian's wikilink syntax (`![[image-NN.png]]`) which doesn't render in standard markdown viewers. The `scripts/preview.py` helper renders any entry to HTML and serves the entry directory over HTTP — useful on a headless box where you can't open Obsidian directly.

```
<youtube-synthesizer scripts dir>/preview.py <entry-dir> [--port 8765] [--bind 0.0.0.0]
```

Pass either an entry directory (containing exactly one `*.md` file plus `image-NN.png` siblings) or a `.md` file directly. The script writes a sibling `index.html` (kept under that name so the HTTP server's default route works) with wikilinks rewritten to `<img>` tags and YAML frontmatter shown as a collapsible block, then starts an HTTP server. Open `http://<host>:<port>/` in a browser.

Use `--no-serve` to render the HTML and exit without starting the server. Use `--bind 127.0.0.1` to restrict to localhost when working on a shared box.

The script is stdlib-only (no dependencies). It is generic over entries with this per-note folder structure.

---

## Discipline: faithful capture, no editorializing

Deliver what the video said and showed, structured and searchable. Do not reframe content for a use case, add interpretive headers, or editorialize the presenter's claims; weaving it into the user's mental model is downstream work. The TL;DR and takeaways attribute claims to the video implicitly through the entry's framing, not as undisputed fact. The only word changes allowed are the logged soft-corrects (C.7).

---

## Prerequisites

- `youtube-transcript` skill installed
- `youtube-screenshotter` skill installed (transitively requires `uv` and `ffmpeg`)
- Network access to YouTube
- A target Obsidian vault path (writable) — used by Phase D. Convention: `~/ObsidianVaults/<vault-name>/`.
- `rclone` (optional, only if using Phase D.6 Dropbox sync) with a `dropbox:` remote configured. Install via the system package manager or `https://rclone.org/install/`. Configure with `rclone config` and pick "Dropbox" — the remote name `dropbox` is what the skill expects by default. Skip this dep entirely if you always invoke with `--no-sync`.

## Failure modes

- **No transcript available** (no captions, foreign language) → error early with a clear message; stop
- **Video unavailable** (private, members-only, age-restricted, geo-blocked) → error early; stop
- **Live streams** → refuse (no fixed endpoint to sample over)
- **Entry already exists, no `--rerun`** → D.2
- **Short video or incomplete chapter coverage** → D.4.a, D.4.c
- **rclone missing or `dropbox:` remote unconfigured** → report the script's error verbatim, leave the local entry intact, suggest installing/configuring rclone or using `--no-sync`
