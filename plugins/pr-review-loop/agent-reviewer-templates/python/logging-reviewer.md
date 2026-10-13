# logging-reviewer
**Checks:** Logging discipline: f-string log calls, secrets in logs, wrong levels, CLI noise versus library/service logging rules, print used as logging.
**Spawn when:** Diff in .py files adds or changes logging calls, print(), logger setup, or CLI entry points.
**Contents:** Patterns to FLAG — universal (apply in any context) · Patterns to FLAG — CLI entry points only · Patterns to FLAG — library / service only · Do NOT flag · Review approach

Review Python code for **logging discipline**. Logging is observability infrastructure: it determines what operators see in production when things go wrong, and it's also a security boundary (logs are often shipped off-host and indexed by tools that don't redact secrets). The reviewer covers two contexts with different rules:

- **Libraries and services** — long-running code that ships logs to operators.
- **CLI tools** — entry points that follow Unix's rule of silence: terse by default, verbose on request.

### Patterns to FLAG — universal (apply in any context)

1. **Sensitive data in log messages (P1 — security leak):**

   ```python
   # BAD — credentials in logs that ship off-host
   logger.info(f"user={user}, token={token}")
   logger.debug(f"request headers: {request.headers}")  # often includes Authorization
   ```

   Flag string interpolation of variables named `token`, `password`, `secret`, `api_key`, `credential`, `auth`, `cookie`, `session`, `private_key`, or `bearer` into any log call. Also flag dumping entire request/response objects without redaction — `request.headers` typically contains `Authorization`.

   Acceptable: explicit redaction (`token[:8] + "..."`), or logging a hash/fingerprint instead of the value.

2. **`logger.error(...)` inside an `except` block without `exc_info=True`:**

   ```python
   # BAD — traceback silently discarded
   try:
       work()
   except SomeError as e:
       logger.error(f"work failed: {e}")
       raise

   # GOOD — exception() is shorthand for error + exc_info=True
   try:
       work()
   except SomeError:
       logger.exception("work failed")
       raise
   ```

   `logger.exception()` captures the full traceback in the log record automatically. Use it inside `except` blocks unless you have a specific reason to omit the traceback.

3. **`logging.basicConfig()` called from library code:**

   ```python
   # BAD — library hijacks the host application's logging setup
   # mypkg/__init__.py
   import logging
   logging.basicConfig(level=logging.INFO)
   ```

   Libraries should call `logging.getLogger(__name__)` and let the application decide where logs go and how they're formatted. `basicConfig` belongs in entry points, never in library modules.

4. **Eager formatting in hot debug paths:**

   ```python
   # BAD in hot paths — formats unconditionally, even when DEBUG is filtered out
   logger.debug(f"processed {item.expensive_repr()}")

   # GOOD — lazy formatting; __str__ only called if DEBUG level is enabled
   logger.debug("processed %s", item)
   ```

   The performance gap matters in hot paths (request handlers, parsers, tight loops). The side-effect gap matters because `f"..."` calls `__str__`/`__repr__` unconditionally — which can be expensive, or can leak values through repr that you didn't intend.

### Patterns to FLAG — CLI entry points only

A file is treated as a **CLI entry point** when any of the following is true:

- Contains `if __name__ == "__main__":`
- Uses `click` decorators (`@click.command`, `@click.group`) or builds an `argparse.ArgumentParser`
- Located under `bin/` or `scripts/`
- Is the target of a `[project.scripts]` / `entry_points` declaration in `pyproject.toml` / `setup.cfg`

CLI tools follow Unix's rule of silence: *when a program has nothing surprising to say, it should say nothing.* Be sparse by default; verbose output is opt-in via flags.

5. **Default log level too verbose:**

   ```python
   # BAD — INFO at default makes the CLI noisy on every run
   logging.basicConfig(level=logging.INFO)

   # GOOD — silent unless something's wrong
   logging.basicConfig(level=logging.WARNING)
   ```

   CLIs should default to WARNING. INFO and DEBUG belong behind verbosity flags.

6. **No verbosity flag:**

   A CLI that uses `logging` (or emits diagnostic output) without exposing a verbosity flag gives the user no way to dial up debug output when needed. Recommend the canonical ladder:

   | Flag | Level | What surfaces |
   |------|-------|---------------|
   | (none) | WARNING | Only problems |
   | `-v` | INFO | Milestones, decisions |
   | `-vv` | DEBUG | Operational detail |
   | `-vvv` | DEBUG + extras | HTTP bodies, SQL queries, etc. |
   | `-q` / `--quiet` | ERROR | Suppress warnings — errors only |

   Recognized as correct (do NOT flag):

   ```python
   # Click
   @click.option("-v", "--verbose", count=True)
   @click.option("-q", "--quiet", is_flag=True)
   def main(verbose, quiet):
       if quiet:
           level = logging.ERROR
       else:
           level = max(logging.WARNING - verbose * 10, logging.DEBUG)
       logging.basicConfig(level=level, stream=sys.stderr)
   ```

   ```python
   # argparse
   parser.add_argument("-v", "--verbose", action="count", default=0)
   parser.add_argument("-q", "--quiet", action="store_true")
   args = parser.parse_args()
   if args.quiet:
       level = logging.ERROR
   else:
       level = max(logging.WARNING - args.verbose * 10, logging.DEBUG)
   logging.basicConfig(level=level, stream=sys.stderr)
   ```

7. **Verbosity flag that doesn't stack:**

   ```python
   # BAD — -vv has no more effect than -v
   parser.add_argument("-v", "--verbose", action="store_true")
   ```

   `action="count"` is the correct argparse form. For Click, `count=True`.

8. **`print()` for diagnostic output in CLI tools:**

   ```python
   # BAD — diagnostics on stdout, mixed with the data the user asked for
   print(f"Processing {filename}...")
   print(json.dumps(result))

   # GOOD — diagnostics on stderr via the logger; only the result on stdout
   logger.info("processing %s", filename)
   print(json.dumps(result))
   ```

   Stdout is for the data the user requested; stderr is for everything else (progress, warnings, errors). Mixing them breaks pipelines (`mycli | jq`).

### Patterns to FLAG — library / service only

9. **`print()` in library or service code:**

   In libraries and long-running services, `print()` is almost always wrong — it bypasses the logger, can't be filtered by level, doesn't include timestamps or correlation IDs, and goes to stdout (where it can corrupt structured output meant for downstream consumers). Flag `print()` in any module that isn't a CLI entry point.

   Acceptable: `print()` in a `__main__` block that is intentionally a quick-and-dirty entry point with no logging configured.

10. **Log-level discipline:**

    Everything emitted at INFO drowns real signal. Recommend the canonical levels:
    - **DEBUG** — fine-grained operational detail, traces, intermediate state.
    - **INFO** — milestones (worker started, request received, batch completed).
    - **WARNING** — recoverable issues (retry happened, fallback used, deprecated path hit).
    - **ERROR** — actionable failures (request failed, write rejected).
    - **CRITICAL** — process-level emergencies (out of disk, lost master connection).

    Flag patterns like `logger.info(f"checking {x}")` in a hot loop (should be DEBUG), or `logger.error("retrying...")` on a recoverable retry (should be WARNING).

### Do NOT flag

- `print()` in tests, ad-hoc scripts, and Jupyter notebooks.
- `print()` in a `__main__` block that is intentionally a quick-and-dirty entry point with no logger configured.
- Logging configuration in a single canonical entry point of an application (that's exactly where it belongs).
- Eager formatting in cold paths (a once-at-startup log line). The lazy-formatting rule only matters in hot loops.
- CLI tools that use `click.echo()` / `click.secho()` — these are Click's stderr-aware print equivalents and respect Click's output conventions.

### Review approach

1. For each `*.py` file in the diff, classify as CLI entry point, library, or service.
2. Grep for `logger.` / `logging.` / `print(` calls.
3. For each log call: check for sensitive variable names interpolated, `logger.error` inside `except` (should be `logger.exception`), eager `f"..."` formatting in hot paths.
4. For CLI files: check default level, verbosity flag presence + stacking, stdout/stderr discipline.
5. For library files: flag any `basicConfig` call (P2).
6. For `print()`: classify by file type; flag in libraries/services, allow in CLIs only for stdout data output.

---
