# typing-consistency-reviewer
verification: judgement — findings come from reading annotations in files that opted in; no command is asked for.
**Checks:** Inconsistent annotations in files that already use typing: unannotated params/returns, mixed old and new syntax, misused Any, stale typing imports.
**Spawn when:** Diff in .py files that already contain annotations, typing imports or __future__ annotations. Skip wholly untyped files.
**Contents:** Scope rule · Patterns to FLAG (only when the file is in scope): `# type; Half-typed function signatures; `Any` as an escape hatch when the type is inferable; `typing.cast` used to silence an error rather than narrow a type; Inconsistent `Optional[X]` vs `X | None` within the same file; Completely-unannotated functions in an otherwise-typed file · Do NOT flag · Review approach

Review Python type annotations for **consistency within files that have opted in to typing**. This reviewer does NOT push untyped codebases toward typing — Python's flexibility is a feature, and gratuitous type ceremony adds complexity for little gain. But once a file opts in, the standards apply: half-typed code is worse than no types, because it gives a false signal to type checkers and human readers alike.

**Scope rule:** A file is in scope when ANY of the following is true:

- At least one function parameter, return value, variable, or class attribute is annotated.
- The file has `from __future__ import annotations`.
- The file imports from `typing` and the import is used (not dead).

Files with zero annotations are out of scope. Leave them alone — the choice not to type is a legitimate design decision.

**Patterns to FLAG (only when the file is in scope):**

1. **`# type: ignore` without an error code and reason comment:**

   ```python
   # BAD — silent escape hatch, no paper trail
   result = some_func(x)  # type: ignore

   # GOOD — narrow ignore with documented reason
   result = some_func(x)  # type: ignore[arg-type]  # x is dynamically validated upstream
   ```

   The `[error-code]` form makes the ignore narrow (it only suppresses that specific error, so unrelated type errors still surface). The reason comment makes the choice reviewable later.

2. **Half-typed function signatures:**

   ```python
   # BAD — some params annotated, some not
   def foo(x: int, y, z: str) -> bool:
       ...

   # BAD — params annotated, return type missing
   def foo(x: int, y: str):
       return x > 0

   # GOOD — fully annotated
   def foo(x: int, y: str) -> bool:
       return x > 0

   # GOOD — explicit None return
   def emit(event: Event) -> None:
       ...
   ```

   Either all parameters are annotated and the return type is present, or the function is unannotated. Mixed signatures are the worst of both worlds: type checkers complain unhelpfully, and human readers can't tell whether the missing types are deliberate or forgotten.

3. **`Any` as an escape hatch when the type is inferable:**

   ```python
   # BAD — function body clearly expects str
   def upper(x: Any) -> Any:
       return x.upper()

   # GOOD
   def upper(x: str) -> str:
       return x.upper()
   ```

   `Any` is acceptable for genuinely generic code (a logger formatter that accepts any object, a serializer's input, a `**kwargs` passthrough). It is **not** acceptable as a way to dodge type-checker complaints when the actual type is obvious from the function body or its callers.

4. **`typing.cast` used to silence an error rather than narrow a type:**

   ```python
   # BAD — cast lies about the type to silence mypy
   value = cast(int, request.json["count"])  # could be anything from JSON

   # GOOD — narrow a known-broader type, with validation upstream
   raw = request.json["count"]
   if not isinstance(raw, int):
       raise ValidationError("count must be int")
   value = raw  # mypy now knows raw is int, no cast needed

   # GOOD — cast when the runtime guarantee is real but the type checker can't see it
   value = cast(int, validated_int_from_jsonschema)
   ```

   `cast` is for telling the type checker something it can't infer but you can prove. Using it to bypass a real type error is a future debugging problem.

5. **Inconsistent `Optional[X]` vs `X | None` within the same file:**

   ```python
   # BAD — same file
   def find(name: str) -> Optional[Entry]: ...
   def find_all(name: str) -> list[Entry] | None: ...
   ```

   Pick one form per file. This reviewer does NOT enforce a project-wide choice — `Optional` works everywhere `typing` does; `X | None` requires Python ≥3.10 (PEP 604) or `from __future__ import annotations`. Local consistency is what matters; suggest the form already dominant in the file.

6. **Completely-unannotated functions in an otherwise-typed file:**

   ```python
   # File has typed functions throughout, then:
   def helper(x, y):  # BAD — drops the type discipline mid-file
       return x + y
   ```

   In a file that opts in to types, every function should be annotated. Either annotate this one, or move it to an untyped module if you genuinely don't want to type it.

**Do NOT flag:**

- Files with zero annotations — out of scope entirely. Untyped Python is a legitimate choice.
- `Any` when the function is genuinely generic over arbitrary types (loggers, serializers, deepcopy-style helpers, `**kwargs` passthroughs).
- Missing type annotations on public APIs as a universal rule.
- Cross-version concerns (`from __future__ import annotations` discipline, `list` vs `List`) — that's a project-level architectural choice and belongs in the project's own AGENT-REVIEWERS.md.
- Type-checker errors themselves — those should already be P1 from CI's mypy/pyright run, not from this reviewer.
- Project-wide enforcement of `Optional` vs `X | None` — only local-to-file consistency matters here.
- `# type: ignore` with the `[error-code]` form and a brief reason comment.

**Review approach:**

1. For each `*.py` file in the diff, determine whether it's in scope (any annotation present anywhere in the file).
2. If in scope, scan for the six patterns above.
3. For `# type: ignore` hits, verify both an error code in brackets AND a reason comment are present.
4. For half-typed signatures, propose the full annotation in the suggested fix.
5. For `Any` hits, look at the function body — if the actual type is obvious from how the parameter is used, suggest the concrete type.
6. For `Optional` vs `X | None` drift within a file, suggest the form already dominant.

This reviewer enforces "if you opt in, do it well" rather than "everyone must opt in." The line between typed and untyped is a project-level decision; the consistency of typing *within* a file is universal hygiene.

---
