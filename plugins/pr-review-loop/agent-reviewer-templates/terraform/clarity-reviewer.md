# clarity-reviewer
**Checks:** Stale or inaccurate .md docs, variable/output descriptions and HCL comments that no longer match the resources they describe.
**Spawn when:** Diff touches .md files, or variable/output blocks' description, or comments in .tf files. Skip diffs with no docs, description or comment changes.
**Contents:** What to check · Flag issues if · Do NOT flag · When flagging, provide

Review markdown documentation, variable/output descriptions, and HCL comments for **clarity and accuracy**.

**What to check:**

1. PR diff for changes to `.md` files (README, module docs)
2. `variable` blocks' `description` fields — present and accurate?
3. `output` blocks' `description` fields — present and accurate?
4. HCL comments that no longer match the resource configuration they describe

**Flag issues if:**

- A variable description says "the user's email address" but the variable name is `notify_addresses` (plural mismatch)
- A README example uses a variable name or output name that the module no longer exposes
- A `# Comment` above a resource describes behavior the resource no longer has
- A module's README still references the old provider syntax (e.g., `region = "..."` inside a resource that no longer accepts it)

**Do NOT flag:**

- Variable descriptions that are correct but terse ("The VPC ID.") — terse is fine; verbose is the smell
- Generic README boilerplate (Apache 2.0 license header, contributing guide link)
- Comments documenting non-obvious design decisions (why a specific count, why a specific availability zone choice)

**When flagging, provide:**

- The stale text
- The corrected replacement
- Brief reason if not obvious
