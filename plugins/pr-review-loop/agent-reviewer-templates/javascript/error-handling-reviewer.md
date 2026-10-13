# error-handling-reviewer
verification: judgement — findings rest on reading the changed catch and promise code; the spec asks for no command, mutation or query proof.
**Checks:** Swallowed errors: empty catch, catch returning null without a contract comment, throw new Error(err.message) losing cause, and leaf .then with no .catch.
**Spawn when:** Diff adds or edits try/catch, .catch or .then chains in .js/.jsx/.ts/.tsx/.mjs source. Skip diffs with no error-handling code and test-only changes.
**Contents:** Patterns to flag · Empty catch → P2 (P1 if in a network/IO path) · `try { ... } catch (err) { return null }` without comment → P2 · Loss of error type info (`throw new Error(err.message)`) → P3 · `.then(...)` without `.catch(...)` on a leaf promise → P2 · Don't flag · When flagging, suggest

Review try/catch blocks and promise rejection handlers for **error-swallowing patterns**.

**Patterns to flag:**

### Empty catch → P2 (P1 if in a network/IO path)

```js
// BAD — error vanishes; no log, no rethrow
try {
  riskyOp()
} catch {}

// GOOD — at minimum, log
try {
  riskyOp()
} catch (err) {
  log.error('riskyOp failed', err)
}
```

### `try { ... } catch (err) { return null }` without comment → P2

Returning null/undefined on error masks the failure. Acceptable when the caller treats null as "operation didn't happen" by contract — but the code should comment that contract.

### Loss of error type info (`throw new Error(err.message)`) → P3

```js
// BAD — stack trace and cause are lost
try {
  await fetch(url)
} catch (err) {
  throw new Error(`fetch failed: ${err.message}`)
}

// GOOD — preserve via `cause`
try {
  await fetch(url)
} catch (err) {
  throw new Error(`fetch failed`, { cause: err })
}
```

### `.then(...)` without `.catch(...)` on a leaf promise → P2

The terminal promise in a chain needs a `.catch`, otherwise rejections become unhandled.

**Don't flag:**

- `try` blocks that rethrow with context (`throw new Error('context', { cause: err })`)
- `catch (err) { /* expected — see comment above */ ... }` with an explicit comment
- Test code that uses `expect(() => ...).toThrow()` patterns

**When flagging, suggest:**

- The specific log/rethrow shape
- The `cause`-preserving rewrite for context-add cases
