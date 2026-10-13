# import-reviewer
**Checks:** Function-level imports, import-order violations when CI lacks ruff, and other PEP 8 import placement rules ruff does not enforce.
**Spawn when:** Diff in .py files adds or changes import or from-import lines, including imports inside functions.
**Contents:** Patterns to FLAG · Review approach

Review Python imports for **PEP 8 compliance and placement discipline**. Most import-ordering issues are caught by `ruff check --select I`; this reviewer focuses on the structural rules ruff doesn't enforce.

**Patterns to FLAG:**

1. **Function-level imports:**

   ```python
   # BAD — import inside a function
   def parse(path):
       import json
       return json.loads(open(path).read())

   # GOOD — top of file
   import json

   def parse(path):
       with open(path) as f:
           return json.load(f)
   ```

2. **Import order violations** (caught by `ruff I001` — flag only if CI doesn't run ruff):

   PEP 8 ordering: stdlib → third-party → local, blank line between groups.

3. **`from X import *`** (wildcard imports):

   ```python
   # BAD — pollutes namespace, defeats static analysis
   from module import *
   ```

   Exceptions: `__init__.py` re-exports where `__all__` is also defined.

4. **Relative imports past package boundaries:**

   ```python
   # BAD — fragile, breaks under restructuring
   from ...other_package import thing
   ```

   Use absolute imports for cross-package references.

**Acceptable function-level imports** (each requires a comment explaining why):

- Optional dependencies wrapped in `try`/`except ImportError` — the dep may not be installed.
- Imports that genuinely break a circular dependency. The comment should name the cycle.
- Imports deferred to minimize CLI startup latency (heavy modules like `numpy`, `pandas`, `torch`). The comment should justify the latency budget.

**Review approach:**

1. Grep for `^\s+import` and `^\s+from` (indented import statements) — these are function-level.
2. For each, check if it falls into an acceptable exception. If yes, verify the documenting comment is present.
3. Cross-check that `ruff check --select I` runs in CI; if not, also flag import-order violations.

---
