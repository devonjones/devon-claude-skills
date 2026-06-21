---
name: dream
description: |
  Mine this project's Claude Code session logs into durable improvements —
  proposed memories, CLAUDE.md rules, docs, skills, and decision-log
  (DECISIONS.md) entries. Async "AI dreaming": distill raw sessions into
  friction-focused digests, then consolidate across sessions (dedup vs what's
  already captured, including any project DECISIONS.md, frequency-gated promotion).

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
or pass `DREAM_PROJECT_DIR=/path/to/project`. The tool needs nothing project-specific
— it derives the log dir, repo, `~/.dream/<slug>/` home, and the known-corpus
(CLAUDE.md/AGENTS.md + the project's memory dir + **every `DECISIONS.md` under the
git root**, auto-discovered) from context. `$DREAM_EXTRA_CORPUS` still appends more.

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
up to the git root, every auto-discovered `DECISIONS.md`, and any
`$DREAM_EXTRA_CORPUS` path).

**If the project has `DECISIONS.md` file(s), read each one IN FULL before
consolidating** — start to finish, do NOT skim or sample despite their length.
They are the authoritative architectural record and your single best dedup
reference: most "new architecture insight" candidates are already a numbered
decision (with its motivating example and a regression test), and you can only
see that — and spot when the log has drifted from shipped behavior — by holding
the whole log. Then:

1. **Cluster** the candidates into distinct lessons; count DISTINCT sessions per
   cluster (frequency).
2. **Dedup** against the known corpus — drop anything already captured (cite what,
   e.g. `DECISIONS.md:NNNN` / the decision number).
3. **Route** each surviving cluster:
   - `memory` — one-off preference, OR any lesson seen in only 1 session.
   - `CLAUDE.md` — a behavior rule recurring across **≥2 sessions** (frequency gates this).
   - `doc` / `skill` — deeper explanation / repeatable procedure.
   - `decisions-log` — a PRODUCT/architecture decision that belongs in a project
     `DECISIONS.md`, in one of two flavors: **(a)** a decision made or shipped in a
     session but never recorded, or **(b)** an existing entry now **stale or
     contradicted** by what shipped (drift). Cite the commits/code that prove it.
     **Anti-manufacture bar:** propose one ONLY when a session shows a real
     decision or reversal — never because something merely "looks undocumented."
     A well-maintained log (inline supersession tombstones) legitimately yields
     **zero** here; that is the correct, honest output, not a gap to fill.
   - `product-decision` — a product decision better tracked as an issue/ticket
     (e.g. a `bd` decision) than a `DECISIONS.md` entry. NEVER agent instructions.
4. Write the routed buckets to **one self-contained per-run file**:
   `~/.dream/<slug>/review/pending/<YYYYMMDD>-dream.md` (today's date; **overwrite**
   it if a run already wrote it today — latest consolidation wins, do NOT append/
   accrete). This is the human review unit: everything from this run in one file
   the user can read in a sitting, then archive whole.

For a large backlog, spawn this as a Task to keep main context lean.

## 4. Promote (copy-on-write gate)

- **memory** candidates → write to the project memory dir (low-stakes, reversible).
- **CLAUDE.md / doc / skill / decisions-log / product-decision** → **propose only**,
  collected into this run's `review/pending/<YYYYMMDD>-dream.md`. These are shared
  and load-bearing; never auto-edit — and `DECISIONS.md` especially is append-with-
  supersession by hand, so route every `decisions-log` proposal to the pending
  file, never an edit.

**Pending → reviewed lifecycle.** Proposals live in `review/pending/`; the
SessionStart hook warns about anything there. The user dismisses a run by moving
its file into `review/reviewed/` (or deleting it) once actioned — so keep each
run's proposals in its own file and never write into `review/reviewed/` yourself.

Report what you auto-wrote and what you propose (with a per-bucket count, including
a `decisions-log` count even when it is 0). Done.

## Running on a schedule (nightly, unattended)

Run this skill headlessly on a timer: `claude -p "<the dream prompt>"
--permission-mode auto`, fired by your OS scheduler. `--permission-mode auto`
lets the classifier gate each tool call and fail closed when unattended (the
pipeline shells out, so stricter modes stall). Because the skill needs local
session logs + `~/.dream/` state + a reachable ollama (install from
<https://ollama.com>; see stage 1 for the env vars), it must run on your
machine, not a cloud scheduler.

See [`references/SCHEDULING.md`](../../references/SCHEDULING.md) for copy-paste
setups: **Linux** (systemd user timer — survives logout via `loginctl
enable-linger`, catches missed runs), **macOS** (launchd LaunchAgent), and a
portable **cron** fallback. Stagger `dream` and `dream-reviewers` a few minutes
apart; both land per-run files in `review/pending/` for the SessionStart hook.
