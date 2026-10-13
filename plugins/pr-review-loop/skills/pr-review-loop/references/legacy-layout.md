# Legacy layout: AGENT-REVIEWERS.md

A repo with a root `AGENT-REVIEWERS.md`, or with no root `.reviewers/` holding
reviewer files, runs in this layout (`configuration.layout` is
`"agent-reviewers"`). To convert, see [`reviewers-dir.md`](reviewers-dir.md).

**Contents:** Format · Defaults and overrides · Configuration · Stale pin · Declaring verification

## Format

Each `## <name>` under `# Agents` is a reviewer, and its body is its spec. A
`.reviewers/<name>.md` beside the file supplies the spec instead, and the H2
body becomes the summary. Other H1 sections are orchestrator context. Every H2
under `# Agents` is spawned, so prose there is a bug (discovery warns).

## Defaults and overrides

The six starters spawn as built-in defaults:

| Repo state | What spawns |
|---|---|
| No `AGENT-REVIEWERS.md` and no `.reviewers/` | All 6 defaults |
| Custom reviewers under `# Agents` | All 6 defaults + the custom ones |
| A custom reviewer named like a default | The custom one replaces that default |
| `disabled: ["pr-test-analyzer"]` | The other 5 defaults |

## Configuration

Settings live in a `# Configuration` H1 of the root `AGENT-REVIEWERS.md`, as a
fenced `json` block. It takes the same keys as `.reviewers/config.json`, plus:

- **`disabled`** — defaults not to spawn.
- **`defaults_version_checked`** — the pin the stale-pin check compares.

## Stale pin

Before round 1, compare `defaults_version_checked` with `DEFAULTS_VERSION` (plugin
root), the version in which the defaults last changed. If the pin is missing or
older, print this and exit non-zero unless `--skip-stale-check` was passed:

```
⚠️  AGENT-REVIEWERS.md was last audited against pr-review-loop v1.2.5.
    Installed version: v1.3.0
    Run `/pr-review-loop:audit-agents` to review changes, or
    pass `--skip-stale-check` to proceed with current configuration.
```

With `--skip-stale-check`, add a note saying so to the merge-readiness summary.
Bump `DEFAULTS_VERSION` only when you add, remove or rename a default, or change
what one checks enough that users should revisit their overrides.

## Declaring verification

Don't add a `verification:` line under `## pr-test-analyzer` or any other
default name. A section with a default's name *replaces* that default, so a
section holding only the declaration swaps the whole shipped prompt for one
line. The starters declare their own.
