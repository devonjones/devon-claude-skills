# Phases B and C: frontmatter and structured extraction

Contents:
- Phase B: Frontmatter (B.1)
- Phase C: Structured extraction (C.1 TL;DR, C.2 Key takeaways, C.3 Description check, C.4 References, C.5 Commands & Code, C.6 Tags + topics, C.7 Auto-caption soft-correct, C.8 Output)

## Phase B — Frontmatter

This phase assembles the YAML frontmatter from the screenshotter's metadata block.

### B.1. Generate the frontmatter dictionary

The frontmatter has two parts: a base schema shared with other source-skills, and YouTube-specific extras alongside.

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
chapter_markers:                       # omit when metadata has none (empty or null)
  - title: "..."
    start_time: 0.0
    end_time: 153.0
transcript_corrections: []  # populated by Phase C / Phase D as soft-corrects are applied
```

`transcript_corrections` is a list of `{original, corrected, timestamp}` entries logging every soft-correct the synthesizer applied to the auto-caption text. Empty list if no corrections were applied.

**Frontmatter discipline:** strict key-value, no narrative prose. Structured data (lists of objects) is fine — `chapter_markers` and `transcript_corrections` are both lists of dicts. Narrative content goes in the body, never in frontmatter.

---

## Phase C — Structured extraction

Produces the body sections of the entry plus the `tags` / `topics` frontmatter and the `transcript_corrections` log. Source-faithful: extract what the video communicated; do not interpret or synthesize. Use the transcript text, the video description, and (for Commands & Code) what's visible in kept frames.

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

**Do not auto-generate wikilinks** to other entries.

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
- **`tags`** — finer-grained markers (e.g. `grain-supply`, `oxen`, `radius-of-effect`, `dovetails`, `unit-tests`). 3–8 entries.

Both lists must be kebab-case strings, no spaces, no special characters. Do not invent vague tags (`interesting`, `useful`); every entry should map to a concrete subject.

### C.7. Auto-caption soft-correct policy

YouTube's auto-captioner produces transcription errors that propagate verbatim into the entry under a strict "do not change words" rule. Examples: *"kills for measurement"* (meant *"scales for measurement"* — homophone misread). This breaks full-text search and produces gibberish in the prose.

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

The timestamp is the transcript-snippet timestamp where the original word appears.

### C.8. Output of Phase C

You now hold:

- A TL;DR string (validated against `source_description`)
- A key-takeaways bullet list
- A references list (description-driven, filtered, with URLs)
- A commands-and-code block list (or empty)
- Populated `tags` and `topics` arrays for the frontmatter
- A `transcript_corrections` list of soft-corrects applied (so far — Phase D applies more during prose composition and appends to this list)

These are consumed by Phase D (output writing).
