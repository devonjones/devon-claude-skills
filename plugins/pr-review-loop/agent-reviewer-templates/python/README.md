**Contents:** Guidelines · How the pack runs · Tooling assumed in CI · Severity convention · Output format · Deferring findings with beads

# Guidelines

A reviewer pack for Python projects. Each section below is an independent reviewer prompt with its own scope, set of patterns to flag, and disposition.

## How the pack runs

**This file is consumed BY the `pr-review-loop` skill — do not run these reviewers directly.** If you've read this file and are about to spawn the agents yourself (outside the skill), stop and invoke `pr-review-loop` instead: the skill owns the parts this file doesn't define — agents posting findings as PR line comments, independent validation of posted findings, per-thread replies, per-agent retirement, CI gating, and exit conditions. Hand-spawning from this file skips all of that and breaks the PR audit trail.

Each reviewer runs independently and reports findings without coordination. A reviewer's silence on something is not an endorsement — it just means that reviewer didn't see anything in its scope.

**Per-reviewer file scope:**

| Reviewer | Files in scope |
|----------|----------------|
| `test-coverage-reviewer` | `*.py` |
| `error-handling-reviewer` | `*.py` (production code) |
| `logging-reviewer` | `*.py` (rules differ for CLI entry points vs libraries/services) |
| `complexity-reviewer` | `*.py` (skips `tests/`) |
| `concurrency-reviewer` | `*.py` touching `threading`, `multiprocessing`, `asyncio`, `concurrent.futures`, or `queue` |
| `resource-leak-reviewer` | `*.py` |
| `external-process-reviewer` | `*.py` touching `subprocess`, `os.system`, `shutil.which` |
| `dead-code-reviewer` | `*.py` |
| `import-reviewer` | `*.py` |
| `importlib-resources-reviewer` | `*.py` in packaged modules (skips `tests/` and ad-hoc scripts) |
| `dataclass-decorator-reviewer` | `*.py` using `dataclasses.field` |
| `typing-consistency-reviewer` | `*.py` files that already use type annotations |
| `clarity-reviewer` | `*.md`, `*.py` (docstrings and comments) |

Skip reviewers whose file scope doesn't match the PR diff.

## Tooling assumed in CI

Reviewers do not duplicate work already done by CI. Each Python project running this pack should have these in CI:

- `ruff check .` — lints, import sorting (`I`), unused imports (`F401`), unused vars (`F841`), and more
- `ruff format --check .` — formatter (Black-compatible)
- `mypy .` or `pyright .` — type checker, strict mode preferred
- `pytest -v` with `--cov` — tests with coverage tracking
- `bandit -r .` — security linter (catches `shell=True`, weak crypto, etc.)
- `vulture .` — dead-code detector
- `ruff check --select C901 --max-complexity 10 .` — mccabe complexity ceiling (see `complexity-reviewer`)

A missing tool is itself a **P1** finding on the first PR that brushes against its scope. For example, if CI doesn't run `bandit` and the PR touches `subprocess`, `external-process-reviewer` flags the CI gap as well as the code.

## Severity convention

Every finding must be tagged with a beads-style priority:

| Priority | Disposition | Examples |
|----------|-------------|----------|
| **P1** | Blocking — must fix before merge | Silent exception swallow, shared state written from several threads without synchronization, missing `@dataclass` on a class using `field()`, leaked DB connection, command injection via `shell=True` |
| **P2** | Should fix in this PR | Missing `raise ... from`, missing `subprocess` timeout, missing tests for new branches, mccabe complexity floor violation, function-level import |
| **P3** | Advisory — deferrable with a beads ticket | Complexity heuristic findings, dead code, clarity nits, markdown structural suggestions |

**Default severity per reviewer:**

- `concurrency-reviewer`, `resource-leak-reviewer`: **P1** by default.
- `error-handling-reviewer`: **P2** by default; **P1** for silent exception swallows and `return` in `finally`.
- `logging-reviewer`: **P2** by default; **P1** for sensitive data in log messages.
- `dataclass-decorator-reviewer`: **P1** by default (it's a correctness bug that escapes type checkers).
- `test-coverage-reviewer`, `external-process-reviewer`, `importlib-resources-reviewer`, `typing-consistency-reviewer`: **P2** by default; specific flags inside each reviewer may be P1.
- `complexity-reviewer`: **P2** for mccabe floor violations; **P3** for heuristic findings.
- `import-reviewer`, `dead-code-reviewer`, `clarity-reviewer`: **P3** by default.

A reviewer may promote or demote a specific finding from its default, but must state why.

## Output format

Findings must be structured. Use this template:

```
[<reviewer>] [<severity>] <one-line title>

File: path/to/file.py:LINE
Quote:
    <1-5 lines of code or text being flagged>

Issue: <one or two sentences on what's wrong>
Suggested fix:
    <concrete diff or rewritten code/text>
Reason (optional): <only if not obvious>
```

Example:

```
[concurrency-reviewer] [P1] Shared counter updated from worker threads without a lock

File: stats/counts.py:18
Quote:
    _COUNTS: dict[str, int] = {}
    def worker(key):
        _COUNTS[key] = _COUNTS.get(key, 0) + 1

Issue: worker() runs on a ThreadPoolExecutor; two threads can read the same
count and both write count + 1, losing an update.
Suggested fix: hold a threading.Lock around the read and the write.
```

Structured findings are diff-able, easy to triage, and easy to deduplicate when multiple reviewers flag the same line.

## Deferring findings with beads

To defer a P2 or P3 finding to a follow-up:

1. Create a beads ticket capturing reviewer name, severity, file, and quote.
2. Link the ticket in the PR description or as a reply to the reviewer's comment.
3. The reviewer accepts the deferral only when the beads ticket exists.

**P1 findings are not deferrable** — they must be fixed in-PR.

---
