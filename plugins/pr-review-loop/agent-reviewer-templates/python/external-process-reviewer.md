# external-process-reviewer
**Checks:** subprocess calls missing timeout=, check handling or output validation, unsafe shell=True, and unhandled missing-binary or malformed-output failures.
**Spawn when:** Diff in .py files imports or calls subprocess, os.system, or os.popen. Skip otherwise.
**Contents:** Patterns to FLAG: Missing `timeout=`; `shell=True` with any non-literal input; `subprocess.Popen` without context manager; No stderr capture on failure; Missing `cwd=`; No differentiation between failure modes; Unbounded output capture; Binary presence assumed, never checked; Output parsing without validation · Do NOT flag · Review approach

Review Python code that shells out via `subprocess`. CLI failures (timeout, malformed output, missing binary) are routine, and Python's defaults are dangerous.

**Patterns to FLAG:**

1. **Missing `timeout=`:**

   ```python
   # BAD — hangs forever if the remote is down
   subprocess.run(["git", "fetch", "origin"])

   # GOOD
   subprocess.run(["git", "fetch", "origin"], timeout=30)
   ```

   Every `subprocess.run` / `subprocess.check_call` / `subprocess.check_output` in a long-running process must have a `timeout=`.

2. **`shell=True` with any non-literal input (P1 — command injection):**

   ```python
   # BAD — command injection
   subprocess.run(f"git log {user_input}", shell=True)

   # GOOD — args as a list, no shell
   subprocess.run(["git", "log", user_input])
   ```

   `shell=True` should almost never be used. Even with `shlex.quote`, list-form args are safer.

3. **`subprocess.Popen` without context manager:**

   ```python
   # BAD
   p = subprocess.Popen(["cmd"], stdout=subprocess.PIPE)
   out, _ = p.communicate()

   # GOOD
   with subprocess.Popen(["cmd"], stdout=subprocess.PIPE) as p:
       out, _ = p.communicate()
   ```

4. **No stderr capture on failure:**

   ```python
   # BAD — when the command fails, the error message is just "Command 'X' returned non-zero exit status 1"
   result = subprocess.run(["cmd"], check=True)

   # GOOD — capture stderr so the error is useful
   result = subprocess.run(
       ["cmd"], check=True, capture_output=True, text=True
   )
   # CalledProcessError now carries .stderr
   ```

5. **Missing `cwd=`:**

   ```python
   # BAD — runs in whatever cwd the process happens to have
   subprocess.run(["git", "status"])

   # GOOD
   subprocess.run(["git", "status"], cwd=repo_path)
   ```

6. **No differentiation between failure modes:**

   ```python
   # BAD — timeout, exit code, missing binary all look the same
   try:
       result = subprocess.run([...], check=True)
   except subprocess.SubprocessError:
       return None

   # GOOD
   try:
       result = subprocess.run([...], check=True, timeout=30)
   except subprocess.TimeoutExpired:
       ...
   except subprocess.CalledProcessError as e:
       ...
   except FileNotFoundError:
       # binary missing
       ...
   ```

7. **Unbounded output capture:**

   `subprocess.run(..., capture_output=True)` reads all of stdout/stderr into memory. For untrusted commands, use a streamed `Popen` with a bounded buffer or write output to a temp file.

8. **Binary presence assumed, never checked:**

   ```python
   # BAD — assumes "myhelper" is on PATH
   subprocess.run(["myhelper", "--flag"])

   # GOOD — verify at startup, fail fast
   if shutil.which("myhelper") is None:
       raise SystemExit("myhelper not installed")
   ```

9. **Output parsing without validation:**

   - Assuming JSON output has specific fields without checking.
   - `str.split()` on output without handling empty result.
   - Parsing version strings without handling pre-release suffixes or unexpected formats.

**Do NOT flag:**

- `subprocess.run` with hardcoded args in init/setup paths designed to fail fast.
- Tests that intentionally invoke commands without timeout (test runner enforces overall timeout).

**Review approach:**

1. For each `subprocess.*`: check timeout, `shell=False`, `cwd`, error-category handling, stderr capture.
2. For each binary invoked: verify presence checked at startup (or first-use, with a clear error message).
3. Flag any `shell=True` with non-literal arguments as P1 (command injection).

---
