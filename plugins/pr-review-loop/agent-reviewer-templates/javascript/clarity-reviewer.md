# clarity-reviewer
verification: judgement — findings rest on comparing the changed docs and comments with the code they describe; the spec asks for no command, mutation or query proof.
**Checks:** Stale docs: JSDoc/TSDoc whose params or text no longer match the code, comments describing removed behavior, README examples naming removed APIs or old config.
**Spawn when:** Diff changes .md files, or JSDoc/TSDoc or comments on exported JS/TS functions or classes, or alters an API/config that README or docs describe.
**Contents:** What to check · Flag issues if · Do NOT flag · When flagging, provide

Review markdown documentation, JSDoc/TSDoc blocks, and inline comments for **clarity and accuracy**.

**What to check:**

1. PR diff for changes to `.md` files (README, docs)
2. JSDoc/TSDoc blocks above exported functions/classes — present, accurate, parameters match?
3. Inline comments that no longer match the code they document (rot)
4. README sections referencing removed APIs, deprecated commands, or stale config shapes

**Flag issues if:**

- A JSDoc `@param name {string} the user's email` is on a function whose parameter is named `addresses` (mismatch)
- A README example uses an export name that no longer exists
- A `// comment` describes behavior the function no longer has
- A README walks through a workflow that no longer matches the code

**Do NOT flag:**

- JSDoc/TSDoc on internal (non-exported) functions — optional
- Comments documenting non-obvious design decisions
- README boilerplate (license, contributing)
- Deliberate repetition of critical rules (security warnings)

**When flagging, provide:**

- The stale text
- The corrected replacement
- Brief reason if not obvious
