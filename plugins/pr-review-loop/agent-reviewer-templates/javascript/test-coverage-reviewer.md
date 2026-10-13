# test-coverage-reviewer
verification: evidence-query — reads package.json for the declared test runner and checks the diff for matching test files, citing the paths.
**Checks:** Missing tests: new or modified functions, bug fixes and components in JS/TS source without matching tests for the runner declared in package.json (node --test, jest, vitest, mocha).
**Spawn when:** Diff modifies non-test .js/.jsx/.ts/.tsx source. Skip when it only touches .d.ts, *.config.*, tsconfig/package.json, barrel re-exports, or test files.
**Contents:** Core rule: Every PR that modifies a non-test JS/TS file must include matching test changes. · Test runner detection · What to flag · Do NOT flag · Acceptable substitutes

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
