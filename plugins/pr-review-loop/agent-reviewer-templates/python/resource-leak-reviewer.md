# resource-leak-reviewer
verification: judgement — findings come from reading each open, socket, connection and Popen site; no command is asked for.
**Checks:** open() without context manager and unclosed sockets, DB connections or processes in long-running code, especially resources reopened in loops.
**Spawn when:** Diff in .py files adds open(), socket, DB connect, Popen, session or client creation. Skip otherwise.
**Contents:** Patterns to FLAG: `open()` without a context manager; `subprocess.Popen` without `.wait()` or context manager; Database connections not closed; HTTP responses not closed; Unbounded `io.read()` / `response.content` from untrusted sources; `functools.lru_cache` without `maxsize=` on unbounded key spaces; Long-lived module-level dicts/sets as caches without eviction; `threading.Thread` / `multiprocessing.Process` not joined or daemonized correctly; `aiohttp.ClientSession` constructed per request; `tempfile.NamedTemporaryFile(delete=False)` without explicit cleanup; Manual `try/finally` chains where `contextlib.ExitStack` would do; Long-lived caches keyed by object identity without `weakref` · Do NOT flag · Review approach

Review Python code for **resource leaks** in long-running processes (daemons, servers, workers, CLI tools that process large batches). Python's GC is forgiving but not magic — file handles, sockets, database connections, and processes can pile up faster than GC frees them, especially in async code where the same coroutine reopens resources in a loop.

**Patterns to FLAG:**

1. **`open()` without a context manager:**

   ```python
   # BAD — file handle relies on GC; on CPython may stay open indefinitely if a reference survives
   f = open(path)
   data = f.read()

   # GOOD
   with open(path) as f:
       data = f.read()
   ```

2. **`subprocess.Popen` without `.wait()` or context manager:**

   ```python
   # BAD — zombie process, fd leak
   p = subprocess.Popen(["git", "fetch"])
   # ... no .wait()
   ```

   Use `subprocess.run(...)` for one-shot commands, or `with subprocess.Popen(...) as p:` for streaming I/O.

3. **Database connections not closed:**

   ```python
   # BAD — connection leaked
   conn = sqlite3.connect(path)
   cursor = conn.execute(query)

   # GOOD
   with sqlite3.connect(path) as conn:
       cursor = conn.execute(query)
   ```

   Note: the `sqlite3` connection context manager commits/rolls back but does NOT close — close explicitly if the connection isn't intended to outlive the block.

4. **HTTP responses not closed:**

   ```python
   # BAD — connection held by the response object
   resp = requests.get(url)
   data = resp.json()
   ```

   Use `with requests.get(url, stream=True) as resp:` for streamed responses, or a session context manager. For `httpx`, always use `with httpx.Client() as client:`.

5. **Unbounded `io.read()` / `response.content` from untrusted sources:**

   ```python
   # BAD — caller controls how much memory you allocate
   data = resp.content  # may be gigabytes
   ```

   For untrusted sources, check `Content-Length` first, set a max size on the HTTP client, or stream with bounded chunks.

6. **`functools.lru_cache` without `maxsize=` on unbounded key spaces:**

   ```python
   # BAD — cache grows without bound when keys come from external input
   @functools.lru_cache(maxsize=None)
   def fetch(user_id):
       ...
   ```

   Set `maxsize=` to a sensible cap when keys derive from external input. Or use `cachetools.TTLCache`.

7. **Long-lived module-level dicts/sets as caches without eviction:**

   ```python
   # BAD — grows forever as long as the process is up
   _CACHE: dict[str, Any] = {}

   def serve(req):
       _CACHE[req.key] = compute(req)
   ```

   Use `functools.lru_cache`, `cachetools`, or an explicit eviction policy.

8. **`threading.Thread` / `multiprocessing.Process` not joined or daemonized correctly:**

   A non-daemon thread blocks process exit forever. A daemon thread leaves resources mid-cleanup. See `concurrency-reviewer` for the deeper rules; this reviewer flags the leak shape (process can't exit, or worker dies with files half-written).

9. **`aiohttp.ClientSession` constructed per request:**

   ```python
   # BAD — defeats connection pooling and leaks sockets
   async def fetch(url):
       async with aiohttp.ClientSession() as session:
           return await session.get(url)
   ```

   Construct a session once at module/app level and reuse it.

10. **`tempfile.NamedTemporaryFile(delete=False)` without explicit cleanup:**

    `delete=False` is sometimes necessary (the file is consumed by a subprocess after the Python writer closes it), but always pair it with `finally: os.unlink(name)` or use `tempfile.TemporaryDirectory()` for batches.

11. **Manual `try/finally` chains where `contextlib.ExitStack` would do:**

    ```python
    # BAD — fragile when N varies, breaks on intermediate failure
    f1 = open(a)
    try:
        f2 = open(b)
        try:
            f3 = open(c)
            try:
                ...
            finally:
                f3.close()
        finally:
            f2.close()
    finally:
        f1.close()

    # GOOD — ExitStack handles unwinding even when count varies at runtime
    from contextlib import ExitStack
    with ExitStack() as stack:
        files = [stack.enter_context(open(p)) for p in paths]
        ...
    ```

    Flag manual try/finally chains protecting two or more resources, especially when the resource count is dynamic. `ExitStack` is the right pattern.

12. **Long-lived caches keyed by object identity without `weakref`:**

    ```python
    # BAD — cache pins the keys in memory forever, prevents GC
    _cache: dict[SomeObject, Result] = {}

    # GOOD — entries vanish when the key is GC'd elsewhere
    import weakref
    _cache: weakref.WeakKeyDictionary[SomeObject, Result] = weakref.WeakKeyDictionary()
    ```

    When a cache is keyed by an object (rather than a primitive ID or string), plain `dict` holds a strong reference to the key, preventing the key from being garbage collected even after the rest of the program has dropped its references. `weakref.WeakKeyDictionary` (for object keys) and `weakref.WeakValueDictionary` (for object values) let cache entries evict naturally when the underlying objects are no longer reachable.

**Cross-reference:** Task leaks in async code (`asyncio.create_task` without keeping a reference) are covered in `concurrency-reviewer`. This reviewer focuses on non-task resources (fds, sockets, processes, memory).

**Do NOT flag:**

- `pathlib.Path.read_text()` / `read_bytes()` — closes the file internally.
- `with` blocks that close resources in normal flow.
- Bounded `functools.lru_cache` with an explicit `maxsize`.
- One-shot scripts that exit shortly after the work (CLIs, build scripts) — the leak shape doesn't apply when the process exits in seconds.

**Review approach:**

1. For each `open()`, `subprocess.Popen`, `sqlite3.connect`, `psycopg2.connect`, `requests.get`, `httpx.get`: verify a `with` block or explicit close on every return path.
2. For each `.read()` / `.content` / `.text` from external input: verify a size bound upstream.
3. For each module-level `dict` / `set` written from multiple call sites: ask about eviction.
4. For each `lru_cache`: verify `maxsize` is set when the key space is external.

---
