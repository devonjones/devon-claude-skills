# Configuration

```json
{
  "defaults_version_checked": "1.5.0",
  "disabled": [
    "silent-failure-hunter",
    "comment-analyzer",
    "code-simplifier"
  ],
  "overlap_acknowledged": {
    "test-coverage-reviewer": {
      "overlaps_with": "pr-test-analyzer",
      "reason": "Different lenses: test-coverage-reviewer enforces hard rules (touched code must be covered; detects test runner via package.json). pr-test-analyzer scores behavioral gaps on a criticality 1-10 axis. Both contribute independent signal during review loops."
    }
  }
}
```

**Why each default is disabled:**

- **`silent-failure-hunter`** — covered by `async-handling-reviewer` (catches unawaited promises, the dominant JS/TS silent-failure pattern) and `error-handling-reviewer` (empty catches, swallowed rejections). The default's patterns are a strict subset.
- **`comment-analyzer`** — covered by `clarity-reviewer`. The clarity-reviewer scopes to JSDoc accuracy and JS/TS-specific comment patterns.
- **`code-simplifier`** — JS has too many idiom variations (ES5 vs ES2015+ vs ES2022+, function vs arrow, class vs factory) for a generic simplifier to be useful. The pack's typescript-strictness-reviewer and dangerous-html-reviewer cover the genuine simplification wins (no `any`, no `eval`). Disabled to avoid noise.

The defaults `code-reviewer`, `pr-test-analyzer`, and `type-design-analyzer` are kept — they cover scopes our pack does not (CLAUDE.md compliance, behavioral coverage, encapsulation).

---

# Guidelines

A reviewer pack for JavaScript and TypeScript projects. **One pack handles both**. The pack's reviewers branch on `tsconfig.json` presence and file extension (`.js` vs `.ts`) to apply rules appropriate to the source language.

## Policy: No pushy JS → TS migration

This pack explicitly **does NOT** propose converting `.js` files to TypeScript. JS-only, TS-only, and mixed codebases are all valid. The pack reviews each file in the language it's written in. The `js-vs-ts-policy-reviewer` agent codifies this stance and pushes back if any other reviewer (or a human) attempts to flag a `.js` file simply for being JS.

If a team chooses to migrate JS → TS, that's a deliberate, scoped initiative — not something to nag-into-being on every PR.

## How the pack runs

Each reviewer runs independently and reports findings without coordination.

**Per-reviewer file scope:**

| Reviewer | Files in scope |
|----------|----------------|
| `test-coverage-reviewer` | `**/*.{js,jsx,ts,tsx,mjs,cjs}` excluding `**/*.{test,spec}.*` and `__tests__/` |
| `async-handling-reviewer` | `**/*.{js,jsx,ts,tsx,mjs,cjs}` |
| `error-handling-reviewer` | `**/*.{js,jsx,ts,tsx,mjs,cjs}` |
| `dangerous-html-reviewer` | `**/*.{jsx,tsx,js,ts}` (any file that may render or evaluate strings) |
| `typescript-strictness-reviewer` | `**/*.{ts,tsx}` ONLY (no-op on JS) |
| `js-vs-ts-policy-reviewer` | Activates when ANY review (human or agent) appears to push JS→TS migration |
| `clarity-reviewer` | `*.md` (README, docs), JSDoc/TSDoc in `.{js,ts,jsx,tsx}` |

Skip reviewers whose file scope doesn't match the PR diff.

## Tooling assumed in CI

Reviewers do not duplicate work already done by CI. Each JS/TS project running this pack should have these in CI:

- A formatter: `prettier --check .` OR a project-specific equivalent (Biome, dprint)
- A linter: `eslint .` (with `@typescript-eslint/parser` if any `.ts` files exist) — catches `no-unused-vars`, `no-undef`, `prefer-const`, etc.
- A type checker (only if TS files exist): `tsc --noEmit`
- A test runner: one of `node --test`, `jest`, `vitest`, `mocha`. Detected via `package.json`'s `scripts.test`.
- A security scanner: `npm audit` (or `pnpm audit`, `yarn npm audit`) — dependency CVE check

A missing tool is itself a **P1** finding on the first PR that brushes against its scope.

## Severity convention

Every finding must be tagged with a beads-style priority matching the pr-review-loop's Priority Mapping:

| Priority | Disposition | Examples |
|----------|-------------|----------|
| **P1** | Blocking — must fix before merge | `eval()` on user input, `dangerouslySetInnerHTML` without sanitization, unhandled async rejection in a request handler |
| **P2** | Should fix in this PR | Unawaited promise, empty catch, `any` without justifying comment (TS only), missing test for a new public function |
| **P3** | Advisory — deferrable with a beads ticket | JSDoc rot, suboptimal-but-correct async pattern, JS→TS migration suggestions (always demoted to P3 minimum by js-vs-ts-policy-reviewer, then dropped) |

A reviewer may promote or demote a specific finding from its default, but must state why.

## Output format

Findings must be structured. Use this template:

```
[<reviewer>] [<severity>] <one-line title>

File: src/path/to/file.ts:LINE
Quote:
    <1-5 lines of code being flagged>

Issue: <one or two sentences on what's wrong>
Suggested fix:
    <concrete code replacement>
Reason (optional): <only if not obvious>
```

## Deferring findings with beads

To defer a P2 or P3 finding to a follow-up:

1. Create a beads ticket capturing reviewer name, severity, file, and quote.
2. Link the ticket in the PR description or as a reply to the reviewer's comment.
3. The reviewer accepts the deferral only when the beads ticket exists.

**P1 findings are not deferrable** — they must be fixed in-PR.

---

# Agents

## test-coverage-reviewer

Review code changes to **require unit tests for all new or modified functions in `.{js,jsx,ts,tsx}` source files**.

**Core rule: Every PR that modifies a non-test JS/TS file must include matching test changes.**

**Test runner detection:**

Read `package.json` to determine which test runner the project uses. Then verify tests exist in the matching shape:

| Detected via | Test runner | Test path conventions |
|--------------|-------------|------------------------|
| `package.json` `scripts.test` contains `node --test` | Node built-in | `*.test.{js,mjs}` colocated, or `test/` dir |
| `package.json` `devDependencies` has `jest` | Jest | `*.test.{js,ts,jsx,tsx}` colocated, or `__tests__/` dir |
| `package.json` `devDependencies` has `vitest` | Vitest | `*.test.{js,ts,jsx,tsx}` or `*.spec.*`, colocated |
| `package.json` `devDependencies` has `mocha` | Mocha | `test/**/*.{js,ts}` |

If `package.json` declares no test runner, flag that as a P2 finding ("project has no test runner declared in `scripts.test`").

**What to flag:**

- New exported functions without unit tests
- Modified functions without tests verifying the modification
- Bug fixes without regression tests
- New React/Vue/Svelte components without component tests (when component-test setup exists)
- Complex logic paths in modified functions without test coverage

**Do NOT flag:**

- Type definitions only (`.d.ts` files, or pure type re-exports)
- Config files (`*.config.{js,ts}`, `tsconfig.json`, `package.json`)
- Pure index/barrel files that only re-export
- Trivial getter/setter additions

**Acceptable substitutes:**

- A beads ticket tracking the test addition (link in the PR description)
- An existing integration test that explicitly exercises the new behavior (cite the test file:line)

## async-handling-reviewer

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

## error-handling-reviewer

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

## dangerous-html-reviewer

Review JSX/TSX and string-template code for **XSS surfaces and code-injection patterns**.

**Patterns to flag:**

### `dangerouslySetInnerHTML` without sanitization → P1

```jsx
// BAD — unsanitized user input becomes HTML
<div dangerouslySetInnerHTML={{ __html: comment.body }} />

// GOOD — sanitize first
import DOMPurify from 'dompurify'
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(comment.body) }} />

// BEST — don't use dangerouslySetInnerHTML at all; render as text
<div>{comment.body}</div>
```

### `element.innerHTML = userInput` → P1

Same XSS surface as `dangerouslySetInnerHTML`. Always sanitize, or use `textContent` for text.

### `eval()` or `new Function(string)` on dynamic input → P1

Code injection. Almost no legitimate use case in app code.

### Template-string SQL → P1

```js
// BAD — SQL injection
db.query(`SELECT * FROM users WHERE id = ${userId}`)

// GOOD — parameterized query
db.query('SELECT * FROM users WHERE id = $1', [userId])
```

Most ORMs do this automatically (Prisma, Drizzle, Kysely). Raw `db.query` with template interpolation is the smell.

**Don't flag:**

- `dangerouslySetInnerHTML` with a constant string at build time (e.g., embedded SVG)
- Template literals for non-SQL string building (logs, file paths, URL construction with `encodeURIComponent`)
- `eval` inside test code that's testing eval-like behavior

**When flagging, suggest:**

- The sanitization library appropriate to the framework (DOMPurify for browser, sanitize-html for Node)
- The parameterized query syntax for the project's DB driver

## typescript-strictness-reviewer

**Activates ONLY on PRs that touch `.ts` or `.tsx` files.** No-op on PRs touching only JS.

Review TypeScript code for **type-system discipline**. The pack assumes TS is being used because the team wants type safety — patterns that opt out of that should be deliberate.

**Patterns to flag:**

### `any` without justifying comment → P2

```ts
// BAD — any hides bugs
function process(data: any) { ... }

// GOOD — narrower type
function process(data: ProcessInput) { ... }

// ALSO ACCEPTABLE — any with a comment explaining why
function fromLegacyApi(data: any /* legacy schema; see #1234 */) { ... }
```

### Unsafe `as` cast across unrelated types → P2

```ts
// BAD — bypasses the type system
const user = JSON.parse(body) as User  // ← parse returns any; cast is a lie

// GOOD — validate at the boundary
import { z } from 'zod'
const userSchema = z.object({ id: z.string(), name: z.string() })
const user = userSchema.parse(JSON.parse(body))
```

### `// @ts-ignore` without justification → P2

Always require an explanatory comment, and prefer `// @ts-expect-error` (which surfaces if the error stops existing).

### Missing return type on exported function → P3

Library-public API benefits from explicit return types (faster checker, clearer signatures). Internal functions can rely on inference.

### Strict-null violations from `as NonNullable` casts → P2

`x as NonNullable<typeof x>` is a way to launder undefined into "no, definitely defined". Real code: check, narrow, then use.

**Don't flag:**

- `any` in `// @ts-expect-error` test cases (testing error handling)
- `unknown` (the safe alternative to `any`)
- Inferred types on internal helpers
- `as const` or branded-type casts (these are type-system features, not escapes)

**When flagging, suggest:**

- The narrower type (often inferable from the surrounding code)
- The validation library appropriate to the project (zod, valibot, ts-pattern)

## js-vs-ts-policy-reviewer

**This is a policy-enforcement reviewer, not a code reviewer.** It runs on every PR and watches for OTHER reviewers' findings that push JS → TS migration. It also pushes back if a human reviewer flags a `.js` file purely for being JS.

**Core policy:**

This codebase is intentionally **language-pluralistic**. JS and TS code coexist by design. Files chosen as `.js` are reviewed as JS; files chosen as `.ts` are reviewed as TS. **No reviewer should propose converting a `.js` file to `.ts` as part of a normal code-review pass.**

**What this reviewer flags:**

When any other reviewer (or a human comment) suggests converting a file from JS to TS:

```
[js-vs-ts-policy-reviewer] [P3] JS→TS migration suggestion is out of scope

Reviewer <name> suggested converting <file.js> to TypeScript. This is
out of scope for routine code review. JS and TS coexistence is an
intentional choice in this codebase.

If a team-wide JS→TS migration is in progress, link the tracking issue
(e.g., `BD-XXX: JS→TS migration phase 2`) and the migration can be
addressed as deliberate, scoped work — not as a per-PR nag.

Downgrading this finding to P3 and recommending it be dropped from
the review loop's exit-condition consideration.
```

**Implementation note:**

This reviewer scans the PR's existing review comments (the orchestrator supplies the PR number and review-fetching tooling at spawn time) for migration-pushing language. It runs in parallel with other reviewers and only sees findings from earlier rounds; strict last-ordering is not required.

Migration-pushing language to scan for:

- "should be TypeScript"
- "convert to .ts"
- "use TypeScript instead"
- "add types" *in the context of a .js file*
- "rename .js to .ts"

When such a suggestion is found, **emit the policy comment as a standard agent-reviewer finding** (e.g., via `post-line-comment.sh` against the file/line the original suggestion targeted). The orchestrator's main loop handles linking back to the source thread and dispositioning it as P3 / out-of-scope. This reviewer does not directly reply to or resolve other reviewers' comments.

**Does NOT flag:**

- Suggestions to add JSDoc type annotations to `.js` files (that's a non-migrating type-discipline path)
- Suggestions to migrate a SPECIFIC file as part of a documented migration initiative (PR description cites the tracking issue)
- TS-specific findings on `.ts` files (those are appropriate per the typescript-strictness-reviewer)

## clarity-reviewer

Review markdown documentation, JSDoc/TSDoc blocks, and inline comments for **clarity and accuracy**.

**What to check:**

1. PR diff for changes to `.md` files (README, docs)
2. JSDoc/TSDoc blocks above exported functions/classes — present, accurate, parameters match?
3. Inline comments that no longer match the code they document (rot)
4. README sections referencing removed APIs, deprecated commands, or stale config shapes

**Flag issues if:**

- A JSDoc `@param name {string} the user's email` is on a function whose parameter is named `addresses` (mismatch)
- A README example uses an export name that no longer exists
- A `// comment` describes behavior the function no longer has
- A README walks through a workflow that no longer matches the code

**Do NOT flag:**

- JSDoc/TSDoc on internal (non-exported) functions — optional
- Comments documenting non-obvious design decisions
- README boilerplate (license, contributing)
- Deliberate repetition of critical rules (security warnings)

**When flagging, provide:**

- The stale text
- The corrected replacement
- Brief reason if not obvious
