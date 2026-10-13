# complexity-reviewer
verification: mixed — McCabe over 10 is proven by running ruff C901; the and/or, parameter-count and naming heuristics are judgement.
**Checks:** Production functions with McCabe complexity over 10, too many and/or duties, >5 positional params, >20 public methods, pass-through wrappers, misleading generic names.
**Spawn when:** Diff adds/changes .py functions or classes outside tests/. Skip test-only or non-Python diffs.
**Contents:** Do NOT flag · DO flag (match/elif-specific)

Review **production code only** for function complexity. **Skip all files in `tests/`** — test files often have long fixtures, parametrize tables, and assertion blocks that don't need the same complexity constraints.

**Objective floor: `ruff check --select C901 --max-complexity 10 .` must pass on every PR.** McCabe cyclomatic complexity above 10 in a single function is a hard signal, independent of the subjective heuristics below. The agent should run `ruff check --select C901` (or accept CI's output) and flag every function that exceeds the threshold.

Apply these heuristics on top of the ruff floor:

1. **"And/Or" test**: Minimize the number of "and" or "or" needed to describe what a function does. If you need multiple conjunctions, the function is doing too much.
   - Good: "This function extracts traits from a stat block."
   - Bad: "This function extracts traits AND normalizes them AND adds links AND handles edge cases for variants."

2. **One-screen rule**: Functions should fit on one screen (~50–60 lines). Longer functions are harder to reason about.
   - **Internal functions don't count**: When a function contains internal helper `def`s, the lines of those helpers do NOT count against the parent's line limit. Only the "main body" lines count.
   - **Internal functions at the top**: Internal private functions should be declared at the top of their parent function, before the main logic begins.

3. **Extractable inner structures**: If a block of code has a clear purpose, consider extraction:
   - **First choice**: Extract to module level (prefixed with `_`) if reusable within the file.
   - **Second choice**: Extract to a sibling helper module within the same package.
   - **Last choice**: Keep as an internal function if truly tied to the parent's context.

4. **Nesting depth**: Flag functions with **indent depth ≥ 4 inside the function body** (four levels of indentation beyond the `def` line). Deep nesting makes control flow hard to follow.
   - Python idiom: use early returns to reduce nesting (`if not x: return`).
   - Example of depth 4 (flag): `def f():\n    for x in xs:\n        if x:\n            with open(...) as f:\n                for line in f: ...`

5. **Parameter count**: Flag functions with more than **5 positional parameters**. Long parameter lists are a complexity smell — refactor to a config object (dataclass, TypedDict), keyword-only args (`def foo(*, a, b, c)`), or split the function. `ruff` catches some of this via `PLR0913` (default threshold 5); flag here even if ruff isn't configured for it.

6. **Class size (public method count)**: Flag classes with **more than 20 public methods** (`ruff PLR0904` default). Count only public methods — methods without a leading underscore and excluding dunders (`__init__`, `__eq__`, `__hash__`, etc.). **Private helper methods (`_foo`) do NOT count** — extracting helpers as private methods is exactly the pattern the rest of this reviewer encourages, so penalizing them would be self-contradictory. Dunders are protocol implementations, not logic.

   The class-size rule is **advisory (P3)**: when triggered, ask whether the public methods cluster around a single responsibility. All variations on one concern (different serializations of the same object, different query methods on the same store) → fine. Multiple unrelated concerns (serialize + persist + render + authorize) → suggest splitting the class along the responsibility lines.

7. **Nested ternaries**: Chained `x if a else y if b else z` is hard to read once you go past one level. Recommend `match`/`case`, an `if/elif/else` chain, or a dict-dispatch lookup.

   ```python
   # BAD — three levels, eyes can't follow
   status = "critical" if cpu > 90 else "warning" if cpu > 70 else "ok" if cpu > 0 else "unknown"

   # GOOD
   if cpu > 90:
       status = "critical"
   elif cpu > 70:
       status = "warning"
   elif cpu > 0:
       status = "ok"
   else:
       status = "unknown"
   ```

   A single ternary (`x if a else y`) is fine; flag at the second `if/else` inside an expression.

8. **Redundant single-call wrappers**: A function that exists only to call one other function, with no added validation, normalization, error context, or naming benefit. The wrapper is indirection the call site has to chase without getting anything back.

   ```python
   # BAD — wraps str.upper() for no reason
   def to_upper(s):
       return s.upper()

   # call site:
   shouted = to_upper(name)  # why not name.upper()?
   ```

   Wrappers that add validation, normalization, error context, or are reused enough that the rename earns its keep are fine. The pattern to flag is single-call, single-caller, no-added-meaning.

9. **Generic identifiers in long functions**: Variables and functions named `data`, `temp`, `result`, `value`, `obj`, `thing` in a function with multiple of each. At the call site, the reader has to look up the definition to know what `result` actually is.

   ```python
   # BAD — three different "result" variables
   def process(rows):
       result = parse(rows)
       result = filter(result)
       result = serialize(result)
       return result

   # GOOD — each transformation has a meaningful name
   def process(rows):
       parsed = parse(rows)
       filtered = filter(parsed)
       serialized = serialize(filtered)
       return serialized
   ```

   Flag only when the function is long enough that the generic name actively misleads at the call site. Short helper functions (≤10 lines) can use generic names — the body is small enough that the name is recoverable from context.

**Do NOT flag:**

- Test files (`tests/`).
- Functions that are long but linear (no branching, just sequential transformations like a parser pipeline) **up to ~100 lines**. Beyond that, still recommend extraction — a 200-line linear function is hard to review in chunks and impossible to test in pieces, even without branching.
- `match` / `if-elif-else` chains where each branch is **a short value→action mapping** (one or two statements per branch, often just a return or a function call). These are inherently flat.
- Functions whose length comes from a single long parametrize table or a single long literal data structure (dict/list).

**DO flag (match/elif-specific):**

- `match` statements or `if-elif-else` chains with **multi-statement branch bodies that do branching logic** (each branch has its own `if`/`for`/`try`). The flatness exemption applies to dispatch tables, not to chains of mini-functions in disguise. If a branch body would itself trigger any heuristic above, extract it to a helper.

**Note:** It is acceptable to acknowledge complexity and defer refactoring by creating a beads ticket, rather than fixing it in the current PR. This applies to heuristic findings; ruff `C901` violations should be resolved in-PR unless there's a documented reason.

---
