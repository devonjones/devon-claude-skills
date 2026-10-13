# resource-leak-reviewer
**Checks:** Leaks in long-running Go services: exec.Command without Wait, unclosed files/bodies/conns, unstopped tickers/timers, unbounded maps/slices and goroutines
**Spawn when:** Diff changes .go code opening files, HTTP bodies, conns, exec processes, tickers or growing caches; skip short-lived CLI-only code
**Contents:** Patterns to FLAG · Do NOT flag · Review approach

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
