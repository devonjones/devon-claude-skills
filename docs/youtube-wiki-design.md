# youtube-wiki design

Three-skill pipeline that turns YouTube videos (explainers, howtos, lectures) into searchable literature notes inside the user's Obsidian vaults. Designed as one source-type within a broader future ingestion system (blog posts, PDFs, Substack, etc. as parallel skills).

## Goal

Build a personal, searchable archive of practical-application videos. Each entry is a faithful capture of what the video communicated — transcript content + canonical visual moments + structured extraction (TL;DR, takeaways, references, code) — designed as raw material for the user's own synthesis layer downstream. The skill produces literature notes; the user produces the synthesis.

## Non-goals

- Auto-ingestion / browser triggers — manual invocation only
- Cross-vault topic routing — user names the target vault explicitly
- Polished essays / opinionated framing — outputs stay source-faithful so they're usable across multiple downstream synthesis directions
- Entertainment content — focus on practical/explainer/howto videos

## Architecture

Three composable skills, deliberately separated:

1. **`youtube-transcript`** (already shipped, unchanged) — extracts time-stamped text via `youtube-transcript-api`.
2. **`youtube-screenshotter`** (new) — given a video URL + a list of timestamps, returns frames. Owns video download (yt-dlp), frame extraction (ffmpeg), pHash diffing, vision-LLM diff judgment, and bisection sampling. Generic over downstream use; doesn't know about wikis or Obsidian. Reusable for future tools (video summarization, scene extraction).
3. **`youtube-synthesizer`** (new) — wiki-specific orchestrator. Given a video URL + target vault path, calls `youtube-transcript` and `youtube-screenshotter`, consolidates results into scenes, generates structured wiki entry, writes to vault.

The screenshotter is dumb (extracts and judges); the synthesizer is smart (orchestrates and writes). This separation lets each be tested and improved independently.

## Sampling & frame selection

### Transcript-driven sampling

Capture a frame at the start of each transcript snippet. The transcript already provides the natural anchoring — frames align to spoken context, which is exactly what the wiki output needs.

### Bisection triggers

Bisect any window where:
- **Visual diff trigger (primary)** — consecutive captured frames differ per the diff judge below. Slide transitions during continuous speech still get caught.
- **Silence trigger (precautionary)** — gap > N seconds (default 10s, tunable). Pauses correlate with visual change (presenter letting a diagram land).

Either trigger fires the same recursive bisection. Termination conditions:
- Window < 1s (minimum), OR
- Endpoints judged `same`, OR
- Endpoints judged `additive` *and* the build-up has reached its terminal frame (next forward frame is `same` or `different`)

### Hybrid diff judge

**pHash pre-filter** — cheap perceptual-hash comparison:
- Very-low Hamming distance → declare `same` without LLM call
- Very-high Hamming distance → declare `different` without LLM call
- Ambiguous middle band → vision LLM

Thresholds will need tuning per video class. Likely 60–80% of pairs decided by pHash alone.

**Vision LLM judge (Haiku 4.5)** — receives both frames + the transcript span between their timestamps as context. Returns one of:

- `same` — no meaningful change
- `different` — new content / scene change
- `additive` — frame B contains everything in A plus more (slide animation, code being typed, equation revealed step-by-step)

**Bias the prompt toward false positives.** Calling `different` on actual-same wastes one frame in the wiki — cheap. Calling `same` on actual-different loses information forever — expensive. Default to `different`/`additive` when uncertain.

**Why transcript context matters.** The model can match expected change (from spoken content) against observed change (from images). "If the spoken content suggests something visual should change and you don't see it, lean toward `same`; if the spoken content suggests build-up, lean toward `additive`." Dramatically improves accuracy over images-alone judging.

### Additive handling

When the judge returns `additive`, keep bisecting forward in time until the verdict becomes `same` (build-up settled) or `different` (new scene). The terminal frame is the canonical capture for that scene. Discard intermediate build-up frames — they're noise in the wiki.

### Per-scene canonical frame

Dedup runs of `same`/`additive` into single scenes. Each scene has:
- One canonical frame (PNG)
- The transcript span(s) it covered (start/end timestamps + text)
- Eventually (Phase 2): a `kind` classification (talking-head, diagram, code, ui-screenshot, etc.) for downstream rendering decisions

## Output: Obsidian literature notes

### Vault structure

Skills write into `<vault>/sources/videos/<ingested-date>-<sanitized-title>/`. The `sources/` parent makes the architectural concept explicit at the path level — vault root is the user's synthesis space, hands-off for skills. The source-type segment (`videos/`, future `articles/`, `pdfs/`, `substack/`) makes the future skill landscape uniform.

```
<vault>/
  sources/
    videos/
      2026-04-27-medieval-grain-economics/
        index.md
        scene-01.png
        scene-04.png
        ...
      2026-04-30-paul-sellers-dovetails/
        index.md
        ...
    articles/    (future)
    pdfs/        (future)
  (vault root: user's own synthesis — hands-off for skills)
```

### Filename convention

`<ingested-date>-<sanitized-title>/index.md` plus `scene-NN.png` siblings. Date prefix gives chronological sortability in the file browser. Per-note folders (vs shared `attachments/`) win on portability — each entry self-contains its assets.

### Frontmatter schema

Designed for the future sqlite3 indexer + cross-source uniformity. Strict key-value, no nested prose, predictable types. Narrative content goes in the body, never in frontmatter.

**Base schema (shared across future article/pdf/substack source-skills):**

```yaml
source_type: youtube         # or article, pdf, substack, ...
source_url: https://...
source_title: "..."
source_author: "..."         # channel for video, author for others
source_published_date: 2025-08-12
ingested_date: 2026-04-27    # when YOU processed it
tags: [dovetails, joinery]
topics: [...]
why_ingested: "optional, prompted at processing time"
```

**YouTube-specific extras:**

```yaml
video_id: MIqpvpNS5pI
channel: "Modern History TV"          # mirror of source_author for in-context clarity
channel_id: UCgkA20PopL90R7tnTQQwiSg  # stable handle, survives renames
playlist_id: null                      # null unless invoked via playlist URL
playlist_title: null                   # cheap series-proxy when present
duration_seconds: 1834
chapter_markers: [...]                 # if present
```

`channel_id` is the key for future "process all videos from this channel and cross-link them" runs — channels can rename themselves, IDs are stable. yt-dlp's `--dump-json` provides everything for free.

### Body structure

- **TL;DR** (1–2 sentences) — the highest-leverage section for re-discovery six months later
- **Key takeaways** (3–5 bullets)
- **Scene-by-scene narration** with embedded frames — hierarchical when chapter markers exist (chapter → scenes), flat otherwise. Auto-degrade to flat for very short videos (~3 min) regardless of chapter markers.
- **References / Mentioned** (people, papers, tools, other videos cited) — plain text in Phase 1, future linker upgrades to wikilinks once the cross-source corpus exists
- **Commands & Code** (for howto content) — extracted blocks duplicated at the end for quick reference

### Output discipline

Literature-note-shaped: faithful capture + light structural extraction. No editorializing, no pre-framing for downstream synthesis directions. The vault root is where the user weaves video content into their mental model — the skill must not bias that weaving by pre-deciding the framing.

No auto-generated wikilinks in Phase 1. Cross-references between video entries should emerge organically as the corpus grows; auto-linking on heuristic guesses tends to produce noise (links to nonexistent or wrong notes).

## Failure modes

- **No transcript available** (no captions, foreign language) — error early with clear message
- **Video unavailable** (private, members-only, age-restricted, geo-blocked) — error early
- **Live streams** (no fixed endpoint) — refuse for now
- **Re-running on already-processed video** — skip by default, `--rerun` flag to overwrite
- **Very short videos** (~3 min) — auto-degrade to flat structure regardless of chapter markers

## Cost & runtime estimates

- 1hr lecture: ~600–1500 vision-LLM judge calls before pHash filter; ~150–500 after
- Haiku 4.5 with two ~720p images per call + cached system prompt → cents to low single dollars per video
- yt-dlp download: ~few hundred MB for typical 1hr 720p video
- ffmpeg frame extraction: trivial
- Total runtime: ~few minutes to ~15 minutes per video on commodity hardware

## Phasing

**Phase 1 (this work):** transcript + screenshotter + synthesizer producing in-place wiki entries with embedded video frames. Test target: https://www.youtube.com/watch?v=MIqpvpNS5pI (Modern History TV grain-haul economics — visuals load-bearing on the central thesis).

**Phase 2:** nano-banana imagery regen for publishable / copyright-safe output. Each scene gets a `kind` classification; diagrams/charts route to nano-banana with the original frame's content described as the prompt source. Style consistency across regenerated images via multi-image style anchoring. Talking-head scenes drop imagery entirely; UI screenshots stay text-only (faithful regen too hard).

**Phase 3:** `youtube-comments` skill — yt-dlp `--write-comments`, then heuristic prefilter (length/junk patterns, keep all pinned + top-K + timestamp-referencing) → vision-LLM substantiveness judge → integration into the wiki (timestamp-referencing comments anchor to scenes, others go in a Discussion section).

**Phase 4+:** sqlite3 corpus indexer over `<vault>/sources/**/index.md` with FTS5; cross-source linker that resolves "References / Mentioned" plain-text into wikilinks when matching source notes exist; MOC auto-maintenance; parallel skills for blog posts, PDFs, Substack newsletters using the shared frontmatter base schema.

## Phase 1 work breakdown

See child issues under the epic. Ordered by dependency:

1. screenshotter: yt-dlp video download + metadata extraction
2. screenshotter: ffmpeg frame extraction at given timestamps + pHash hybrid pre-filter
3. screenshotter: vision-LLM diff judge (same/different/additive with transcript context)
4. screenshotter: transcript-aligned bisection sampling pipeline
5. screenshotter: SKILL.md + CLI entrypoint
6. synthesizer: scene consolidation + frontmatter generation
7. synthesizer: structured extraction (TL;DR, takeaways, references, code, tags)
8. synthesizer: output writing (folder structure, image storage, hierarchical-vs-flat)
9. synthesizer: SKILL.md + CLI entrypoint
10. End-to-end validation on the grain-haul test video
