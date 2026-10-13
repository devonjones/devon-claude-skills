# Guidelines

A reviewer pack for Go projects. Each section below is an independent reviewer prompt with its own scope, set of patterns to flag, and disposition.

## How the pack runs

**This file is consumed BY the `pr-review-loop` skill — do not run these reviewers directly.** If you've read this file and are about to spawn the agents yourself (outside the skill), stop and invoke `pr-review-loop` instead: the skill owns the parts this file doesn't define — agents posting findings as PR line comments, independent validation of posted findings, per-thread replies, per-agent retirement, CI gating, and exit conditions. Hand-spawning from this file skips all of that and breaks the PR audit trail.

Each reviewer runs independently and reports findings without coordination. A reviewer's silence on something is not an endorsement — it just means that reviewer didn't see anything in its scope.

**Per-reviewer file scope:**

| Reviewer | Files in scope |
|----------|----------------|
| `test-coverage-reviewer` | `*.go` |
| `error-handling-reviewer` | `*.go` |
| `complexity-reviewer` | `*.go` (skips `*_test.go`) |
| `concurrency-reviewer` | `*.go` touching `go`, `chan`, `select`, `sync.*`, or `context` |
| `resource-leak-reviewer` | `*.go` |
| `external-process-reviewer` | `*.go` touching `os/exec` |
| `dead-code-reviewer` | `*.go` |
| `clarity-reviewer` | `*.md`, `*.go` (comments only) |

Skip reviewers whose file scope doesn't match the PR diff.

## Tooling assumed in CI

Reviewers do not duplicate work already done by CI. Each Go project running this pack should have these in CI:

- `gofmt -l ./...` — empty output enforced
- `go vet ./...`
- `staticcheck ./...` (honnef.co/go/tools)
- `go test -race -count=1 ./...` — race detector enabled
- `gocognit -over 10 ./...` — cognitive complexity ceiling (see `complexity-reviewer`)
- `deadcode ./...` from `golang.org/x/tools/cmd/deadcode` (see `dead-code-reviewer`)

A missing tool is itself a **P1** finding on the first PR that brushes against its scope. For example, if CI doesn't run `-race` and the PR touches concurrent code, `concurrency-reviewer` flags the CI gap as well as the code.

## Severity convention

Every finding must be tagged with a beads-style priority:

| Priority | Disposition | Examples |
|----------|-------------|----------|
| **P1** | Blocking — must fix before merge | Security issue, leak in long-running service, unsynchronized shared state, unjustified new mutex, goroutine leak, missing `-race` in CI |
| **P2** | Should fix in this PR | Missing error wrap context, missing tests for new branches, missing `ctx` propagation, missing CLI timeout, gocognit floor violation |
| **P3** | Advisory — deferrable with a beads ticket | Complexity heuristic findings, dead code, clarity nits, markdown structural suggestions |

**Default severity per reviewer:**

- `concurrency-reviewer`, `resource-leak-reviewer`: **P1** by default.
- `test-coverage-reviewer`, `error-handling-reviewer`, `external-process-reviewer`: **P2** by default; specific flags inside each reviewer may be P1.
- `complexity-reviewer`: **P2** for gocognit floor violations; **P3** for heuristic findings.
- `dead-code-reviewer`, `clarity-reviewer`: **P3** by default.

A reviewer may promote or demote a specific finding from its default, but must state why.

## Output format

Findings must be structured. Use this template:

```
[<reviewer>] [<severity>] <one-line title>

File: path/to/file.go:LINE
Quote:
    <1-5 lines of code or text being flagged>

Issue: <one or two sentences on what's wrong>
Suggested fix:
    <concrete diff or rewritten code/text>
Reason (optional): <only if not obvious>
```

Example:

```
[concurrency-reviewer] [P1] New sync.Mutex without justification

File: internal/cache/cache.go:42
Quote:
    type cache struct {
        mu sync.Mutex
        m  map[string]int
    }

Issue: New mutex protects mutable shared state. Per the pack's design philosophy,
mutexes are flagged by default — replace with channel-owned state unless this falls
into "Tolerated uses of sync.*" in concurrency-reviewer.
Suggested fix: A goroutine owns the map and accepts ops via channel. See the GOOD
example in concurrency-reviewer.
```

Structured findings are diff-able, easy to triage, and easy to deduplicate when multiple reviewers flag the same line.

## Deferring findings with beads

To defer a P2 or P3 finding to a follow-up:

1. Create a beads ticket capturing reviewer name, severity, file, and quote.
2. Link the ticket in the PR description or as a reply to the reviewer's comment.
3. The reviewer accepts the deferral only when the beads ticket exists.

**P1 findings are not deferrable** — they must be fixed in-PR.

---
