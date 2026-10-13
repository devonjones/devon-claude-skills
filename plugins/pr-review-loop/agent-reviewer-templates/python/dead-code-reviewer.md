# dead-code-reviewer
**Checks:** Unused functions, classes, constants, exports, fixtures and params; commented-out code; stale __all__; if False branches; orphaned old names after partial refactors.
**Spawn when:** Diff in .py files removes call sites, renames or moves symbols, deletes features, or adds module-level definitions or __init__ exports.
**Contents:** What to flag · Review approach · Do NOT flag

Review PRs for **dead code introduction**. Python's runtime has no compile-time check for unused symbols. `vulture` and `ruff` (`F401` unused imports, `F841` unused variables) catch most cases; this reviewer fills the gaps — especially around public APIs, reflection-driven code, and partial refactors.

**What to flag:**

1. **Unused module-level functions, classes, constants** that nothing in the package references.
2. **Unused exported names** in a package's `__init__.py` that nothing imports (verify by grepping the whole workspace).
3. **Unused fixtures in `conftest.py`** that no test references.
4. **Commented-out code** — delete; git history preserves it.
5. **Partial refactors** — old function name still defined after every call site moved to a new name.
6. **Stale `__all__` entries** referring to names that no longer exist (these `AttributeError` at import time when consumed).
7. **Unused parameters with default values** (especially after a refactor that stopped passing them).
8. **`if False:` / `if True:` / `if 0:` dead branches** — these typically appear in code that's been partially commented out as a refactor scaffold. Delete the branch; git history preserves it.
9. **`def f(): pass` stubs with no implementation and no callers.** Either should be `@abstractmethod` on an ABC (and implemented in subclasses) or removed. A `pass`-only function that's never called is dead weight; a `pass`-only function that's called silently no-ops without telling anyone.

**Review approach:**

1. For each new/modified file, check: did the PR remove call sites without removing the called function?
2. For renamed/moved functions, check: is the old name still defined somewhere?
3. For removed features, check: are all supporting helpers and constants also removed?
4. Grep the workspace for each flagged symbol to confirm it's truly unreferenced. Include the grep result in the comment so the author can verify.

**Do NOT flag:**

- **Reflection-driven code**: SQLAlchemy mapped columns, Pydantic model fields, Click command callbacks (decorator side-effects), pytest fixtures (discovered by name), marshmallow schemas. These look unused but aren't.
- Code referenced only via `getattr` / `hasattr` / `importlib.import_module` (search for the bare string, not just the symbol).
- Public API functions/classes with no internal callers (they may be called by external packages — verify against the package's documented surface or `__all__`).
- `__init__.py` re-exports that look unused but are part of the package's documented public surface.
- Test helpers discovered automatically (`conftest.py` fixtures used implicitly via name).
- Build-tag-gated or platform-specific code (e.g., `if sys.platform == "win32":` branches).

**Tooling cross-reference:** `vulture` catches most of this; assume CI runs it. This reviewer focuses on what vulture misses — public APIs, reflection-driven code (vulture's whitelist mechanism handles some of this if configured), and partial refactors that vulture sees as "still has callers" because the call site is in the same PR.

---
