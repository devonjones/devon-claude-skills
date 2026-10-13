# importlib-resources-reviewer
verification: evidence-query — grep the diff for Path(__file__).parent and __file__.parents and check each hit loads bundled data.
**Checks:** Package data loaded via Path(__file__).parent, os.path.dirname(__file__) or __file__.parents[N] instead of importlib.resources.
**Spawn when:** Diff in .py files adds or changes use of __file__ to locate bundled data files. Skip otherwise.
**Contents:** FLAG when a file in a packaged module contains · Acceptable pattern · Do NOT flag · Review approach

Review Python code for **correct package data access**. Package data files (JSON sidecars, SQL schema, text fixtures, templates) must be loaded via `importlib.resources`, not `Path(__file__).parent`. The `__file__.parent` pattern silently breaks when a module is renamed or moved to a subpackage — the parent directory shifts and the relative path no longer resolves. The `importlib.resources` pattern is robust to package moves and works identically in dev (editable install), `pip install`, frozen builds, and Lambda zips.

**FLAG when a file in a packaged module contains:**

- `Path(__file__).parent / "data"` (or any path navigation from `__file__`)
- `os.path.dirname(__file__)` used to locate bundled data
- `__file__.parents[N]` for sibling resources

**Acceptable pattern:**

```python
from importlib import resources

data_file = resources.files("mypackage.data").joinpath("config.json")
config = json.loads(data_file.read_text())
```

For Python ≥3.9. On older versions, `importlib.resources.read_text("mypackage.data", "config.json")` is the equivalent.

**Do NOT flag:**

- `Path(__file__).parent` used for **write paths** — tests writing to a tmp dir relative to the test file, scripts emitting output next to themselves. Resources are read-only by definition.
- `__file__` references in `tests/` — tests have a stable layout and aren't packaged.
- `__file__` references in entry-point scripts (`bin/`, top-level CLI shims) that are not part of the package surface.

**Review approach:**

1. Grep PR diff for `Path(__file__).parent` and `__file__.parents`.
2. For each hit in package code, check whether the path resolves to a bundled data file. If so, recommend the `importlib.resources` form.
3. For each new package data file added under a package directory, verify it's also declared in `pyproject.toml` / `setup.cfg` `package_data` or `MANIFEST.in` (depending on the build backend) — otherwise it won't be shipped.

---
