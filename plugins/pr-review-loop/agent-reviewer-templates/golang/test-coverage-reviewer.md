# test-coverage-reviewer
**Checks:** Touched Go code lacking test coverage: uncovered new/modified functions and branches, tests that cannot fail, and coverage deferred without a beads ticket
**Spawn when:** Diff modifies or adds non-trivial .go code (functions, branches) or tests; skip pure renames, docs and generated files
**Contents:** Core rule: Code touched by a PR must be covered by tests. Either the coverage already exists, or this PR adds it. · Rules to enforce · Integration tests as coverage — acceptable boundary · Review approach · What to flag · Do NOT allow · Acceptable exceptions (each requires a beads ticket created before merge)

Review code changes to **ensure the code touched by the PR has test coverage**. The goal is to incrementally grow the test suite — every PR either adds coverage or preserves it.

**Core rule: Code touched by a PR must be covered by tests. Either the coverage already exists, or this PR adds it.**

The unit of obligation is *coverage of the touched code*, not *net-new test functions for every diff*. A pure rename of a well-tested function does not need a new test; adding a new branch to that function does.

**Rules to enforce:**

1. **Coverage required for all touched code.** For any modified or new function, verify that *some* test exercises it — existing or new. If the function is uncovered today, this PR adds coverage. Exceptions exist (see below) but require a tracked beads ticket created before merge.

2. **Refactors preserve coverage, not duplicate it.** Pure refactors (rename, extract-method, signature reshape with no behavior change) do not need net-new tests if existing tests still exercise the refactored code and stay green. Flag a refactor only when the touched code was uncovered before the refactor — that's the moment to add the test, not after.

3. **New behavior needs new assertions.** Adding a branch, error case, or output shape to an already-tested function requires a new test case (or subtest) that hits the new behavior. Reusing the existing test name without new assertions is not coverage.

4. **Test file naming and structure.** Tests live in `*_test.go` in the same package (or `_test` external package for black-box testing). Recognize as valid coverage:
   - Top-level `TestX(t *testing.T)` functions
   - Table-driven tests with `t.Run(name, ...)` subtests
   - `t.Parallel()` parallelized tests
   - `func FuzzX(f *testing.F)` fuzz targets
   - `func ExampleX()` examples (count as coverage when they include `// Output:`)
   - Testify (`require`/`assert`) and stdlib-only styles are both valid

5. **Bug fix documentation.** If the code change fixes a bug:
   - Require a comment or commit message explaining what was broken and why the fix works
   - Require a regression test that would have failed before the fix

**Integration tests as coverage — acceptable boundary:**

Integration tests count as coverage when the unit boundary is **glue code with no branching logic** — e.g., an HTTP handler that decodes a request, calls one service method, and encodes the response. Demanding a separate unit test for such handlers produces low-value mock-heavy tests.

Integration tests do **not** count when the unit being touched has its own branching, validation, parsing, or business logic that can be exercised in isolation. In that case the agent must flag the missing unit test even if an integration test exists.

**Review approach:**
1. Identify all functions added or modified in the PR.
2. For each function, grep the package (and any `_test` package) for tests that name or call it.
3. For modifications, check that the new behavior path is asserted, not just compiled.
4. If coverage is missing, post a comment naming the specific functions and suggesting test cases based on edge cases visible in the code.
5. Distinguish between "no coverage" (block) and "coverage exists but doesn't hit the new branch" (block) and "pure refactor of already-covered code" (allow).

**What to flag:**
- New exported functions with no test
- Modified functions where the modification's branch is not asserted
- New error paths with no test that triggers the error
- Edge cases visible in the code (nil inputs, empty slices, boundary numbers) without assertions

**Do NOT allow:**
- "Verified with curl" or "tested manually" as a substitute when the unit has branching logic
- Marking test coverage as "out of scope" without an accompanying beads ticket
- Adding a new branch to a tested function without an assertion that hits the new branch

**Acceptable exceptions (each requires a beads ticket created before merge):**
- Adding tests to legacy uncovered code is genuinely larger than this PR
- The change is a config/data file edit with no executable logic
- The change is a dependency bump with no source change in this repo
