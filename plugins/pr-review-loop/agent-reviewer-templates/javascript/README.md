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
