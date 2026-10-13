# complexity-reviewer
verification: mixed — the gocognit floor is proven by running gocognit -over 10 (or CI output); the heuristics (and/or test, nesting, naming) are judgement.
**Checks:** Go functions over gocognit 10, deep nesting (4+), mixed and/or responsibilities, branchy switch cases, single-call wrappers, vague names in long functions
**Spawn when:** Diff changes non-test .go files with new or edited functions; skip test-only (*_test.go) or non-Go diffs
**Contents:** Do NOT flag · DO flag (switch-specific)

Review **production code only** for function complexity. **Skip all `*_test.go` files** — test files often have long table-driven tests and helpers that don't need the same constraints.

**Objective floor: `gocognit -over 10` must pass on every PR.** Cognitive complexity above 10 in a single function is a hard signal, independent of the subjective heuristics below. The agent should run `gocognit -over 10 ./...` (or accept CI's output) and flag every function that exceeds the threshold. Gocognit (not gocyclo) is the right tool here because it weights nested constructs and ignores flat dispatch switches — which matches the heuristics below. A flat 20-case switch scores low on gocognit; a 3-level-nested `for/if/select` scores high.

Apply these heuristics on top of the gocognit floor:

1. **"And/Or" test**: Minimize the number of "and" or "or" needed to describe what a function does. If you need multiple conjunctions, the function is doing too much.
   - Good: "This function parses a config file into a struct"
   - Bad: "This function parses the config AND validates fields AND applies defaults AND writes back to disk"

2. **One-screen rule**: Functions should fit on one screen (~50-60 lines). Longer functions are harder to reason about.
   - **Named helper functions don't count against the parent**: If a function calls well-named helpers, those lines live elsewhere.
   - Go's error handling naturally inflates line counts — use judgment. A function that's 70 lines but 20 of those are `if err != nil` blocks is fine.

3. **Extractable blocks**: If a block of code within a function has a clear purpose, consider extraction:
   - **First choice**: Package-level unexported function if reusable within the package
   - **Second choice**: Method on the relevant type
   - **Last choice**: Inline closure if truly specific to the parent

4. **Nesting depth**: Flag functions with **indent depth ≥ 4 inside the function body** (i.e., four levels of `{ }` nesting beyond the function signature itself). Deep nesting makes control flow hard to follow.
   - Go idiom: use early returns to reduce nesting (`if err != nil { return }`)
   - Example of depth 4 (flag): `func F() { for { if { switch { case x: { ... } } } } }`

5. **Redundant single-call wrappers**: A function that exists only to call one other function, with no added validation, error wrapping, or naming benefit. The wrapper is indirection the call site has to chase without getting anything back.

   ```go
   // BAD — wraps strings.ToUpper for no reason
   func toUpper(s string) string {
       return strings.ToUpper(s)
   }

   // call site:
   shouted := toUpper(name)  // why not strings.ToUpper(name)?
   ```

   Wrappers that add validation, error wrapping (`fmt.Errorf("ctx: %w", err)`), or are reused enough that the rename earns its keep are fine. The pattern to flag is single-call, single-caller, no-added-meaning.

6. **Generic identifiers in long functions**: Variables named `data`, `tmp`, `res`, `val`, `obj`, `thing` in a function with multiple of each. At the call site, the reader has to look up the definition to know what `res` actually is.

   ```go
   // BAD — three different "res" variables in one function
   func process(rows []Row) (Output, error) {
       res, err := parse(rows)
       if err != nil { return Output{}, err }
       res = filter(res)
       res, err = serialize(res)
       ...
   }
   ```

   Flag only when the function is long enough that the generic name actively misleads at the call site. Short helper functions (≤20 lines) can use generic names — the body is small enough that the name is recoverable from context.

   **Go-specific exception**: `err` is the conventional error variable name and should be used everywhere. Never flag `err`.

**Do NOT flag:**
- Test files (`*_test.go`)
- Functions that are long but linear (no branching, just sequential steps like a pipeline) **up to ~100 lines**. Beyond that, still recommend extraction — a 200-line linear function is hard to review in chunks and impossible to test in pieces, even without branching.
- `switch` statements where each case is a **short value→action mapping** (one or two statements per case, often just a return or a function call). These are inherently flat.
- Functions whose length comes primarily from Go error handling boilerplate.

**DO flag (switch-specific):**
- `switch` statements with **multi-statement case bodies that do branching logic** (each case has its own `if`/`for`/nested logic). The flatness exemption applies to dispatch tables, not to switches that are really a chain of mini-functions in disguise. If a case body would itself trigger any heuristic above, extract it to a helper.

**Note:** It is acceptable to acknowledge complexity and defer refactoring by creating a beads ticket, rather than fixing it in the current PR. This applies to heuristic findings; gocognit floor violations should be resolved in-PR unless there's a documented reason.
