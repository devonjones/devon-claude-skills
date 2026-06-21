# Dream — design notes

"AI dreaming": an async, offline pass that turns accumulated Claude Code traces
into durable improvements. Loop shape: **capture → consolidate → validate →
promote**, copy-on-write (outputs are candidates, not live writes), with a
promotion gate that differs by how risky the write is.

Two skills, one shared pipeline (`scripts/dreamlib`):

- **`dream`** — session miner. distill (heuristic friction + local-ollama
  enrichment, cached digests) → pool → Opus consolidation (dedup vs known corpus,
  frequency-gated promotion, behavior-vs-product-decision routing).
- **`dream-reviewers`** — validate the pr-review-loop reviewer roster.

## Promotion gate (copy-on-write)

| Target | Stakes | Default |
|---|---|---|
| memory | low, reversible | auto-write OK |
| CLAUDE.md / docs / skills | shared, load-bearing | propose only |
| reviewer roster (AGENT-REVIEWERS.md) | the quality gate | propose only |
| product decisions | belong in the tracker | route to `bd`, never to agent instructions |

## Hard-won findings (why it's built this way)

- **Mine friction, not content.** The signal is denials, corrections, tool errors
  — moments the agent did the wrong thing or had to discover something the docs
  should have stated. Volume of "what happened" is noise.
- **Local clustering is too weak for semantic dedup.** Lexical Jaccard under-merges
  (varied phrasing); general-purpose ollama embeddings false-merge ("Document X" ≈
  "Clarify Y"). So the deterministic pass only *pools + pre-flags*; an Opus pass
  owns clustering/dedup/routing. At backlog scale a single Opus pass is cheaper
  and far more reliable.
- **Frequency gates promotion.** A lesson in 1 session is a memory at most; recurring
  across many is a CLAUDE.md candidate. Only cross-session synthesis sees frequency.
- **Mature corpora yield little novelty — that's success.** Most surfaced lessons
  are already captured; the value is the few genuinely-new recurring ones.

## Reviewer validation — and why markers exist

The PR is *supposed* to be the system of record, but the review loop historically
**skipped posting** some findings, so GitHub is selection-biased (posted-only).
Logs store findings heterogeneously across eras (inline results → task-notification
`<result>` → `/tmp` transcripts **cleared on reboot**), and *none* of these record
**who** dispositioned a finding (operator taste vs orchestrator).

The fix is the **[marker contract](MARKER-CONTRACT.md)** — the checkpoint-writer
pattern: pr-review-loop intentionally emits one durable, structured marker per
finding+disposition (with `disposition_by`). dream consumes markers as
authoritative; GitHub + the log harvest/coverage are backfill for history. The
forward harvest cron grabs `/tmp` transcripts opportunistically before a reboot,
but markers are the durable answer.

## Output locations

All derived data lives **outside the repo** at `~/.dream/<slug>/` (`<slug>` =
git-root basename): `digests/`, `review/`, `reviews/`, `markers/`. Override with
`$DREAM_HOME`. Nothing is written into the working tree.
