# error-handling-reviewer
verification: mixed — bare pass after except, return in finally and raise without from are found by grep; whether a handler is justified is judgement.
**Checks:** Swallowed exceptions, errors converted to defaults without logging, and raise statements missing 'from' that strip exception context.
**Spawn when:** Diff in .py files adds or changes try/except, raise, bare except, or fallback-return error paths. Skip diffs with none.
**Contents:** Patterns to FLAG: Silent exception swallowing — the most damaging pattern; `return` statement inside a `finally` block; Generic `except Exception` without re-raise; Bare `except:`; Missing exception chaining; Custom exception classes for caller-handleable cases; `try/finally` for cleanup when a context manager would do; `assert` used for runtime validation rather than invariants · Acceptable patterns: Assertions with context; Specific exception handling with `raise ... from`; Known exception handling for documented expected cases; Bare `except` with `raise` for cleanup; `contextlib.suppress` for genuinely-ignorable cases · Review approach

Review Python code for **error handling correctness**. The focus is on errors that vanish: exceptions caught and discarded, exceptions converted to defaults without logging, exception context stripped by missing `raise from`. Silent error handling makes failures impossible to investigate after the fact — the original traceback is the most valuable debugging signal you have, and discarding it deletes the investigation trail.

This reviewer enforces universal Python error-handling hygiene. It does **not** take a stance on whether a codebase should be defensively forgiving (web apps where `user.get("name", "Anonymous")` is idiomatic) or aggressively brittle (parsers / data pipelines where any unexpected structure should fail loudly). That's a project-level architectural choice and lives in the project's own AGENT-REVIEWERS.md.

**Patterns to FLAG:**

1. **Silent exception swallowing — the most damaging pattern (P1):**

   ```python
   # BAD — exception silently discarded
   try:
       parse_data(html)
   except Exception:
       pass

   # BAD — default return masks the failure
   try:
       return parse_data(html)
   except Exception:
       return {}
   ```

   If parsing fails, callers see `{}` and assume success. The original error never reaches the operator. The traceback is lost and the bug is invisible until downstream code chokes on missing fields.

2. **`return` statement inside a `finally` block (P1):**

   ```python
   # BAD — return in finally silences any exception raised in try
   try:
       return do_something()
   finally:
       return default  # swallows any exception
   ```

   Python's semantics: a `return` (or `raise`) in `finally` overrides any pending exception. This is almost always a bug.

3. **Generic `except Exception` without re-raise (P2):**

   ```python
   # BAD — catches everything, logs, continues silently
   try:
       do_complex_thing()
   except Exception as e:
       logger.warning(f"Error: {e}")
       # implicit None return
   ```

   If a caller branches on the return value, "warning logged + None returned" looks identical to "everything was fine, here's None." Either re-raise after logging, or document why a sentinel return is correct.

4. **Bare `except:` (catches `BaseException`) (P2):**

   ```python
   # BAD — also catches KeyboardInterrupt and SystemExit
   try:
       work()
   except:
       cleanup()
   ```

   Use `except Exception:` at minimum. `BaseException` includes `KeyboardInterrupt` and `SystemExit` — catching them turns Ctrl-C and `sys.exit()` into silent no-ops.

5. **Missing exception chaining (`raise ... from`) (P3):**

   ```python
   # BAD — original exception context lost
   try:
       value = int(text)
   except ValueError:
       raise ParseError("invalid number")

   # GOOD — preserves the cause for the traceback
   try:
       value = int(text)
   except ValueError as e:
       raise ParseError(f"invalid number: {text!r}") from e
   ```

   Use `raise ... from e` to preserve the original exception in the traceback. Use `raise ... from None` only when deliberately suppressing the cause is correct (rare — usually it's not).

6. **Custom exception classes for caller-handleable cases (P3):**

   Errors that callers will branch on programmatically (not-found, already-exists, validation-failure) should be declared as classes inheriting from a meaningful base:

   ```python
   # GOOD
   class LexiconError(Exception):
       """Base class for lexicon-layer errors."""

   class EntryNotFound(LexiconError):
       pass

   def get_entry(game_id: str) -> Entry:
       row = db.fetchone("SELECT * FROM entries WHERE game_id = ?", (game_id,))
       if row is None:
           raise EntryNotFound(game_id)
       return Entry.from_row(row)
   ```

   Flag ad-hoc `raise ValueError("not found")` in places where the caller clearly needs to detect the case but can't, because `ValueError` is too generic to match safely.

7. **`try/finally` for cleanup when a context manager would do (P3):**

   ```python
   # BAD — manual cleanup that early returns can skip
   f = open(path)
   try:
       data = f.read()
   finally:
       f.close()

   # GOOD
   with open(path) as f:
       data = f.read()
   ```

8. **`assert` used for runtime validation rather than invariants (P2):**

   ```python
   # BAD — asserts can be stripped with python -O
   def process(user_input):
       assert user_input is not None, "input required"

   # GOOD — actual validation
   def process(user_input):
       if user_input is None:
           raise ValueError("input required")
   ```

   `assert` is for internal invariants the developer knows must be true. Use real validation for user-facing checks.

**Acceptable patterns:**

1. **Assertions with context (fail-fast on internal invariants):**

   ```python
   assert len(children) == 2, f"Expected 2 children, got {len(children)}"
   ```

2. **Specific exception handling with `raise ... from`:**

   ```python
   try:
       value = int(text.strip())
   except ValueError as e:
       raise ParseError(f"Invalid number: {text!r}") from e
   ```

3. **Known exception handling for documented expected cases:**

   ```python
   try:
       score = int(stat.strip())
   except ValueError:
       # Known case: stat blocks use "-" for missing ability scores.
       # None is the correct value for this case.
       score = None
   ```

   The "Known case" comment makes the intentional choice explicit and reviewable.

4. **Bare `except` with `raise` for cleanup:**

   ```python
   try:
       work()
   except:
       cleanup()
       raise  # re-raises the original exception
   ```

5. **`contextlib.suppress` for genuinely-ignorable cases:**

   ```python
   from contextlib import suppress

   with suppress(FileNotFoundError):
       os.remove(temp_path)
   ```

   Better than `try/except FileNotFoundError: pass` because intent is explicit and the diff stays a one-liner.

**Review approach:**

1. Grep for `except` patterns: `except Exception:`, `except:`, `except (...)`. For each, confirm the handler either logs AND re-raises, returns the correct value for a documented case (with comment), or has another defensible justification.
2. Grep for `pass` immediately after `except`. Flag as P1.
3. Grep for `return` inside `finally`. Flag as P1.
4. Grep for `try` blocks that could be `with` statements (i.e., the body acquires and the `finally` releases a resource).
5. Grep for `raise X(...)` after `except`. Verify `from e` (or `from None` with justification) is present.
6. For each ad-hoc `raise ValueError(...)` or `raise RuntimeError(...)` in places where callers might want to detect the case, suggest a custom exception class.

---
