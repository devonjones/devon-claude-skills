# async-handling-reviewer
verification: judgement — findings rest on reading the changed code; the spec asks for no command, mutation or query proof.
**Checks:** Unawaited promises, Promise.all over order-dependent steps, async functions with no await, and setTimeout(async) callbacks that swallow rejections.
**Spawn when:** Diff touches .js/.jsx/.ts/.tsx/.mjs source adding or changing async/await, .then chains, Promise.* or timers. Skip docs-only or non-JS diffs.
**Contents:** Patterns to flag · Unawaited promise → P2 (P1 if in a request handler or test) · `Promise.all` where order matters → P2 · `async` function with no `await` → P3 · `setTimeout(async () => ...)` losing rejections → P2 · Don't flag · When flagging, suggest

Review JS/TS code for **promise and async/await misuse**. Mishandled async is the dominant silent-failure mode in modern JS — errors disappear into unhandled rejections; ordering bugs surface as flaky tests.

**Patterns to flag:**

### Unawaited promise → P2 (P1 if in a request handler or test)

```js
// BAD — promise dropped on the floor; rejection becomes unhandled
async function handleRequest(req) {
  saveAuditLog(req)  // ← no await
  return computeResponse(req)
}

// GOOD — explicit await or fire-and-forget with handling
async function handleRequest(req) {
  await saveAuditLog(req)
  return computeResponse(req)
}

// ALSO GOOD — explicit fire-and-forget with rejection handler
async function handleRequest(req) {
  saveAuditLog(req).catch(err => log.error('audit log failed', err))
  return computeResponse(req)
}
```

### `Promise.all` where order matters → P2

```js
// BAD — these have a serialization order
await Promise.all([
  createUser(data),       // must succeed before...
  sendWelcomeEmail(data), // ...this can run with user.id
])

// GOOD — explicit sequencing
const user = await createUser(data)
await sendWelcomeEmail(user)
```

### `async` function with no `await` → P3

A function marked `async` that doesn't await anything is suspect. Either it's missing an await (bug) or shouldn't be async at all (noise).

### `setTimeout(async () => ...)` losing rejections → P2

```js
// BAD — async callback's rejection vanishes
setTimeout(async () => {
  await riskyOp()
}, 1000)

// GOOD — wrap with catch
setTimeout(() => {
  riskyOp().catch(err => log.error(err))
}, 1000)
```

**Don't flag:**

- `void` operator explicitly used to discard a promise (`void riskyOp()`) — signals intentional fire-and-forget
- Top-level await in modules (legitimate use)
- `Promise.allSettled` — designed for "don't care about ordering or aggregate failure"

**When flagging, suggest:**

- The specific `await` placement
- The error-handling fallback if fire-and-forget is intended
