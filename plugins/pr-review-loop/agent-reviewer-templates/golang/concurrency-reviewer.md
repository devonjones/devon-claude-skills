# concurrency-reviewer
**Checks:** New sync.Mutex/RWMutex, goroutine leaks, channel close/ownership errors, select without ctx.Done, WaitGroup misuse, time.After in loops, missing -race in CI
**Spawn when:** Diff adds or edits Go code using go statements, chan, select, sync.*, sync/atomic or context; skip otherwise
**Contents:** Top-priority pattern to FLAG — any new `sync.Mutex` / `sync.RWMutex` · Other patterns to FLAG · Do NOT flag · Required tooling · Review approach

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
