# youtube-wiki design

Three-skill pipeline that turns YouTube videos (explainers, howtos, lectures) into searchable literature notes inside the user's Obsidian vaults. Designed as one source-type within a broader future ingestion system (blog posts, PDFs, Substack, etc. as parallel skills).

> **Status (2026-04-28):** Phase 1 shipped under PR #11 against the `youtube-wiki` branch. End-to-end validation on the grain-haul test video surfaced four structural flaws in the synthesizer's Phase A (image selection) and Phase D (output writing) that this doc has been rewritten to address. The "Phase 1.5 rework" section below tracks the corrections; the SKILL.md in `plugins/youtube-synthesizer/skills/youtube-synthesizer/SKILL.md` still reflects the original (flawed) design and is being rewritten as part of the rework.

## Goal

Build a personal, searchable archive of practical-application videos. Each entry is a faithful capture of what the video communicated — transcript content + load-bearing visuals + structured extraction (TL;DR, takeaways, references, code) — designed as raw material for the user's own synthesis layer downstream. The skill produces literature notes; the user produces the synthesis.

## Non-goals

- Auto-ingestion / browser triggers — manual invocation only
- Cross-vault topic routing — user names the target vault explicitly
- Polished essays / opinionated framing — outputs stay source-faithful so they're usable across multiple downstream synthesis directions
- Entertainment content — focus on practical/explainer/howto videos

## Architecture

Three composable skills, deliberately separated:

1. **`youtube-transcript`** (already shipped, unchanged) — extracts time-stamped text via `youtube-transcript-api`.
2. **`youtube-screenshotter`** (Phase 1 shipped) — purely mechanical. Given a video URL + a list of timestamps, downloads the video (yt-dlp), extracts frames at those timestamps (ffmpeg), and computes perceptual hashes (pHash). Emits a manifest JSON with metadata + per-frame entries. **No LLM calls.** Generic over downstream use; doesn't know about wikis or Obsidian. Reusable for future tools.
3. **`youtube-synthesizer`** (Phase 1 shipped, Phase 1.5 rework in flight) — wiki-specific orchestrator. Runs as a Claude Code skill driven by the parent agent. Owns the sampling-and-classification loop (using the parent agent's native vision capability — no separate API calls), structured extraction, and output writing.

The screenshotter is mechanical (download, extract, hash); the synthesizer is smart (everything that requires reasoning, including the value classification of each candidate frame). This separation puts every LLM call on the user's existing Claude Code session — there's no separate `ANTHROPIC_API_KEY` and no double-billing.

---

## The value-filter principle (replaces "scene boundary" sampling)

> **Images appear in the wiki entry only when they communicate something the transcript words don't, or when they help explain the narrative — even if that means several in a row.**

The original design treated visual change as the trigger for capturing a scene: every place pHash flagged a meaningful pixel diff became a `scene` with one canonical frame embedded in the body. The Phase 1 e2e on the grain-haul test video (`MIqpvpNS5pI`) showed why this fails:

- 19 captured "scenes," of which **7 were straight talking-head shots** (presenter's face, no overlay), **5 were title / pull-quote text cards** (text duplicating what the transcript already said), **1 was a blank transition frame** between content, leaving **only ~6 actually informational images** (diagrams, maps, illustrations of the four lord types).
- An animated build-up (the bulk→value wheat-bundle conversion) was reduced to a single terminal frame, throwing away the explanatory sequence.
- Wiki output ended up ~70% noise around the 30% load-bearing visuals.

The replacement: **classify every candidate frame by KIND, then keep frames that carry information beyond the transcript.**

### Frame kinds

For each candidate frame, the agent classifies as exactly one of:

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

### Sampling strategy (replaces bisection-on-visual-diff)

1. **Initial sample at transcript-snippet boundaries + chapter starts + `t=0.5`.** Same as before; this gives the candidate set.
2. **Classify every candidate frame.** Drop the noise kinds; tag each keeper with its kind.
3. **Bisect the GAPS between consecutive keepers.** If two informational frames are more than ~15s apart and the intervening transcript suggests visual content (the speaker says "as you can see," "let me show you," "here's the diagram"), sample at the midpoint to find missed informational frames. The trigger flips: **bisect when there's a gap that might contain a missed diagram**, not when consecutive frames look different.
4. **Inside an animated build-up, keep all the steps.** When the agent classifies a frame as `animated-build-step`, sample more densely (every 2–3s) within that window until the kind transitions to something else. Each step survives in the output if it adds information.
5. **Output: an ordered list of `(timestamp, frame_path, kind)` triples** for the kept frames. This is not "scenes covering the whole video" — it's "informational moments and where they appear." Number of images per video is whatever the source has of substance: 0 in a pure-talking-head section, 4-in-a-row during an animated diagram explanation.

### pHash's role shrinks

pHash is no longer the primary sampling signal. It's a cheap **deduplication** check after kind classification: if two consecutive keep-frames have near-identical pHash (Hamming ≤ 5), they're the same image — drop one. Otherwise the pHash result is informational only.

The screenshotter still computes pHash for every extracted frame (that work is cheap and the hash is useful for dedup); the synthesizer still reads it; but the same/different/additive verdict scheme is replaced by the kind-classification scheme above.

---

## Output: Obsidian literature notes

### Vault structure

Skills write into `<vault>/sources/videos/<ingested-date>-<sanitized-title>/`. The `sources/` parent makes the architectural concept explicit at the path level — vault root is the user's synthesis space, hands-off for skills. The source-type segment (`videos/`, future `articles/`, `pdfs/`, `substack/`) makes the future skill landscape uniform.

```
<vault>/
  sources/
    videos/
      2026-04-27-the-ox-thats-breaking-your-fantasy-map/
        index.md
        image-01.png
        image-02.png
        ...
    articles/    (future)
    pdfs/        (future)
  (vault root: user's own synthesis — hands-off for skills)
```

### Filename convention

`<ingested-date>-<sanitized-title>/index.md` plus `image-NN.png` siblings. Date prefix gives chronological sortability. Per-note folders win on portability — each entry self-contains its assets. Filename was previously `scene-NN.png`; renamed because the "scene" abstraction has been dropped (see value-filter principle above).

**Title sanitization:** lowercase → strip anything not in `[a-z0-9]` (apostrophes vanish, not replaced with hyphens — produces `thats` not `that-s`) → collapse repeated whitespace into single hyphens → trim leading/trailing hyphens → truncate at 80 characters.

### Frontmatter schema

Designed for the future sqlite3 indexer + cross-source uniformity. Strict key-value, no narrative prose; structured data (lists of objects) is fine. Narrative content goes in the body, never in frontmatter.

**Base schema (shared across future article/pdf/substack source-skills):**

```yaml
source_type: youtube
source_url: https://...
source_title: "..."
source_author: "..."             # channel for video, author for others
source_published_date: 2025-08-12
source_description: |            # NEW (Phase 1.5) — verbatim author-written
  ...                            #   description from the source. Acts as
                                 #   ground truth for hallucination check.
ingested_date: 2026-04-27
tags: [dovetails, joinery]
topics: [...]
why_ingested: "optional, prompted at processing time"
```

**YouTube-specific extras:**

```yaml
video_id: MIqpvpNS5pI
channel: "The Grainbound"             # mirror of source_author for in-context clarity
channel_id: UCSeuqv9fNSUJT5VfcmslTBg  # stable handle, survives renames
playlist_id: null                      # null unless invoked via playlist URL
playlist_title: null                   # cheap series-proxy when present
duration_seconds: 1119
chapter_markers: [...]                 # if present
```

`channel_id` is the key for future "process all videos from this channel and cross-link them" runs — channels can rename themselves, IDs are stable. yt-dlp's `--dump-json` provides everything for free.

### Body structure (option D — decoupled prose flow)

Replaces the original per-scene heading hierarchy. The original Phase 1 design produced:

```
## Scenes
### Chapter Title
#### Scene 1 — 00:05 to 00:30
![[scene-01.png]]
<transcript span 00:05–00:30, including any partial sentence>
#### Scene 2 — 00:30 to 01:00
...
```

This split clauses mid-sentence at scene boundaries (e.g. *"...use the map and work" / "along. I will not show…"*). The replacement drops scene-level headings entirely and renders chapter-level prose with images embedded inline:

```
## TL;DR
<1-2 sentences>

## Key takeaways
- ...

## <Chapter 1 title from chapter_markers>

<sentence-aware reflow of the full transcript span for this chapter,
broken into paragraphs at sentence boundaries>

![[image-01.png]]

<more reflowed prose>

![[image-02.png]]

<more reflowed prose, etc.>

## <Chapter 2 title>

<reflowed prose>

...

## References

<filtered URLs from the description, with annotations>
```

**Rules for the chapter-level prose:**

- **One section per chapter** from `chapter_markers`. **Use the author's chapter titles verbatim** — including placeholders like "Chapter 2" or "Chapter 3." The chapter structure is the author's deliberate framing of the video; the synthesizer respects it even when titles are pro-forma. Do not synthesize "better" chapter titles from content.
- **Sentence-aware reflow.** Concatenate transcript snippets within each chapter's `[start_time, end_time)` span. Break into paragraphs at sentence terminators (`. `, `! `, `? `) at natural-feeling points (every ~3-6 sentences). Words verbatim — do not paraphrase or summarize.
- **Embed informational images inline at their timestamps.** When a kept frame's timestamp falls within a chapter, inject the `![[image-NN.png]]` line at the nearest sentence boundary to that timestamp. Multiple images in close succession (e.g. an animated build-up sequence) appear consecutively, separated by their corresponding prose if any falls between them.
- **No video has scene-level headings.** Scenes are gone. Sections are `## TL;DR`, `## Key takeaways`, `## <chapter title>` (one per chapter), `## References`, `## Commands & Code` (omitted if empty).
- **Very short videos** (≤ 3 minutes or no `chapter_markers`): omit chapter sections, render the entire transcript as one prose flow under a `## Body` heading (or similar — open). Decision deferred to implementation.

### Description-driven references

The original Phase 1 emitted references as vague prose ("the presenter's Discord and website") with no actual URLs. Phase 1.5 pulls the real URLs from yt-dlp's video description and filters them.

**Where references come from (in priority order):**

1. **URLs in the video description** (`info["description"]` from yt-dlp). Most cited resources live here.
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
## References

- [The Grainbound resources page](https://thegrainbound.com/resources/) — host of the worksheet and practice map referenced in chapter 4.
- [The Grainbound Discord](https://discord.gg/PTnt72aj8B) — community where the worksheet+map are pinned.
- A separate video on vassal/loyalty systems — referenced at workflow step 7 (no URL provided in description).
```

No auto-generated wikilinks in Phase 1. Cross-references between video entries should emerge organically as the corpus grows; auto-linking on heuristic guesses tends to produce noise. The future Phase 4 sqlite3-backed cross-source linker resolves names to wikilinks once matching `sources/` entries exist.

### Description as hallucination check

The video description's "ABOUT THIS VIDEO" prose (when present) is the author's own structured summary. Use it as a check on the synthesizer's TL;DR / takeaways:

- **Compare** the synthesizer-generated TL;DR against the description prose. If the TL;DR introduces framing or claims that aren't grounded in either the transcript or the description, the agent has drifted — re-do the TL;DR.
- **Store** the full description verbatim in `source_description` frontmatter for searchable reference (and for future re-checks if the synthesizer is re-run with an updated SKILL.md).

The description is **not** rendered in the body — it would duplicate TL;DR / takeaways. It lives in frontmatter only.

### Auto-caption soft-correct policy

YouTube's auto-captioner produces transcription errors that the original "do not change words" discipline propagates verbatim into the wiki entry. Example from the e2e: *"kills for measurement"* (should be *"scales for measurement"* — a homophone misread). This breaks future full-text search ("scales" matches no results) and produces gibberish in the rendered prose.

**Policy (Phase 1.5 amendment to "no editorializing"):**

- **Soft-correct obvious auto-caption mis-transcriptions** when the intended word is unambiguous from immediate context. Categories: homophones (kills↔scales, their↔there, write↔right), garbled compound words, dropped articles where the sentence is otherwise grammatical.
- **Do not paraphrase, summarize, or restructure.** The principle of source-faithfulness applies to *what the presenter intended to say*. A clear mis-transcription is not what the presenter said.
- **Bias toward leaving alone.** When the intended word is genuinely ambiguous or the agent isn't confident, leave the caption text verbatim. Better to have one piece of garbled text than to invent the wrong word.
- **Document corrections in a `transcript_corrections` frontmatter field** (a list of `{original: "kills", corrected: "scales", timestamp: 320}` entries) so corrections are auditable and the original-as-captured is retrievable. This also lets a future linter spot systematic captioner failures across the corpus.

### Output discipline

Literature-note-shaped: faithful capture + light structural extraction. No editorializing, no pre-framing for downstream synthesis directions. The vault root is where the user weaves video content into their mental model — the skill must not bias that weaving by pre-deciding the framing.

The agent's voice should not blend with the presenter's voice. The synthesizer-generated TL;DR and takeaways describe the video's claims — they should *attribute* claims to the video implicitly through the document's framing (an entry in `sources/videos/` is by definition a record of what the source said) rather than asserting claims as undisputed facts.

---

## Failure modes

- **No transcript available** (no captions, foreign language) — error early with a clear message
- **Video unavailable** (private, members-only, age-restricted, geo-blocked) — error early
- **Live streams** (no fixed endpoint) — refuse for now
- **Re-running on already-processed video** — skip by default, `--rerun` flag to overwrite
- **Very short videos** (~3 min) — no chapter sections; render the whole transcript as one prose flow

## Cost & runtime estimates

- All LLM judgment runs on the user's existing Claude Code session — no separate `ANTHROPIC_API_KEY`, no double-billing. Per-video LLM cost is whatever the parent agent's reasoning loop incurs on its normal tariff.
- 1hr lecture: classification work scales with the number of candidate frames after pHash dedup, typically a few hundred. Most are fast-classified as `talking-head` (drop). Only the keep-set (typically 10–40 informational frames per hour) gets careful attention from the agent.
- yt-dlp download: ~few hundred MB for typical 1hr 720p video
- ffmpeg frame extraction: trivial
- Total runtime: ~few minutes to ~15 minutes per video on commodity hardware (dominated by download + agent reasoning turns)

---

## Phasing

**Phase 1 (shipped, with known flaws):** transcript + screenshotter + synthesizer producing in-place wiki entries with embedded video frames. Lives on PR #11 (`youtube-wiki` branch). Test target: `https://www.youtube.com/watch?v=MIqpvpNS5pI` ("The Ox That's Breaking Your Fantasy Map," The Grainbound, grain-haul economics).

**Phase 1.5 (this rework):** address the four structural flaws found in the Phase 1 e2e — value-filter image selection, decoupled chapter-level prose flow, description-driven references with URL filtering, auto-caption soft-correct policy. Re-validate against the same test video; expected outcome ~6 informational images instead of 19, no mid-sentence cuts, real URLs in references.

**Phase 2:** nano-banana imagery regen for publishable / copyright-safe output. Each kept image's `kind` (already classified in Phase 1.5) routes the regen: `diagram`/`map`/`chart` → nano-banana with the original described as prompt source; `code`/`ui` → text-only or stylized illustration; `b-roll` → omit or describe in prose. Style consistency across regenerated images via multi-image style anchoring.

**Phase 3:** `youtube-comments` skill — yt-dlp `--write-comments`, then heuristic prefilter (length/junk patterns, keep all pinned + top-K + timestamp-referencing) → vision-LLM substantiveness judge → integration into the wiki (timestamp-referencing comments anchor to nearby chapter sections, others go in a Discussion section).

**Phase 4+:** sqlite3 corpus indexer over `<vault>/sources/**/index.md` with FTS5; cross-source linker that resolves "References / Mentioned" plain-text into wikilinks when matching source notes exist; MOC auto-maintenance; parallel skills for blog posts, PDFs, Substack newsletters using the shared frontmatter base schema.

---

## Phase 1 work breakdown (closed)

See child issues under epic `devon-claude-skills-ih2` (closed). Ordered by dependency; all closed:

1. screenshotter: yt-dlp video download + metadata extraction *(ih2.1)*
2. screenshotter: ffmpeg frame extraction + pHash pre-filter *(ih2.2)*
3. ~~screenshotter: vision-LLM diff judge~~ *(ih2.3 — closed; relocated to ih2.11 to avoid double-billing)*
4. screenshotter: unified extract CLI batching download + frames + pHash *(ih2.4)*
5. screenshotter: SKILL.md + CLI entrypoint *(ih2.5)*
6. synthesizer: bisection + LLM judgment loop using parent agent's vision *(ih2.11)*
7. synthesizer: scene consolidation + frontmatter generation *(ih2.6)*
8. synthesizer: structured extraction (TL;DR, takeaways, references, code, tags) *(ih2.7)*
9. synthesizer: output writing (folder structure, image storage, hierarchical-vs-flat) *(ih2.8)*
10. synthesizer: SKILL.md + CLI entrypoint *(ih2.9)*
11. End-to-end validation on the grain-haul test video *(ih2.10 — surfaced the four structural flaws)*

## Phase 1.5 work breakdown (in flight)

A new epic captures the rework. The synthesizer SKILL.md will be substantially rewritten (Phases A and D); the screenshotter is unchanged. Target deliverables:

1. Replace synthesizer Phase A: drop pHash-driven scene-boundary detection, adopt value-filter sampling that classifies frames by `kind` (talking-head / blank / title-card / pull-quote-card → drop; diagram / map / chart / code / ui / b-roll / animated-build-step / hybrid-with-info-overlay → keep). Bisect the gaps between consecutive keepers; keep all animated-build-steps. Output: ordered `(timestamp, frame_path, kind)` triples.
2. Drop synthesizer Phase B (scene consolidation) — there are no scenes to consolidate. The keep-list passes directly to Phase C / Phase D.
3. Extend synthesizer Phase C: in addition to TL;DR / takeaways / tags / topics, **pull the video description**, **filter URLs** by the keep/drop table above, and emit references with actual URLs and one-line annotations. Compare the agent-generated TL;DR against the description's "ABOUT THIS VIDEO" prose as a hallucination check.
4. Replace synthesizer Phase D: chapter-level prose flow with sentence-aware reflow, images embedded inline at their timestamps. **Use the author's chapter titles verbatim** including placeholders. No scene-level headings. Apply the auto-caption soft-correct policy (homophones, garbled compound words; document corrections in frontmatter `transcript_corrections`).
5. Update the frontmatter schema: add `source_description` (verbatim author description) and `transcript_corrections` (list of `{original, corrected, timestamp}`). Image filename convention changes from `scene-NN.png` to `image-NN.png`.
6. Re-validate against `MIqpvpNS5pI`. Expected: ~6 informational images instead of 19; one continuous chapter-level prose flow per chapter; references list contains the actual `thegrainbound.com` and Discord URLs from the description; "kills for measurement" → "scales for measurement" with the correction logged in frontmatter.
