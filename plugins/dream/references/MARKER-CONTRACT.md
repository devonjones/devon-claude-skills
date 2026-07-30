# Dream marker contract (v1)

A **dream marker** is one durable, structured record that a *producer* skill
writes at a decision point, for the *consumer* (dream) to mine later. This is the
"checkpoint-writer" pattern: the executor intentionally records what matters
instead of dream reverse-engineering it from raw logs.

It exists because reverse-engineering is lossy. For reviewer validation
specifically, raw logs gave three bad sources — GitHub (only *posted* findings),
`/tmp` transcripts (cleared on reboot), heterogeneous inline/notification blobs —
and **none** could say *who* dispositioned a finding (the operator's taste vs the
orchestrator's). A marker records all of it, once, durably.

## Location

```
~/.dream/<slug>/markers/<producer>.jsonl        # append-only, one JSON per line
```

- `<slug>` = **basename of the git root** (`basename "$(git rev-parse --show-toplevel)"`).
  Producers and dream both derive it the same way, with no network call. (Honors
  `$DREAM_HOME` if set, which overrides `~/.dream/<slug>`.)
- `<producer>` = the writing skill's name, e.g. `pr-review-loop.jsonl`.
- **Outside the repo** — never write markers into the working tree.

## Schema

Every record has `ts` (ISO-8601 UTC), `skill` (producer), and `kind`.

### `kind: "reviewer-finding"` (consumed by `dream-reviewers`)

| field | meaning |
|---|---|
| `pr`, `round` | PR number, review round |
| `reviewer` | agent name (kebab), e.g. `complexity-reviewer` |
| `severity` | `P1` \| `P2` \| `P3` |
| `file`, `line` | location |
| `finding` | the issue text |
| `disposition` | `fixed` \| `addressed` \| `acknowledged` \| `out_of_scope` \| `wont_fix` \| `withdrawn` \| `unresolved` |
| `disposition_by` | **`user`** \| `orchestrator` — the taste signal; only markers carry it |
| `reason` | one line on why (esp. for `wont_fix`/`withdrawn`) |
| `validator` | `valid` \| `invalid` \| `uncertain` \| null (independent-validator verdict, if run) |

```json
{"ts":"2026-06-21T05:00:00Z","skill":"pr-review-loop","kind":"reviewer-finding","pr":702,"round":1,"reviewer":"complexity-reviewer","severity":"P3","file":"x.py","line":42,"finding":"function ~67 lines, just over one screen","disposition":"wont_fix","disposition_by":"user","reason":"line-length advisory; ruff C901 is the real floor","validator":"valid"}
```

### `kind: "correction" | "insight" | "decision" | "friction"` (session miner)

Generic markers any skill — or a `/dream-mark` invocation — can drop:

| field | meaning |
|---|---|
| `text` | the lesson / correction / decision, one sentence |
| `context` | optional: what was happening |
| `refs` | optional: PR, file, ticket ids |

```json
{"ts":"…","skill":"pr-review-loop","kind":"insight","text":"verify against the live grid, not the handoff premise","context":"…"}
```

## Rules for producers

1. **Append, never mutate.** One line per record. dream is read-only over the stream.
2. **Best-effort.** Emitting a marker must NEVER fail or block the producer's main
   flow — wrap it so a write error is swallowed.
3. **No secrets.** Markers may be summarized into memories/CLAUDE.md; keep them clean.
4. Unknown `kind`s are ignored by dream, so producers may add new kinds freely.

## Consumer behavior

`dream reviews-synth --source markers|github|all`. Marker findings are the
**authoritative** source; GitHub and the log harvest are backfill for
un-instrumented history. The taste column (`taste(user)`) comes only from
markers' `disposition_by`.
