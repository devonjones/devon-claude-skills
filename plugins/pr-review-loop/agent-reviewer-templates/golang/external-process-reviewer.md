# external-process-reviewer
verification: judgement — os/exec findings are read from the diff; the spec asks for no command or query to prove them.
**Checks:** os/exec calls missing timeout/context, unchecked exit status or stderr, unvalidated output parsing, missing-binary handling, and shell-injection risk
**Spawn when:** Diff adds or edits .go code importing os/exec or calling exec.Command(Context); skip otherwise
**Contents:** Patterns to FLAG: Missing timeout / context; Unbounded output capture; Missing `cmd.Dir`; No differentiation between failure modes; Output parsing without validation; No stderr capture on failure; `exec.LookPath` skipped or done at wrong time · Do NOT flag · Review approach

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
