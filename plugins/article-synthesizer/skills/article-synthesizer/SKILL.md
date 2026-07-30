---
name: article-synthesizer
description: Turn a web article into a faithful-capture literature note in an Obsidian vault. Use when the user wants to ingest a web page (blog post, essay, technical article, documentation page) into their personal source notes corpus. Fetches the page, extracts structured content (TL;DR, takeaways, faithful body prose, references). The article sibling of youtube-synthesizer — same vault conventions, same frontmatter base schema, no frame pipeline.
---

# Article Synthesizer

Produces an Obsidian literature note from a web article. The web-page sibling of `youtube-synthesizer`: same vault layout, same shared frontmatter base schema (so the future sqlite3 indexer joins on a single contract), same faithful-capture discipline. Deliberately simpler — no frames, no ffmpeg, no sub-agents. Fetch the page, extract its substance, write the note.

You — the agent running this skill — do the extraction inline as you follow the procedure below. The skill produces faithful capture of the source; downstream synthesis into the user's mental model is their job, not yours.

## Invocation

Required inputs from the user:

- **`<URL>`** — the article's URL

Optional:

- **`<vault>`** — absolute path to the target Obsidian vault, **or** a vault name relative to `~/ObsidianVaults/`. The skill writes to `<vault>/sources/articles/<sanitized-domain>/<ingested-date>-<sanitized-title>/`. If omitted, see Phase D.1 for the discovery flow.
- **`--rerun`** — overwrite an existing entry at the target path. Without this flag, the skill refuses to overwrite (Phase D.2).
- **`--why <reason>`** — populate the `why_ingested` frontmatter field. If omitted, leave it as an empty string; the user can fill it in after.
- **`--no-sync`** — accepted for parity with `youtube-synthesizer`, but currently a no-op: Dropbox sync is out of scope for v1 (see Phase D.5), so `--no-sync` is effectively always on.

If `<URL>` is missing, ask the user before starting work — do not guess. `<vault>` resolution is described in Phase D.1; do not guess that either.

## Output

A single Obsidian literature note at `<vault>/sources/articles/<sanitized-domain>/<ingested-date>-<sanitized-title>/` containing:

- `<sanitized-title>.md` — frontmatter + body (TL;DR, key takeaways, faithful-capture prose, references). Same `<sanitized-title>` as the parent directory's title segment, without the date prefix (the directory carries the date already).

Grouping by domain keeps a site's articles together — opening `<vault>/sources/articles/martinfowler-com/` shows every entry from that site side-by-side. This mirrors `youtube-synthesizer`'s channel grouping.

**Scope boundary — images:** article images are linked at their remote URLs, never downloaded. There is no image pipeline in v1; the entry directory contains only the `.md` file. If an image is load-bearing, its remote link plus the surrounding prose carries the information.

---

## Phase A — Fetch and validate

Produces the page's readable content plus its head metadata. **Never fabricate content for a page you could not fetch — error early and stop.**

### A.1. Primary fetch: WebFetch

Fetch `<URL>` with the WebFetch tool, prompting for the full article content — title, byline, publication date, body text with section headings preserved, code blocks, and outbound links. Record `fetched_via: webfetch`.

### A.2. Fallback fetch: curl

If WebFetch is unavailable in the session, errors out, or returns content that is obviously truncated or boilerplate-only, fall back to fetching the raw HTML:

```
curl -sL "<URL>" -o <work_dir>/page.html
```

Read the HTML directly and extract the article content and head metadata yourself. Record `fetched_via: curl`.

### A.3. Validate what came back

Before any extraction, check the fetched content against the failure modes. All of these are hard stops — report the reason and exit; do not synthesize a note from fragments:

- **404 / gone / DNS failure** — the page doesn't exist. Stop.
- **Paywall** — the fetch returned a teaser plus a subscription prompt instead of the article. Stop; tell the user the page is paywalled.
- **Login wall** — the fetch returned a sign-in page. Stop; tell the user the page requires authentication.
- **Non-HTML content type** — a PDF, image, or other binary. Refuse: PDFs belong to a future `pdf-synthesizer` skill, not this one. Stop and say so.
- **JS-only SPA** — the HTML shell contains no article text (empty `<div id="root">`, "enable JavaScript" notices). Try the curl fallback if you haven't already; if the content still isn't in the HTML, fail honestly — this skill does not run a browser.

The test for "did I get the article": the fetched text contains the article's actual prose, not just navigation, teasers, or metadata. When in doubt, compare against the title and meta description — if the body doesn't deliver what they promise, treat it as a failed fetch.

### A.4. Extract head metadata

From the fetched page, collect:

- **Title** — `og:title`, `<title>`, or the page's `<h1>` (prefer the most article-specific; `<title>` often carries site-name suffixes like " | Martin Fowler" — strip them).
- **Author** — byline, `author` meta tag, or structured data. `null` if not discoverable; do not guess.
- **Published date** — `article:published_time`, visible dateline, or structured data, normalized to `YYYY-MM-DD`. `null` if not discoverable.
- **Meta description** — `og:description` or `<meta name="description">`, verbatim. Empty string if absent.
- **Site name** — `og:site_name`, or the bare domain if absent.
- **Canonical URL** — `<link rel="canonical">`, kept only when it differs from `<URL>`.

---

## Phase B — Frontmatter

The frontmatter has two parts: the base schema shared with `youtube-synthesizer` and future pdf/substack source-skills (so the future sqlite3 indexer joins on a single contract), and article-specific extras alongside.

**Base schema:**

```yaml
source_type: article
source_url: <URL as invoked>
source_title: <title from A.4>
source_author: <author from A.4, or null>
source_published_date: <date from A.4 as YYYY-MM-DD, or null>
source_description: |
  <meta description verbatim from A.4. Block-scalar YAML so multi-line is
  fine. Leave empty string if the page has no description.>
ingested_date: <today's date in YYYY-MM-DD>
tags: []           # populated by Phase C
topics: []         # populated by Phase C
why_ingested: ""   # optional; from --why flag at invocation time
```

`source_description` is the verbatim publisher-written description. It is **not** rendered in the body — it would duplicate TL;DR / takeaways. It lives in frontmatter only, as a hallucination check (Phase C.3) and a searchable reference.

**Article-specific extras** (alongside the base, not nested):

```yaml
site_name: <from A.4>
fetched_via: webfetch          # webfetch | curl
word_count: <approximate word count of the captured body prose>
canonical_url: <from A.4>      # include ONLY when it differs from source_url; omit otherwise
```

**Frontmatter discipline:** strict key-value, no narrative prose. Narrative content goes in the body, never in frontmatter.

---

## Phase C — Structured extraction

Produces the body sections plus the `tags` / `topics` frontmatter. Source-faithful: extract what the article communicated; do not interpret or synthesize.

### C.1. TL;DR

1–2 sentences capturing the article's central claim or thesis. The highest-leverage section for re-discovery six months later.

Source: the article text primarily. Look for explicit thesis statements (often in the opening paragraphs and the conclusion), plus the title and meta description.

Avoid: editorializing ("an interesting take on..."), interpretation ("the article argues that... but..."), framing for any particular use case.

### C.2. Key takeaways

3–5 bullets, each a single sentence, capturing the points the article makes that the user will want to remember.

A takeaway is a substantive claim the author makes — not a section header. Avoid meta-statements about the article itself, restating the title, or padding the list to hit a count (3 strong bullets beat 5 weak ones).

### C.3. Hallucination check via meta description

Before finalizing the TL;DR and key takeaways, compare them against the verbatim meta description (`source_description` from Phase B). If the agent-generated TL;DR introduces framing or claims that aren't grounded in **either** the article text **or** the description, the agent has drifted — re-do the TL;DR. This is a check, not a copy; do not paste the description into the TL;DR.

### C.4. References from outbound links

Pull the references list from the article's outbound links — the links the author actually placed in the prose (and any explicit "further reading" section), not the site's chrome.

**Link classification** (kept vs dropped):

| Keep | Drop |
|---|---|
| Cited papers, articles, books | Site navigation / header / footer links |
| Project / tool homepages that the article discusses | Share buttons, social media handles |
| GitHub / source code | Newsletter signups / subscribe CTAs (unless the newsletter is itself the cited source) |
| Standalone documentation links | Ads, sponsor links, affiliate links |
| The author's related posts, when the prose points at them | Same-site tag / category / archive pages |
| Community spaces (Discord, forum) **only when the article points at specific topical content there** | Comment-section and login links |

**Output format:** one bullet per kept reference, with the actual URL and a one-line annotation noting why it was cited:

```markdown
- [CRDT primer](https://crdt.tech/) — the introduction the author recommends before reading the implementation section.
- [example-repo on GitHub](https://github.com/example/example-repo) — the reference implementation the article walks through.
```

Omit the section entirely if no links survive the filter. Do not fabricate URLs for works the article names without linking — emit those as plain text.

**Avoid auto-generated wikilinks at this skill version.** Cross-references between entries should emerge organically as the corpus grows; a future cross-source linker (sqlite3-backed) will resolve names to wikilinks once matching `sources/` entries exist.

### C.5. Tags + topics

Populate the frontmatter `tags` and `topics` fields:

- **`topics`** — broad subject categories (e.g. `distributed-systems`, `woodworking`, `economics`, `python`). 1–4 entries. Match the user's existing vocabulary if you can see prior entries in the same vault.
- **`tags`** — finer-grained markers (e.g. `crdt`, `conflict-resolution`, `dovetails`, `unit-tests`). 3–8 entries. These power the future sqlite3 FTS index more than topics do.

Both lists must be kebab-case strings, no spaces, no special characters. Do not invent vague tags (`interesting`, `useful`); every entry should map to a concrete subject.

---

## Phase D — Output writing

### D.1. Resolve the entry path

#### D.1.a. Resolve `<vault>` if not supplied

The convention is that the user keeps Obsidian vaults under `~/ObsidianVaults/<vault-name>/`.

If `<vault>` was supplied at invocation:

- If it's an absolute path, use it directly.
- If it's a bare name (no `/`), resolve to `~/ObsidianVaults/<name>/`.

If `<vault>` was *not* supplied (interactive use only — in headless mode a missing vault is a `DRAIN-FAILED`, see Headless invocation):

1. `ls ~/ObsidianVaults/` and present the list. Ask the user to pick one.
2. If `~/ObsidianVaults/` doesn't exist or is empty, ask the user for an absolute vault path.

#### D.1.b. Compose the entry directory

Given the resolved `<vault>`, the article's domain, and the title from A.4:

1. **Sanitize the title:** lowercase → strip anything not in `[a-z0-9 ]` (apostrophes vanish — produces `thats` not `that-s`; quotes, colons, em-dashes, ampersands all disappear) → collapse whitespace runs into single hyphens → trim leading/trailing hyphens → truncate at 80 characters.
2. **Sanitize the domain:** take the URL's hostname, strip a leading `www.`, map dots to spaces, then apply the same rule as step 1 (e.g. `www.martinfowler.com` → `martinfowler-com`).
3. Today's date in `YYYY-MM-DD` format (this is `ingested_date`).
4. Compose the entry directory: `<vault>/sources/articles/<sanitized_domain>/<ingested_date>-<sanitized_title>/`

Example: `~/ObsidianVaults/Programming/sources/articles/martinfowler-com/2026-07-29-patterns-of-distributed-systems/`

The domain directory is created on-demand if it doesn't exist yet.

### D.2. Skip-or-overwrite check

If the entry directory already exists and the user did not pass `--rerun`:

- Print a clear message: *"Entry already exists at `<path>`. Pass --rerun to overwrite."*
- Stop. Do not modify existing content.

If `--rerun`, remove the existing directory's contents before writing (preserve nothing — full regeneration).

### D.3. Compose the body — faithful-capture prose

The body after TL;DR and key takeaways is the article's substance, captured faithfully:

- **Preserve the article's own section headings** when present, as `##` sections in source order. The heading structure is the author's deliberate framing; do not synthesize "better" headings. If the article has no headings, render the prose under a single `## Body` heading.
- **Reflow into readable paragraphs.** Web articles often arrive as fragmented one-line paragraphs or run-on extraction text; reflow at sentence boundaries into ~3–6 sentence paragraphs. Do not paraphrase, summarize, or restructure — capture what the article said in prose that tracks the source closely, in attribution-implicit voice (an entry in `sources/articles/` is by definition a record of what the source said).
- **Code blocks verbatim, with language tags.** For technical articles, every code block is captured exactly as written, fenced with the correct language tag. Do not "fix" the author's code.
- **Images: link, don't download.** Where an image is load-bearing, embed its remote URL as a standard markdown image (`![<alt or one-line description>](https://...)`) at its position in the prose. No local copies — see the scope boundary in Output.

Top-level skeleton:

```markdown
---
<frontmatter from Phase B / C, YAML>
---

# <source_title>

**Source:** [<source_url>](<source_url>) — <site_name><, author when known><, published date when known>

## TL;DR

<TL;DR string from Phase C.1>

## Key takeaways

- <bullet 1>
- <bullet 2>
- ...

## <Article section heading 1>

<reflowed faithful-capture prose, with code blocks and remote image links inline>

## <Article section heading 2>

...

## References

<list from Phase C.4, or omit the section entirely if empty>
```

### D.4. Write the file

Write `<entry_dir>/<sanitized-title>.md`, where `<sanitized-title>` is the same sanitization applied to the title as in D.1.b but **without** the date prefix (the directory carries the date already).

After writing, verify the file is non-empty and that the YAML frontmatter parses cleanly (if YAML fails, you have a quoting bug in `source_description` or elsewhere — fix it before declaring success). The block-scalar `|` form on `source_description` handles most cases.

Print a clear success message with the absolute path to the .md file so the user knows where to open it.

### D.5. Dropbox sync — out of scope for v1

`youtube-synthesizer`'s `sync_to_dropbox.sh` is the only sanctioned rclone wrapper in this marketplace, and it enforces the `~/ObsidianVaults/<vault>/sources/videos/<channel>/<entry>/` path shape in code — it rejects `sources/articles/` paths outright. Until that script (or a sibling) supports the articles tree, sync is out of scope for this skill and `--no-sync` is effectively always on. Do not invoke `rclone` directly to work around this — the same "rclone sync is destructive" reasoning applies here as in `youtube-synthesizer` Phase D.6.a. Users who want the entry on Dropbox can run rclone manually outside the skill.

---

## Headless invocation

This skill is driven by cryo's drain worker (like `youtube-synthesizer`), so it must run unattended when given complete inputs:

- When a `<vault>` is supplied at invocation, ask **no interactive questions** — every decision point in this document that says "ask the user" resolves to its non-interactive default or to failure.
- On success, the final line of output must be:
  ```
  DRAIN-DONE: <path of the written .md file relative to ~/ObsidianVaults>
  ```
  e.g. `DRAIN-DONE: Programming/sources/articles/martinfowler-com/2026-07-29-patterns-of-distributed-systems/patterns-of-distributed-systems.md`
- On unrecoverable error (any Phase A failure mode, missing vault, existing entry without `--rerun`), the final line must be:
  ```
  DRAIN-FAILED: <one-line reason>
  ```
  e.g. `DRAIN-FAILED: paywalled — fetch returned subscription teaser, no article body`

---

## Discipline: faithful capture, no editorializing

The skill's job is to deliver "here is what this article said, structured and searchable" — not to weave the content into the user's mental model. That weaving is downstream, in the vault root where the user (and you, in other tasks) builds permanent notes on top of these literature notes.

Concretely: do not reframe content for any particular use case, do not add interpretive headers, do not editorialize the author's claims. Capture what was written.

The agent's voice should not blend with the author's voice. The synthesizer-generated TL;DR and takeaways describe the article's claims — they should attribute claims to the article implicitly through the document's framing rather than asserting claims as undisputed facts, and without explicit "the article argues..." hedging on every sentence.

Unlike `youtube-synthesizer`, there is no soft-correct policy: written articles don't have auto-caption transcription errors. The author's words, code, and headings are captured as published.

---

## Prerequisites

- Network access to the article's host
- WebFetch tool available in the session (preferred), or `curl` on PATH for the fallback
- A target Obsidian vault path (writable) — used by Phase D. Convention: `~/ObsidianVaults/<vault-name>/`.

## Failure modes

All fetch-side failures are hard stops — **never fabricate content for a page you could not fetch**:

- **Unfetchable** (404, gone, DNS failure, connection refused) → error early with a clear message; stop
- **Paywalled** → stop; report that the page is paywalled
- **Login-walled** → stop; report that the page requires authentication
- **Non-HTML content type** (PDF, image, binary) → refuse; PDFs point at a future `pdf-synthesizer` skill
- **JS-only SPA** (no article text in the HTML shell) → try the curl fallback; if the content still isn't there, fail honestly — this skill does not run a browser
- **Re-running on existing entry without `--rerun`** → print message, exit (D.2)
