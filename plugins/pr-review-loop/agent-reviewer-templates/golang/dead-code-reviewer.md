# dead-code-reviewer
verification: evidence-query — each flagged symbol is proven unreferenced by a workspace grep whose result is quoted in the comment.
**Checks:** Unused package-level vars/consts/functions/types, unexported-but-uncalled methods, orphaned exported identifiers, and leftovers from partial refactors
**Spawn when:** Diff in .go files deletes callers, renames/moves identifiers, or adds new package-level declarations
**Contents:** What to flag: Unused package-level vars / consts; Unused unexported functions and methods; Unused exported identifiers; Unused types; Orphaned test helpers; Commented-out code; Partial refactors · Review approach · Do NOT flag

Review PRs for **dead code introduction**. Go's compiler catches unused *locals* but not unused package-level variables, functions, types, or constants. `staticcheck`'s `U1000` catches most of this; this reviewer fills the gaps — especially around exported identifiers and partial refactors that tools can't reason about.

**What to flag:**

1. **Unused package-level vars / consts**: declarations at package scope that nothing reads after the PR.
2. **Unused unexported functions and methods**: `func lowerCase(...)` that nothing in the package calls.
3. **Unused exported identifiers**: harder — they may be called by external code. Grep the workspace (and known consumers). If nothing in-tree references it and there's no reason to expect an external caller, flag for removal.
4. **Unused types**: `type foo struct {...}` with no references in the workspace.
5. **Orphaned test helpers**: functions in `*_test.go` that no test calls.
6. **Commented-out code**: blocks of code commented with `//` left in the file. Delete; git history preserves it.
7. **Partial refactors**: a PR renames `oldFn` to `newFn` at every call site but leaves the old `oldFn` definition around as a stub or duplicate.

**Review approach:**
1. For each new or modified file in the PR, check: did the PR remove usages of a package-level symbol without removing the symbol itself?
2. For renamed or moved functions, check: is the old name still defined somewhere?
3. For removed features, check: are all supporting types/vars/constants also removed?
4. Grep the workspace for each flagged symbol to confirm it's truly unreferenced. Include the grep result in the comment so the author can verify.

**Do NOT flag:**

- Exported functions that are part of a published public API (they may be called by external code).
- Interface implementations that appear unused but satisfy an interface contract (verify by checking interface method sets).
- `init()` functions.
- Build-tag-gated or platform-specific code (`_linux.go`, files with `//go:build` directives).
- Code referenced by reflection (struct fields read by `encoding/json`, `database/sql` column scanning, ORM tag-based field access). These look unused but aren't.

**Tooling cross-reference:** `staticcheck -checks=U1000` and `deadcode` from `golang.org/x/tools/cmd/deadcode` catch most cases. Assume CI runs at least one of these; this reviewer focuses on what tools miss — exported identifiers used externally, reflection-driven code, partial refactors.
