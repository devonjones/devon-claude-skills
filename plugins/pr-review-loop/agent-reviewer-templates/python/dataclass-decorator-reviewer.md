# dataclass-decorator-reviewer
verification: evidence-query — grep changed files for field(default and check the decorator above each enclosing class.
**Checks:** Classes using dataclasses field(default_factory=...) or field(default=...) without a @dataclass decorator, which leaves a literal Field object as the attribute.
**Spawn when:** Diff in .py files adds or edits a class body that calls field( or imports from dataclasses. Skip otherwise.
**Contents:** FLAG when a PR adds or modifies a class that uses `field(default_factory=...)` or `field(default=...)` without a `@dataclass` (or `@dataclass(...)`) decorator on the line above · Acceptable patterns (do NOT flag) · Review approach

Review Python code for **missing `@dataclass` decorators on classes that use `dataclasses.field()`**. The decorator is what makes `field()` resolve to a `Field` descriptor at class-construction time. Without it, `field(default_factory=list)` becomes a literal `Field` object as the attribute value — passing tests at import time but failing at first instance use with errors like `argument of type 'Field' is not iterable` or `'Field' object has no attribute 'append'`.

**Default severity: P1.** The bug surfaces at instance-construction or first-attribute-access time, not at import time, so type checkers and quick smoke imports won't catch it. The class is broken in production-shaped ways.

**FLAG when a PR adds or modifies a class that uses `field(default_factory=...)` or `field(default=...)` without a `@dataclass` (or `@dataclass(...)`) decorator on the line above:**

```python
from dataclasses import dataclass, field

class X:                                       # ← needs @dataclass!
    forms: list[str] = field(default_factory=list)
    citations: set[str] = field(default_factory=set)
```

```python
from dataclasses import dataclass, field

class Y:                                       # ← needs @dataclass!
    name: str = field(default="")
```

**Acceptable patterns (do NOT flag):**

- `@dataclass`-decorated classes with `field(...)` defaults — the decorator is what makes `field()` resolve correctly.
- Classes that reference `field` only as a typing annotation (`x: dataclasses.Field[int]`) without calling it.
- `attrs.field(...)` or `pydantic.Field(...)` — those have their own decorator chains (`@attrs.define`, model inheritance) and don't fit this rule's signature.
- Standalone `field()` calls used to build `dataclasses.make_dataclass()` arguments dynamically.

**Review approach:**

1. Grep new/modified files for `field(default` — every hit must be inside a `@dataclass`-decorated class (check the line above the enclosing `class` statement).
2. If a `field(...)` call is in a class without the decorator: flag it.

This rule fires almost exclusively on **extraction PRs** — when a `@dataclass` class is moved from one file into another via line-range copy, the `@dataclass` decorator line above `class X:` is often missed if the extraction range starts at `class`. Pay extra attention to refactors that copy classes between files.

---
