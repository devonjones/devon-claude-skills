# typescript-strictness-reviewer
verification: judgement — findings rest on reading the changed TS for type-system escapes; the spec asks for no command, mutation or query proof.
**Checks:** Type-safety escapes in TS: unjustified any, unsafe as casts (JSON.parse as T), @ts-ignore without reason, as NonNullable laundering, missing return types on exports.
**Spawn when:** Diff touches .ts/.tsx files (non-.d.ts). Skip when the PR only changes JavaScript files.
**Contents:** Patterns to flag · `any` without justifying comment → P2 · Unsafe `as` cast across unrelated types → P2 · `// @ts-ignore` without justification → P2 · Missing return type on exported function → P3 · Strict-null violations from `as NonNullable` casts → P2 · Don't flag · When flagging, suggest

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
