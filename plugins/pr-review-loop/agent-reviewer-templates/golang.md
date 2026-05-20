# Configuration

```json
{
  "defaults_version_checked": "1.3.0",
  "disabled": [
    "silent-failure-hunter",
    "comment-analyzer",
    "code-simplifier"
  ],
  "overlap_acknowledged": {
    "test-coverage-reviewer": {
      "overlaps_with": "pr-test-analyzer",
      "reason": "Different lenses: test-coverage-reviewer enforces hard rules (touched code must be covered; new branches must be asserted). pr-test-analyzer scores behavioral gaps on a criticality 1-10 axis. Both contribute independent signal during review loops."
    }
  }
}
```

**Why each default is disabled:**

- **`silent-failure-hunter`** — covered by `error-handling-reviewer`. Our reviewer flags unchecked error returns, errors assigned to `_`, missing wrapping context, `defer` calls that swallow errors on writers/flushers, and bare `return` after `WriteHeader` with explicit BAD/GOOD examples. The default's patterns are a strict subset.
- **`comment-analyzer`** — covered by `clarity-reviewer`. The clarity-reviewer's code-comment section catches restate-the-code, stale references, and exported-identifier doc style.
- **`code-simplifier`** — covered by `complexity-reviewer` (nesting depth, and/or test, redundant wrappers, generic naming) and `dead-code-reviewer` (commented-out code, partial refactors) combined. Patterns from code-simplifier that weren't already in our reviewers (redundant single-call wrappers, generic naming) have been added to `complexity-reviewer`.

The defaults `code-reviewer` (CLAUDE.md compliance + significant bugs) and `type-design-analyzer` (encapsulation, invariant design) are kept as-is — they cover scopes our pack does not.

---

# Guidelines

A reviewer pack for Go projects. Each section below is an independent reviewer prompt with its own scope, set of patterns to flag, and disposition.

## How the pack runs

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

# Agents

## test-coverage-reviewer

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

## error-handling-reviewer

Review Go code for **error handling correctness**.

**Patterns to FLAG:**

1. **Unchecked error returns:**
   ```go
   // BAD — error silently discarded
   file.Close()
   json.Unmarshal(data, &v)
   db.Exec("DELETE FROM entries")

   // GOOD
   if err := file.Close(); err != nil { ... }
   ```

2. **Errors assigned to `_`:**
   ```go
   // BAD — intentionally discarding
   _, _ = fmt.Fprintf(w, "hello")
   ```
   Only acceptable when documented with a comment explaining why.

3. **Missing error wrapping (no context):**
   ```go
   // BAD — caller has no idea where this came from
   return err

   // GOOD
   return fmt.Errorf("fetch record %s: %w", id, err)
   ```

   **When NOT to wrap:** Wrap when you're adding context the caller doesn't already have (the ID being fetched, the operation in progress). Don't wrap just to wrap — re-wrapping a sentinel at every layer (`fmt.Errorf("call A: %w", err)` → `fmt.Errorf("call B: %w", err)` → ...) lengthens the chain `errors.Is` has to traverse and produces unreadable error strings. If the calling layer adds no new information, return the error unchanged.

4. **Equality comparisons against potentially-wrapped errors:**
   ```go
   // BAD — fails the moment anyone upstream wraps with %w
   if err == ErrNotFound { ... }

   // GOOD
   if errors.Is(err, ErrNotFound) { ... }
   ```
   Same for type assertions on errors:
   ```go
   // BAD
   if pathErr, ok := err.(*os.PathError); ok { ... }

   // GOOD
   var pathErr *os.PathError
   if errors.As(err, &pathErr) { ... }
   ```
   Flag any `err == someErr` or `err.(*SomeType)` pattern against errors that might cross a wrapping boundary.

5. **Sentinel errors for caller-handleable cases:**
   Errors that callers branch on programmatically (not-found, already-exists, permission-denied, etc.) should be declared as package-level sentinels:
   ```go
   // GOOD
   var ErrNotFound = errors.New("not found")

   func GetUser(id string) (*User, error) {
       if u := lookup(id); u == nil {
           return nil, ErrNotFound
       }
       ...
   }
   ```
   Flag ad-hoc `fmt.Errorf("not found")` returns in places where the caller clearly needs to detect the case but can't, because there's no sentinel to compare against.

6. **`defer` calls that swallow errors on writers/flushers:**
   ```go
   // BAD — write may have failed; Close error tells you
   defer f.Close()              // where f is a write target
   defer gzw.Close()            // gzip.Writer flushes on Close
   defer w.(*bufio.Writer).Flush()
   ```
   For writers, capture the Close/Flush error in a named return:
   ```go
   func writeOut(...) (err error) {
       f, err := os.Create(...)
       if err != nil { return err }
       defer func() {
           if cerr := f.Close(); err == nil {
               err = cerr
           }
       }()
       ...
   }
   ```

7. **Error checks after multiple statements:**
   ```go
   // BAD — which call failed?
   a := doA()
   b := doB()
   if err != nil { ... }
   ```

8. **Bare `return` after partial writes to `http.ResponseWriter`:**
   Once headers are written, you can't change the status code. Flag cases where an error after `WriteHeader` or `Write` silently returns without at least a log line.

9. **HTTP handlers returning 200 OK while swallowing errors:**
   ```go
   // BAD — response looks successful but may be incomplete
   sessions, _ := s.db.ListSessions(repoPath, 10)
   worktrees, _ := s.db.ListActiveWorktrees(repoPath)
   writeJSON(w, http.StatusOK, map[string]any{
       "sessions":  sessions,
       "worktrees": worktrees,
   })
   ```
   A handler that calls multiple fallible operations and discards the errors returns a 200 that callers will treat as authoritative. At minimum, log every discarded error with the request context (`slog.ErrorContext(ctx, ...)`); if any of the operations is critical to the response's correctness, return 500 instead of a partial 200.

**Do NOT flag:**
- `defer rows.Close()` — standard `database/sql` pattern; rows are read-only and the Close error is informational.
- `defer resp.Body.Close()` on **read-only** HTTP response bodies — the body has been consumed; Close error is informational. (Distinct from the writer case in #6 above.)

**Require at least a log line (do not allow silent `_ =`):**
- `_ = json.NewEncoder(w).Encode(v)` in HTTP handlers. A failing encode almost always means the client disconnected or the connection broke — silent discard is a debugging black hole. Require `slog.WarnContext(ctx, "encode response", "error", err)` or equivalent. Discarding the error entirely is only acceptable with a comment explaining why logging would be worse (e.g., known noisy in load tests).

**Review approach:**
1. Search for function calls whose return values include `error` but aren't checked.
2. Look for `err` variables that are checked late or not at all.
3. Verify `fmt.Errorf` wrapping adds *new* information — flag both missing wrapping and gratuitous wrapping.
4. Check `defer` calls on writers/flushers for lost errors; allow them on read-only resources.
5. Flag `err ==` and type-assertion error checks against errors that may have been wrapped — these should use `errors.Is` / `errors.As`.
6. When a caller is clearly branching on an error condition, verify the producer exposes a sentinel (or typed error) that the caller can match against.

## complexity-reviewer

Review **production code only** for function complexity. **Skip all `*_test.go` files** — test files often have long table-driven tests and helpers that don't need the same constraints.

**Objective floor: `gocognit -over 10` must pass on every PR.** Cognitive complexity above 10 in a single function is a hard signal, independent of the subjective heuristics below. The agent should run `gocognit -over 10 ./...` (or accept CI's output) and flag every function that exceeds the threshold. Gocognit (not gocyclo) is the right tool here because it weights nested constructs and ignores flat dispatch switches — which matches the heuristics below. A flat 20-case switch scores low on gocognit; a 3-level-nested `for/if/select` scores high.

Apply these heuristics on top of the gocognit floor:

1. **"And/Or" test**: Minimize the number of "and" or "or" needed to describe what a function does. If you need multiple conjunctions, the function is doing too much.
   - Good: "This function parses a config file into a struct"
   - Bad: "This function parses the config AND validates fields AND applies defaults AND writes back to disk"

2. **One-screen rule**: Functions should fit on one screen (~50-60 lines). Longer functions are harder to reason about.
   - **Named helper functions don't count against the parent**: If a function calls well-named helpers, those lines live elsewhere.
   - Go's error handling naturally inflates line counts — use judgment. A function that's 70 lines but 20 of those are `if err != nil` blocks is fine.

3. **Extractable blocks**: If a block of code within a function has a clear purpose, consider extraction:
   - **First choice**: Package-level unexported function if reusable within the package
   - **Second choice**: Method on the relevant type
   - **Last choice**: Inline closure if truly specific to the parent

4. **Nesting depth**: Flag functions with **indent depth ≥ 4 inside the function body** (i.e., four levels of `{ }` nesting beyond the function signature itself). Deep nesting makes control flow hard to follow.
   - Go idiom: use early returns to reduce nesting (`if err != nil { return }`)
   - Example of depth 4 (flag): `func F() { for { if { switch { case x: { ... } } } } }`

5. **Redundant single-call wrappers**: A function that exists only to call one other function, with no added validation, error wrapping, or naming benefit. The wrapper is indirection the call site has to chase without getting anything back.

   ```go
   // BAD — wraps strings.ToUpper for no reason
   func toUpper(s string) string {
       return strings.ToUpper(s)
   }

   // call site:
   shouted := toUpper(name)  // why not strings.ToUpper(name)?
   ```

   Wrappers that add validation, error wrapping (`fmt.Errorf("ctx: %w", err)`), or are reused enough that the rename earns its keep are fine. The pattern to flag is single-call, single-caller, no-added-meaning.

6. **Generic identifiers in long functions**: Variables named `data`, `tmp`, `res`, `val`, `obj`, `thing` in a function with multiple of each. At the call site, the reader has to look up the definition to know what `res` actually is.

   ```go
   // BAD — three different "res" variables in one function
   func process(rows []Row) (Output, error) {
       res, err := parse(rows)
       if err != nil { return Output{}, err }
       res = filter(res)
       res, err = serialize(res)
       ...
   }
   ```

   Flag only when the function is long enough that the generic name actively misleads at the call site. Short helper functions (≤20 lines) can use generic names — the body is small enough that the name is recoverable from context.

   **Go-specific exception**: `err` is the conventional error variable name and should be used everywhere. Never flag `err`.

**Do NOT flag:**
- Test files (`*_test.go`)
- Functions that are long but linear (no branching, just sequential steps like a pipeline) **up to ~100 lines**. Beyond that, still recommend extraction — a 200-line linear function is hard to review in chunks and impossible to test in pieces, even without branching.
- `switch` statements where each case is a **short value→action mapping** (one or two statements per case, often just a return or a function call). These are inherently flat.
- Functions whose length comes primarily from Go error handling boilerplate.

**DO flag (switch-specific):**
- `switch` statements with **multi-statement case bodies that do branching logic** (each case has its own `if`/`for`/nested logic). The flatness exemption applies to dispatch tables, not to switches that are really a chain of mini-functions in disguise. If a case body would itself trigger any heuristic above, extract it to a helper.

**Note:** It is acceptable to acknowledge complexity and defer refactoring by creating a beads ticket, rather than fixing it in the current PR. This applies to heuristic findings; gocognit floor violations should be resolved in-PR unless there's a documented reason.

## concurrency-reviewer

Review Go code for **concurrency correctness**: goroutines, channels, `context.Context`, and shared state. Concurrency bugs are the highest-impact class of Go defects — they pass tests, survive code review, and surface in production as hangs, leaks, and data corruption. This reviewer is non-negotiable on any PR that touches `go`, `chan`, `select`, `sync.*`, or `context`.

**Design philosophy: "Share memory by communicating."** Channels are the only inter-goroutine communication primitive that doesn't routinely produce subtle bugs. `sync.Mutex` and `sync.RWMutex` look correct in single-function examples and almost always grow into deadlocks, lock-ordering bugs, scope creep, and copy-of-locked-value bugs once they live in production code. **Empirical position of this reviewer:** developers using sync primitives get the threading code wrong approximately 100% of the time. The bugs are subtle, survive code review, pass tests, and surface as data races and rare hangs under production load. **Any new mutex is a code smell** and must clear a high bar — not "is there a simpler alternative" but "would I defend this design choice in a postmortem."

**Top-priority pattern to FLAG — any new `sync.Mutex` / `sync.RWMutex`:**

```go
// BAD — protecting shared state with a mutex
type cache struct {
    mu sync.Mutex
    m  map[string]int
}
func (c *cache) Get(k string) int {
    c.mu.Lock()
    defer c.mu.Unlock()
    return c.m[k]
}

// GOOD — a goroutine owns the state; channels are the only interface to it
type cache struct {
    ops chan func(map[string]int)
}
func (c *cache) run() {
    m := map[string]int{}
    for op := range c.ops {
        op(m)
    }
}
```

Flag every new `sync.Mutex` or `sync.RWMutex`. The PR author must justify why channel-owned-state doesn't work for this specific case. Acceptable justifications fall into the "Tolerated uses of `sync.*`" list below; everything else should be rewritten as channel-based.

**Other patterns to FLAG:**

1. **Goroutine leaks (no termination path):**
   ```go
   // BAD — nothing ever stops this goroutine
   go func() {
       for {
           doWork()
       }
   }()

   // GOOD — terminates when ctx is canceled
   go func() {
       for {
           select {
           case <-ctx.Done():
               return
           default:
               doWork()
           }
       }
   }()
   ```
   Every `go func()` must have a clear termination path: a `context.Done()` signal, a closed input channel, or a bounded loop. Flag any goroutine launched without one.

2. **Missing `context.Context` propagation:**
   ```go
   // BAD — function does I/O but takes no ctx
   func FetchUser(id string) (*User, error) {
       return http.Get("https://api/users/" + id)
   }

   // GOOD
   func FetchUser(ctx context.Context, id string) (*User, error) {
       req, _ := http.NewRequestWithContext(ctx, "GET", "https://api/users/"+id, nil)
       return http.DefaultClient.Do(req)
   }
   ```
   Functions performing I/O (HTTP, DB, file, RPC) or long-running computation must take `ctx context.Context` as the **first parameter**. Passing `context.Background()` deep in a call tree, instead of plumbing the caller's ctx, defeats cancellation — flag this even if it compiles.

3. **Ignoring `ctx.Err()` in long loops:**
   ```go
   // BAD — loop runs to completion even after ctx canceled
   for _, item := range items {
       process(item)
   }

   // GOOD
   for _, item := range items {
       if err := ctx.Err(); err != nil {
           return err
       }
       process(item)
   }
   ```
   Flag long iterations or recursive walks that don't periodically check `ctx.Done()` or `ctx.Err()`.

4. **Channel ownership: sender closes, never receiver.**
   ```go
   // BAD — receiver closing; sender will panic on next send
   for v := range ch {
       if shouldStop(v) {
           close(ch)
           return
       }
   }
   ```
   The goroutine that *sends* on a channel owns its close. Closing from the receiver, or closing twice, panics. Flag closes that don't sit alongside the sends.

5. **Channel direction at function boundaries:**
   ```go
   // BAD — bare chan T allows callee to send AND close, intent unclear
   func consume(ch chan int) { ... }

   // GOOD — direction expresses intent and prevents misuse
   func consume(ch <-chan int) { ... }
   func produce(ch chan<- int) { ... }
   ```
   Function parameters that are channels should declare direction (`<-chan T` or `chan<- T`) unless the function genuinely both sends and receives.

6. **Buffered channels as a deadlock band-aid:**
   ```go
   // BAD — buffer size 1 chosen to "fix" a hang, not for backpressure
   results := make(chan Result, 1)
   ```
   A buffered channel is a deliberate backpressure or batching mechanism. If the buffer size is `1` and the comment says "to avoid blocking," it's almost always papering over a real synchronization bug. Flag and ask for the reasoning; require either a comment justifying the buffer size or a switch to an unbuffered channel with proper synchronization.

7. **`select` missing `<-ctx.Done()`:**
   ```go
   // BAD — blocks forever if both channels stall
   select {
   case v := <-in:
       handle(v)
   case out <- v:
       ...
   }

   // GOOD
   select {
   case v := <-in:
       handle(v)
   case out <- v:
       ...
   case <-ctx.Done():
       return ctx.Err()
   }
   ```
   Any `select` inside a function that takes a `ctx` must include a `<-ctx.Done()` case, otherwise cancellation is silently ignored.

8. **`select` with `default` that turns blocking into busy-loop:**
   ```go
   // BAD — spins the CPU
   for {
       select {
       case v := <-ch:
           handle(v)
       default:
           // nothing here; loop spins
       }
   }
   ```
   `default:` in a `select` makes it non-blocking. Inside a `for` loop, this becomes a busy wait. Flag unless the `default` branch genuinely does work and the design wants polling semantics.

9. **Shared state without synchronization:**
   ```go
   // BAD — concurrent map writes panic
   m := map[string]int{}
   for _, item := range items {
       go func(i Item) {
           m[i.Key] = i.Value
       }(item)
   }
   ```
   Maps, slice headers, and struct fields written from multiple goroutines must have a single owning goroutine that accepts operations via channel. Mutex-based protection (`sync.Mutex`, `sync.RWMutex`, `sync.Map`) is a top-priority flag (see the section before the numbered list) and requires its own justification — do not accept it as the default fix for this pattern.

10. **`sync.WaitGroup` misuse:**
    ```go
    // BAD — Add inside the goroutine races with Wait
    for _, item := range items {
        go func(i Item) {
            wg.Add(1)   // race: Wait may have already returned
            defer wg.Done()
            process(i)
        }(item)
    }

    // GOOD — Add before launch, Done deferred
    for _, item := range items {
        wg.Add(1)
        go func(i Item) {
            defer wg.Done()
            process(i)
        }(item)
    }
    ```
    `wg.Add` must be called *before* the corresponding `go` statement, and `wg.Done` must be deferred so panics still decrement the counter.

11. **Goroutines without panic recovery (long-lived workers):**
    ```go
    // BAD — a panic here kills the whole process
    go workerLoop(jobs)
    ```
    For long-lived background goroutines (workers, schedulers, consumers), wrap the body in `defer func() { if r := recover(); r != nil { ... log ... } }()`. Short-lived task goroutines tied to a request don't need this — let them propagate. Flag long-lived launches without recovery.

12. **`time.After` in a loop (timer leak):**
    ```go
    // BAD — every iteration creates a Timer that the GC can't collect until it fires
    for {
        select {
        case v := <-ch:
            handle(v)
        case <-time.After(time.Second):
            checkHealth()
        }
    }

    // GOOD
    t := time.NewTimer(time.Second)
    defer t.Stop()
    for {
        select {
        case v := <-ch:
            handle(v)
            if !t.Stop() { <-t.C }
            t.Reset(time.Second)
        case <-t.C:
            checkHealth()
            t.Reset(time.Second)
        }
    }
    ```
    Use `time.NewTimer` / `time.NewTicker` with explicit `Stop()` in any loop, especially hot loops.

13. **Loop variable capture in goroutines** (pre-Go 1.22 code):
    ```go
    // BAD on Go ≤1.21 — all goroutines see the last value of i
    for i := 0; i < 10; i++ {
        go func() { fmt.Println(i) }()
    }

    // GOOD — pass as argument
    for i := 0; i < 10; i++ {
        go func(i int) { fmt.Println(i) }(i)
    }
    ```
    Go 1.22+ fixed the loop variable scoping, so this is only a flag on repos with `go` directive < 1.22 in `go.mod`. Check `go.mod` before flagging.

**Tolerated uses of `sync.*` primitives** (the reviewer should still verify the constraint actually holds — and lean toward "rewrite it as channels" when in doubt):

- `sync.Once` — one-time package or struct initialization. Channels can do this with `close(ch)` + `<-ch`, but `Once` is hard to misuse and is the idiomatic choice.
- `sync.WaitGroup` — coordinated goroutine termination (this is coordination, not mutual exclusion). Still subject to the WaitGroup-misuse flag (#10).
- `sync.RWMutex` for **truly read-mostly, write-rare** state where writes happen at well-defined points (config reload, refresh tick) and reads happen on a hot path where channel-routing latency would be visible. "Read-mostly" alone is not enough; the latency argument must hold. If writes can happen at arbitrary moments, this isn't read-mostly and the exemption does not apply.
- `sync/atomic` for **single-word** counters (request counts, atomic flags). Anything more than a single atomic load/store/CAS should be a channel.

Each tolerated use must have a comment explaining *why* it's not a channel. "Mutex was simpler" is not an acceptable answer.

**Do NOT flag:**

- Short-lived request-scoped goroutines that return naturally (e.g., `errgroup.Group` workers that exit when their function returns).
- `context.TODO()` placeholders in clearly-marked WIP code, or at process entry points where no parent ctx exists.
- Goroutines launched by well-known libraries (`http.Server.Serve`, `errgroup.Group.Go`, `singleflight.Group.Do`) — these manage their own lifecycle.
- Channels passed to functions that genuinely both send and receive (rare but valid).

**Required tooling:**

- **`go test -race ./...` must be in CI.** The race detector catches most synchronization bugs that escape review. If CI doesn't run with `-race`, that's a P1 finding in itself — flag it on any PR that adds concurrency.
- Recommend `go vet` (built-in) and `staticcheck` for additional concurrency lints (e.g., `SA1015` for `time.Tick` leaks, `SA2000` for `WaitGroup` misuse).

**Review approach:**

1. Search the diff for `go ` (goroutine launches), `chan ` (channel decls), `select`, `sync.`, and `context.`.
2. For each `go func()`: identify the termination condition. If none, flag as a leak.
3. For each `select`: check for `<-ctx.Done()` if a ctx is in scope.
4. For each channel: identify the sender and verify it (not the receiver) closes the channel.
5. For each function taking shared state (maps, pointers, struct fields) and launching goroutines: verify mutex or channel ownership.
6. For each `time.After` inside a `for` loop: flag and suggest `time.NewTimer`.
7. Confirm `go test -race` runs in CI; flag if missing.

## resource-leak-reviewer

Review Go code for **resource leaks** in long-running services (daemons, servers, workers). Leaks are silent and cumulative — a slow fd leak or unbounded memory leak won't crash for days, then kills the process under load. Short-lived CLIs are mostly exempt; this reviewer's primary scope is processes that run for hours or longer.

**Patterns to FLAG:**

1. **`exec.Command` without `Wait()`:**
   ```go
   // BAD — process zombie, fd leak
   cmd := exec.Command("git", "fetch")
   cmd.Start()
   // ... never calls cmd.Wait()
   ```
   Every `cmd.Start()` must have a matching `cmd.Wait()` (directly or via a goroutine that reaps the process).

2. **HTTP response bodies not closed:**
   ```go
   // BAD — fd leak, connection not returned to pool
   resp, err := client.Do(req)
   if err != nil { return err }
   // forgot resp.Body.Close()
   ```
   Every successful HTTP response (`err == nil`) must have `defer resp.Body.Close()` or an explicit close on every return path.

3. **File descriptors not closed:**
   - `os.Open` / `os.Create` without matching `Close()` (use `defer`).
   - `sql.Rows` without `defer rows.Close()` — required even after a complete `for rows.Next()` loop, to cover error paths.
   - `net.Listen` / `net.Dial` without close on shutdown paths.

4. **Unbounded memory from untrusted input:**
   ```go
   // BAD — caller controls how much you read into memory
   data, _ := io.ReadAll(r)
   ```
   Use `io.LimitReader` or `http.MaxBytesReader` when the source is untrusted.

5. **`bufio.Scanner` with the default buffer:**
   The default buffer is 64KB. On longer lines `Scan()` returns false and `Err()` reports `bufio.ErrTooLong` — silently dropped if you don't check. For untrusted line-oriented input, call `scanner.Buffer(...)` with a known cap and check `scanner.Err()`.

6. **Slice growth without capacity hints:**
   When appending in a loop with a known final size, allocate up front: `s := make([]T, 0, n)`. Not strictly a leak, but causes pathological reallocation under load.

7. **Long-lived caches without eviction:**
   Package-scope or struct-scope `map[K]V` written from request handlers without size cap or eviction policy. These grow until the process OOMs.

**Cross-reference:** Goroutine leaks are covered in **concurrency-reviewer** (flag #1 of the numbered list). This reviewer focuses on non-goroutine resources (fds, memory, processes, connections).

**Do NOT flag:**
- `defer resp.Body.Close()` — standard pattern.
- Short-lived processes / commands where process exit reclaims everything.
- Bounded allocations with known sizes (`make([]T, n)` where `n` is a constant or validated input).

**Review approach:**
1. For each `os.Open`, `os.Create`, `exec.Command`, `client.Do`, `db.Query`, `net.Listen`: verify the matching close on all return paths.
2. For each `io.ReadAll` / `io.Copy` from an external source: check for an upstream size limit.
3. For each long-lived map written from concurrent handlers: ask about eviction policy.
4. Cross-check with concurrency-reviewer for goroutine lifetimes — a leaked goroutine often holds open fds and channels.

## external-process-reviewer

Review Go code that shells out to **external CLIs** (`git`, `gh`, `docker`, `kubectl`, custom binaries). These are routine failure points — network timeouts, malformed output, version skew, missing binaries.

**Patterns to FLAG:**

1. **Missing timeout / context:**
   ```go
   // BAD — hangs forever if the remote is down
   cmd := exec.Command("git", "fetch", "origin")

   // GOOD
   ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
   defer cancel()
   cmd := exec.CommandContext(ctx, "git", "fetch", "origin")
   ```
   Every `exec.Command` invoked from a long-running process (daemon, server, worker) must use `CommandContext` with a timeout. One-shot CLI tools are exempt — the user can `Ctrl-C`.

2. **Unbounded output capture:**
   ```go
   // BAD — misbehaving subprocess could return gigabytes into memory
   out, err := cmd.CombinedOutput()
   ```
   For untrusted output, attach `io.LimitReader` to `cmd.Stdout` / `cmd.Stderr`, or wrap with a bounded `bytes.Buffer` with a manual cap.

3. **Missing `cmd.Dir`:**
   ```go
   // BAD — runs in whatever cwd the process happens to have
   cmd := exec.Command("git", "status")
   ```
   For repo-relative or workspace-relative commands, set `cmd.Dir` explicitly. Implicit cwd reliance is a debugging nightmare in multi-tenant or test scenarios.

4. **No differentiation between failure modes:**
   ```go
   // BAD — timeout looks the same as non-zero exit
   if err != nil { return err }

   // GOOD — distinguish the categories
   if errors.Is(ctx.Err(), context.DeadlineExceeded) { ... }
   var exitErr *exec.ExitError
   if errors.As(err, &exitErr) {
       // exitErr.ExitCode(), exitErr.Stderr
   }
   ```
   Timeouts, non-zero exits, missing binary (`exec.ErrNotFound`), and pipe errors all surface as `err != nil`. Handle the categories you care about explicitly.

5. **Output parsing without validation:**
   - Assuming JSON output has specific fields without checking.
   - `strings.Split(out, "\n")` without handling the empty-input case (which returns `[]string{""}`, not `[]string{}`).
   - Parsing version strings without handling pre-release suffixes or unexpected formats.

6. **No stderr capture on failure:**
   ```go
   // BAD — when the command fails, the error message is just "exit status 1"
   if err := cmd.Run(); err != nil {
       return err
   }
   ```
   Capture stderr (via `cmd.Stderr = &stderrBuf`, or `exec.ExitError.Stderr` when using `Output()`) and include it in the wrapped error.

7. **`exec.LookPath` skipped or done at wrong time:**
   If a binary may not be on PATH, check at startup with `exec.LookPath("foo")` and fail fast, rather than failing on first runtime use. Flag code that assumes a binary exists without ever checking.

**Do NOT flag:**
- `exec.Command` with hardcoded args in init/setup paths that are expected to fail-fast.
- Tests that intentionally invoke commands without timeouts (the test runner enforces an overall timeout).

**Review approach:**
1. For each `exec.Command`/`exec.CommandContext`: check timeout, `cmd.Dir`, error differentiation, stderr capture.
2. For each output-parsing site: verify error handling for empty output, unexpected format, missing fields.
3. For each binary invoked: verify its presence is checked at startup or first use, not assumed.

## dead-code-reviewer

Review PRs for **dead code introduction**. Go's compiler catches unused *locals* but not unused package-level variables, functions, types, or constants. `staticcheck`'s `U1000` catches most of this; this reviewer fills the gaps — especially around exported identifiers and partial refactors that tools can't reason about.

**What to flag:**

1. **Unused package-level vars / consts**: declarations at package scope that nothing reads after the PR.
2. **Unused unexported functions and methods**: `func lowerCase(...)` that nothing in the package calls.
3. **Unused exported identifiers**: harder — they may be called by external code. Grep the workspace (and known consumers). If nothing in-tree references it and there's no reason to expect an external caller, flag for removal.
4. **Unused types**: `type foo struct {...}` with no references in the workspace.
5. **Orphaned test helpers**: functions in `*_test.go` that no test calls.
6. **Commented-out code**: blocks of code commented with `//` left in the file. Delete; git history preserves it.
7. **Partial refactors**: a PR renames `oldFn` to `newFn` at every call site but leaves the old `oldFn` definition around as a stub or duplicate.

**Review approach:**
1. For each new or modified file in the PR, check: did the PR remove usages of a package-level symbol without removing the symbol itself?
2. For renamed or moved functions, check: is the old name still defined somewhere?
3. For removed features, check: are all supporting types/vars/constants also removed?
4. Grep the workspace for each flagged symbol to confirm it's truly unreferenced. Include the grep result in the comment so the author can verify.

**Do NOT flag:**

- Exported functions that are part of a published public API (they may be called by external code).
- Interface implementations that appear unused but satisfy an interface contract (verify by checking interface method sets).
- `init()` functions.
- Build-tag-gated or platform-specific code (`_linux.go`, files with `//go:build` directives).
- Code referenced by reflection (struct fields read by `encoding/json`, `database/sql` column scanning, ORM tag-based field access). These look unused but aren't.

**Tooling cross-reference:** `staticcheck -checks=U1000` and `deadcode` from `golang.org/x/tools/cmd/deadcode` catch most cases. Assume CI runs at least one of these; this reviewer focuses on what tools miss — exported identifiers used externally, reflection-driven code, partial refactors.

## clarity-reviewer

Review markdown documentation AND Go code comments for terseness and structure. Every token costs money and attention — cut the fat, but also fix the layout.

This reviewer applies to:
- Any `.md` file in the PR — design docs, READMEs, runbooks, ADRs.
- Doc comments and inline comments in `.go` files.

**Markdown — what to check:**

1. Look at the PR diff for changes to `.md` files.
2. **Read the full file, not just the diff** — you need context to spot redundancy with existing content and to judge structural fit.
3. Examine new or modified text for word-level fat (table below) AND structural problems (next section).

**Word-level patterns to flag:**

| Verbose | Terse |
|---------|-------|
| "in order to" | "to" |
| "for the purpose of" | "to" / "for" |
| "in the event that" | "if" |
| "at this point in time" | "now" |
| "due to the fact that" | "because" |
| "it is important to note that" | (delete, just state the thing) |
| "as mentioned above/previously" | (replace with a link to the actual section; rarely just delete) |
| "This section describes how to..." | (delete, describe it directly) |

**Filler words** (`actually`, `basically`, `simply`, `really`, `just`): question, then suggest removal. These are sometimes load-bearing for tone in user-facing docs ("simply" can soften a step that sounds intimidating). Default to flagging only when the word adds no information AND the surrounding tone doesn't need softening.

**Structural patterns to flag:**

- **Wall of text**: A section longer than ~300 words without a sub-heading, list, table, or code block. Recommend breaking it up.
- **Missing TL;DR / lede**: A document longer than ~500 words that doesn't open with a 1-3 sentence summary of what it's about. Recommend adding one.
- **Missing examples**: A how-to or reference section that describes a command, API, or pattern without showing it. Recommend a code block with a real example.
- **Heading inflation**: A section with one sub-heading under it, or sub-headings that introduce a single paragraph each. Either inline the content or add siblings.
- **Voice/tense inconsistency**: A doc that mixes second-person ("you should run X") with imperative ("run X") within the same section. Pick one. Imperative is usually shorter; second-person is friendlier for onboarding.
- **Link rot phrasing**: "as mentioned above," "see the section below," "in the previous chapter" — these break when the doc is restructured. Replace with `[explicit link]` to the heading anchor.

**Go code comments — what to flag:**

1. **Restate-the-code comments:**
   ```go
   // BAD — the comment says what the code already says
   // Increment counter by 1
   counter++

   // GOOD — usually no comment needed
   counter++
   ```
   Delete comments that restate the function name or the line below them.

2. **Doc comments on exported identifiers — Go style:**
   - Required on exported funcs, types, vars, consts (per `golint` / `revive`).
   - One sentence, starting with the identifier name: `// Parse decodes the input and returns ...`
   - Avoid "This function ..." — it's implicit. Avoid restating the type that's obvious from the signature.

3. **No doc comments on unexported funcs** unless the logic is non-obvious. `// foo does X` above `func foo()` where `foo` clearly does X is noise.

4. **Block comments explaining WHY are good. Block comments explaining WHAT are bad.** A 5-line comment describing self-explanatory code should be deleted. A 5-line comment explaining a non-obvious constraint, hidden invariant, or workaround for a specific bug should stay.

5. **Stale comments**: comments referencing renamed identifiers, removed code paths, or completed TODOs. Flag any comment whose subject no longer exists in the surrounding code.

**Flag content issues if:**

- A sentence can be cut in half without losing meaning.
- The same information is stated twice in different words.
- A code comment restates what the next line of code does.
- Explanatory text explains something already obvious from context.
- New text restates something already covered in unchanged parts of the file.

**Do NOT flag:**

- Necessary detail that aids understanding.
- Examples and code blocks (these should be complete, not abbreviated).
- Repetition that serves as a deliberate reminder (e.g., "NEVER use git push" repeated for emphasis).
- Technical precision that requires specific wording.
- Tone-softening filler in user-facing docs where the alternative reads as terse-to-the-point-of-cold.
- Required doc comments on exported identifiers even if the function is simple — Go convention requires them.

**When flagging, provide:**

- The verbose text (or a description of the structural issue).
- A terse / better-structured replacement.
- Brief reason (optional, only if not obvious).
