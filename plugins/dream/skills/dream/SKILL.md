---
name: dream
description: |
  Mine this project's Claude Code session logs into durable improvements —
  proposed memories, CLAUDE.md rules, docs, and skills. Async "AI dreaming":
  distill raw sessions into friction-focused digests, then consolidate across
  sessions (dedup vs what's already captured, frequency-gated promotion).

  Use when: (1) the user asks to mine/learn-from past sessions, "dream over my
  logs", or improve project memory/docs from experience; (2) a nightly/periodic
  self-improvement pass; (3) after a stretch of work, to capture recurring
  lessons. NOT for reviewer-roster tuning — that's the `dream-reviewers` skill.
argument-hint: "(optional) project dir, or session id to focus on"
---

# Dream — session miner

Turn accumulated session traces into durable project improvements. Two stages:
cheap deterministic distillation, then an Opus consolidation pass that you run.

Read [`references/DESIGN.md`](../../references/DESIGN.md) for the why; read
[`references/MARKER-CONTRACT.md`](../../references/MARKER-CONTRACT.md) to also
fold in any structured markers producers left for you.

## 0. Locate the scripts

Use Glob to find the entry wrapper, then use its full literal path for every call:
```
Glob: **/plugins/dream/scripts/dream      (clone)   OR   **/dream/*/scripts/dream  (installed)
```
Run everything from the **target project directory** (so paths derive correctly),
or pass `DREAM_PROJECT_DIR=/path/to/project`. The tool needs nothing wyrd-specific
— it derives the log dir, repo, `~/.dream/<slug>/` home, and the known-corpus
(CLAUDE.md/AGENTS.md + the project's memory dir) from context.

## 1. Distill (stage 1 — deterministic + local model)

```bash
<scripts>/dream distill          # all un-distilled sessions (cached by source hash)
<scripts>/dream distill --no-model   # heuristic only (fast, skips ollama)
<scripts>/dream stats            # friction + candidate-insight tallies
```

Distillation extracts **friction** (denials, corrections, tool errors) and runs a
local ollama model (`WYRD_OLLAMA_URL`, default `http://10.5.2.31:11434`;
`DREAM_MODEL`, default `qwen2.5:7b`) to emit per-session candidate insights. The
live (most-recent) session is skipped unless `--include-live`. Digests are cached
in `~/.dream/<slug>/digests/` — only new sessions re-distill.

## 2. Pool (stage 2a — deterministic)

```bash
<scripts>/dream synth            # → ~/.dream/<slug>/review/queue.json + QUEUE.md
```

Pools all candidate insights and lexically pre-flags likely-already-captured
ones. This is a HINT only — local clustering under-merges; you do the real
consolidation next.

## 3. Consolidate (stage 2b — YOU, or a spawned Opus Task)

Local embeddings/lexical clustering are too weak for semantic dedup, so the
judgment is yours. Read `review/queue.json` + the known corpus
(`<scripts>/dream` derives it; it's the project's `memory/`, CLAUDE.md/AGENTS.md
up to the git root, and any `$DREAM_EXTRA_CORPUS` decision log). Then:

1. **Cluster** the candidates into distinct lessons; count DISTINCT sessions per
   cluster (frequency).
2. **Dedup** against the known corpus — drop anything already captured (cite what).
3. **Route** each surviving cluster:
   - `memory` — one-off preference, OR any lesson seen in only 1 session.
   - `CLAUDE.md` — a behavior rule recurring across **≥2 sessions** (frequency gates this).
   - `doc` / `skill` — deeper explanation / repeatable procedure.
   - `product-decision` — a decision about the PRODUCT, not agent behavior →
     route to the project's issue tracker (e.g. a `bd` decision), NEVER to agent
     instructions.
4. Write a `SYNTHESIS.md` to `~/.dream/<slug>/review/` with the routed buckets.

For a large backlog, spawn this as a Task to keep main context lean.

## 4. Promote (copy-on-write gate)

- **memory** candidates → write to the project memory dir (low-stakes, reversible).
- **CLAUDE.md / doc / skill / product-decision** → **propose only**: open issues /
  a review queue for the user. These are shared and load-bearing; never auto-edit.

Report what you auto-wrote and what you propose. Done.
