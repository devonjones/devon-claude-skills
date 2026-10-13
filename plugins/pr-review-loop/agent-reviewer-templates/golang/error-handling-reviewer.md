# error-handling-reviewer
**Checks:** Unchecked or discarded errors (`_ =`), swallowed errors, missing %w wrapping, panics for recoverable errors, and error paths that log nothing
**Spawn when:** Diff changes .go files that call functions returning error or contain `_ =`, err handling, or panic; skip if no error-returning calls change
**Contents:** Patterns to FLAG: Unchecked error returns; Errors assigned to `_`; Missing error wrapping; Equality comparisons against potentially-wrapped errors; Sentinel errors for caller-handleable cases; `defer` calls that swallow errors on writers/flushers; Error checks after multiple statements; Bare `return` after partial writes to `http.ResponseWriter`; HTTP handlers returning 200 OK while swallowing errors · Do NOT flag · Require at least a log line (do not allow silent `_ =`) · Review approach

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
