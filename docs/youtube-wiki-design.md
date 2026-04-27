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
2. **`youtube-screenshotter`** (new) — purely mechanical. Given a video URL + a list of timestamps, downloads the video (yt-dlp), extracts frames at those timestamps (ffmpeg), and computes perceptual hashes (pHash). Emits a manifest JSON with metadata + per-frame entries. **No LLM calls.** Generic over downstream use; doesn't know about wikis or Obsidian. Reusable for future tools.
3. **`youtube-synthesizer`** (new) — wiki-specific orchestrator. Runs as a Claude Code skill driven by the parent agent. Owns the bisection + diff-judgment loop (using the parent agent's native vision capability — no separate API calls), scene consolidation, structured extraction, and output writing.

The screenshotter is mechanical (download, extract, hash); the synthesizer is smart (everything that requires reasoning, including the same/different/additive verdict). This separation puts every LLM call on the user's existing Claude Code session — there's no separate `ANTHROPIC_API_KEY` and no double-billing.

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

The judging is split between a cheap mechanical pre-filter (in the screenshotter) and the parent Claude Code agent's reasoning (in the synthesizer). No separate API calls — the synthesizer is a Claude Code skill, so the agent that's already driving it does the visual judgment as part of its normal reasoning loop.

**pHash pre-filter (screenshotter side)** — perceptual-hash Hamming distance is computed for every extracted frame. The synthesizer reads these from the manifest:
- Very-low Hamming distance (≤ `SAME_MAX`, default 5) → declare `same` without further work
- Very-high Hamming distance (≥ `DIFFERENT_MIN`, default 20) → declare `different` without further work
- Ambiguous middle band → defer to the agent's visual judgment

In practice ~30–60% of pairs are resolvable from pHash alone (varies by video class — talking-head-heavy content has more ambiguous pairs because pHash can't tell "presenter moved" from "slide changed").

**Agent visual judgment (synthesizer side)** — for ambiguous pairs, the synthesizer's procedure (in its SKILL.md) instructs the parent Claude Code agent to open both frame images via the Read tool and decide the verdict using its native vision capability. Returns one of:

- `same` — no meaningful change
- `different` — new content / scene change
- `additive` — frame B contains everything in A plus more (slide animation, code being typed, equation revealed step-by-step)

**Bias toward false positives.** Calling `different` on actual-same wastes one frame in the wiki — cheap. Calling `same` on actual-different loses information forever — expensive. The SKILL.md instructs the agent to default to `different`/`additive` when uncertain.

**Why transcript context matters.** The agent should match expected change (from spoken content) against observed change (from images). If the speaker says "as you can see in this new diagram" between frames, expect `different`. If they say "and now we add the next term", expect `additive`. If they're continuing to talk on the same slide, expect `same`. Silent windows often correlate with `different` or `additive` — presenter pausing while showing something visual.

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

- All LLM judgment runs on the user's existing Claude Code session — no separate `ANTHROPIC_API_KEY`, no double-billing. Per-video LLM cost is whatever the parent agent's reasoning loop incurs on its normal tariff.
- 1hr lecture: ~600–1500 candidate frames after transcript-aligned sampling; ~30–60% resolved by pHash alone, leaving a few hundred ambiguous pairs that go to agent vision in batches
- yt-dlp download: ~few hundred MB for typical 1hr 720p video
- ffmpeg frame extraction: trivial
- Total runtime: ~few minutes to ~15 minutes per video on commodity hardware (dominated by download + agent reasoning turns)

## Phasing

**Phase 1 (this work):** transcript + screenshotter + synthesizer producing in-place wiki entries with embedded video frames. Test target: https://www.youtube.com/watch?v=MIqpvpNS5pI (Modern History TV grain-haul economics — visuals load-bearing on the central thesis).

**Phase 2:** nano-banana imagery regen for publishable / copyright-safe output. Each scene gets a `kind` classification; diagrams/charts route to nano-banana with the original frame's content described as the prompt source. Style consistency across regenerated images via multi-image style anchoring. Talking-head scenes drop imagery entirely; UI screenshots stay text-only (faithful regen too hard).

**Phase 3:** `youtube-comments` skill — yt-dlp `--write-comments`, then heuristic prefilter (length/junk patterns, keep all pinned + top-K + timestamp-referencing) → vision-LLM substantiveness judge → integration into the wiki (timestamp-referencing comments anchor to scenes, others go in a Discussion section).

**Phase 4+:** sqlite3 corpus indexer over `<vault>/sources/**/index.md` with FTS5; cross-source linker that resolves "References / Mentioned" plain-text into wikilinks when matching source notes exist; MOC auto-maintenance; parallel skills for blog posts, PDFs, Substack newsletters using the shared frontmatter base schema.

## Phase 1 work breakdown

See child issues under the epic. Ordered by dependency:

1. screenshotter: yt-dlp video download + metadata extraction *(ih2.1 — done)*
2. screenshotter: ffmpeg frame extraction + pHash pre-filter *(ih2.2 — done)*
3. ~~screenshotter: vision-LLM diff judge~~ *(ih2.3 — closed; relocated to ih2.11 in the synthesizer to avoid a separate API key + double-billing)*
4. screenshotter: unified extract CLI batching download + frames + pHash *(ih2.4)*
5. screenshotter: SKILL.md + CLI entrypoint *(ih2.5)*
6. synthesizer: bisection + LLM judgment loop using parent agent's vision *(ih2.11 — new)*
7. synthesizer: scene consolidation + frontmatter generation *(ih2.6)*
8. synthesizer: structured extraction (TL;DR, takeaways, references, code, tags) *(ih2.7)*
9. synthesizer: output writing (folder structure, image storage, hierarchical-vs-flat) *(ih2.8)*
10. synthesizer: SKILL.md + CLI entrypoint *(ih2.9)*
11. End-to-end validation on the grain-haul test video *(ih2.10)*
