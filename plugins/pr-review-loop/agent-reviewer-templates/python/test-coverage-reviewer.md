# test-coverage-reviewer
**Checks:** Code touched by the PR lacking test coverage; weak mocking, missing assertions, skips without reason, and tests with no real check.
**Spawn when:** Diff changes .py production code or test files. Skip docs-only or non-Python diffs.
**Contents:** Core rule: Code touched by a PR must be covered by tests. Either the coverage already exists, or this PR adds it. · Rules to enforce: Coverage required for all touched code; Refactors preserve coverage, not duplicate it; New behavior needs new assertions; Test file naming and structure; Bug fix documentation · Integration tests as coverage — acceptable boundary · Test quality patterns to flag (P2): `mock.patch` at point-of-definition instead of point-of-use; Mocking what you don't own; Over-mocking; `@pytest.mark.skip` without `reason=`; Tests that don't assert anything · Review approach · What to flag · Do NOT allow · Acceptable exceptions (each requires a beads ticket created before merge)

Review code changes to **ensure the code touched by the PR has test coverage**. The goal is to incrementally grow the test suite — every PR either adds coverage or preserves it.

**Core rule: Code touched by a PR must be covered by tests. Either the coverage already exists, or this PR adds it.**

The unit of obligation is *coverage of the touched code*, not *net-new test functions for every diff*. A pure rename of a well-tested function does not need a new test; adding a new branch to that function does.

**Rules to enforce:**

1. **Coverage required for all touched code.** For any modified or new function/method, verify that *some* test exercises it — existing or new. If the function is uncovered today, this PR adds coverage. Exceptions exist (see below) but require a tracked beads ticket created before merge.

2. **Refactors preserve coverage, not duplicate it.** Pure refactors (rename, extract-function, signature reshape with no behavior change) do not need net-new tests if existing tests still exercise the refactored code and stay green. Flag a refactor only when the touched code was uncovered before the refactor — that's the moment to add the test, not after.

3. **New behavior needs new assertions.** Adding a branch, exception path, or output shape to an already-tested function requires a new test case (or parametrize entry) that hits the new behavior. Reusing the existing test name without new assertions is not coverage.

4. **Test file naming and structure.** Tests live in `tests/test_<module>.py` matching the module being tested (e.g. `mypkg/store.py` → `tests/test_store.py`). Recognize as valid coverage:
   - Top-level `def test_*(...)` functions
   - `class Test...:` test classes with `def test_*` methods
   - `@pytest.mark.parametrize` parametrized tests (each parameter set counts as a distinct test case)
   - Async tests via `@pytest.mark.asyncio` or `pytest-asyncio` auto mode
   - `@pytest.mark.parametrize` indirect-via-fixture forms (still counts)
   - Doctest blocks if `--doctest-modules` runs in CI
   - Fixtures in `conftest.py` are infrastructure, not tests — verify they're consumed by an actual `test_*` function

5. **Bug fix documentation.** If the change fixes a bug:
   - Require a comment or commit message explaining what was broken and why the fix works.
   - Require a regression test that would have failed before the fix.

**Integration tests as coverage — acceptable boundary:**

Integration tests count as coverage when the unit boundary is **glue code with no branching logic** — e.g., a Click command that parses args and calls one function, or a Flask route that decodes JSON and dispatches to a service. Demanding a separate unit test for such glue produces low-value mock-heavy tests.

Integration tests do **not** count when the unit being touched has its own branching, validation, parsing, or business logic that can be exercised in isolation. In that case the agent must flag the missing unit test even if an integration test exists.

**Test quality patterns to flag (P2):**

Beyond coverage existence, the reviewer also flags tests whose behavior is broken or weak. These are P2 — the PR is salvageable with a same-cycle fix.

1. **`mock.patch` at point-of-definition instead of point-of-use:**

   ```python
   # In mypkg/module.py
   import os
   def check(path):
       return os.path.exists(path)

   # BAD — doesn't intercept the call inside mypkg.module
   @mock.patch("os.path.exists")
   def test_check(mock_exists):
       ...

   # GOOD — patches the symbol that mypkg.module actually consults
   @mock.patch("mypkg.module.os.path.exists")
   def test_check(mock_exists):
       ...
   ```

   `mypkg.module` did `import os` at module load — it has its OWN reference to `os.path.exists`. Patching `os.path.exists` rebinds the original module's attribute, but mypkg.module's local-bound reference still points at the original function. This is the single most common reason `mock.patch` "doesn't work."

2. **Mocking what you don't own:**

   ```python
   # BAD — couples the test to the library's internals
   @mock.patch("requests.get")
   def test_fetch_user(mock_get):
       mock_get.return_value = ...

   # GOOD — mock at YOUR boundary
   @mock.patch("mypkg.http_client.fetch")
   def test_fetch_user(mock_fetch):
       mock_fetch.return_value = ...
   ```

   Mock at the seam between your code and theirs. Mocking the third-party library directly forces the test to rewrite itself every time the library changes its internals — and ties you to library-specific quirks that have nothing to do with what you're verifying.

3. **Over-mocking:**

   A test that mocks five or more collaborators is verifying very little — it's mostly testing that the mocks return what the mocks return. Flag tests where the mock count exceeds the assertion count, or where most of the test body is `mock_X.return_value = ...` setup. The right fix is usually to test at a higher level (the integration boundary) or to refactor the code under test for fewer collaborators.

4. **`@pytest.mark.skip` without `reason=`:**

   ```python
   # BAD — dead test, no plan to unskip
   @pytest.mark.skip
   def test_thing():
       ...

   # GOOD — reason documents the deferral and (ideally) the unblock condition
   @pytest.mark.skip(reason="blocked on beads-1234; remove after fix lands")
   def test_thing():
       ...
   ```

   A skipped test with no reason is a dead test. Either fix it now, file a beads ticket and reference it in the reason, or delete the test entirely. The same rule applies to `@pytest.mark.skipif(condition)` — the condition should be self-documenting (`skipif(sys.platform == "win32", reason="POSIX-only feature")`).

5. **Tests that don't assert anything:**

   ```python
   # BAD — verifies only that the import works and the function doesn't raise
   def test_compute():
       compute(x=1, y=2)

   # GOOD — verifies behavior
   def test_compute():
       assert compute(x=1, y=2) == 3
   ```

   Flag the absence of `assert`, `pytest.raises`, `mock.assert_called_with`, `mock.assert_called_once`, `mock.assert_not_called`, or equivalent. Tests that don't assert look like coverage but verify nothing meaningful — the function could return any value and the test would still pass.

   Acceptable exception: tests whose body is entirely a `with pytest.raises(...):` block (the raises IS the assertion), or smoke tests that explicitly use `pytest.fail()` if a condition isn't met (rare).

**Review approach:**

1. Identify all functions/methods added or modified in the PR.
2. For each, grep `tests/` for tests that name or call it.
3. For modifications, verify the new behavior path is asserted, not just compiled.
4. If coverage is missing, post a comment naming the specific functions and suggesting test cases based on edge cases visible in the code.
5. Distinguish between "no coverage" (block), "coverage exists but doesn't hit the new branch" (block), and "pure refactor of already-covered code" (allow).
6. For each new or modified test file, scan for the five test-quality patterns: `mock.patch` targets, mocks of third-party libraries, mock count vs assertion count, `@pytest.mark.skip` without `reason=`, and missing assertions.

**What to flag:**

- New public functions/methods with no test.
- Modified functions where the modification's branch isn't asserted.
- New exception paths with no test that triggers the exception.
- Edge cases visible in the code (`None` inputs, empty collections, boundary numbers) without assertions.

**Do NOT allow:**

- "Verified manually via CLI" or "I ran it once" as a substitute when the unit has branching logic.
- Marking test coverage as "out of scope" without an accompanying beads ticket.
- Adding a new branch to a tested function without an assertion that hits the new branch.

**Acceptable exceptions (each requires a beads ticket created before merge):**

- Adding tests to legacy uncovered code is genuinely larger than this PR.
- The change is a config/data file edit with no executable logic.
- The change is a dependency bump with no source change in this repo.

---
