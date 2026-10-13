# lifecycle-reviewer
verification: evidence-query — reads the diff for removed prevent_destroy and added ignore_changes or create_before_destroy, and greps the module for the resource's name and references.
**Checks:** Risky lifecycle blocks: removed prevent_destroy on stateful resources, ignore_changes = all, create_before_destroy on name-bound resources.
**Spawn when:** Diff adds, removes or edits a lifecycle { } block in .tf files (prevent_destroy, ignore_changes, create_before_destroy). Skip otherwise.
**Contents:** Patterns to flag · Removing `prevent_destroy` from a stateful resource → P1 · Adding `ignore_changes` that masks drift → P2 · `create_before_destroy = true` on a resource with hard external references → P2 · Don't flag · When flagging, suggest

Review `lifecycle { ... }` blocks for **dangerous removals or additions**.

**Patterns to flag:**

### Removing `prevent_destroy` from a stateful resource → P1

```hcl
# Diff removing this:
lifecycle {
  prevent_destroy = true   # ← removal of this line on prod data is alarming
}
```

`prevent_destroy = true` on databases, persistent storage, and DNS zones is a deliberate safety mechanism. Removing it without justification is risky. If genuinely needed (e.g., recreating the resource), require a PR description note explaining the migration plan.

### Adding `ignore_changes` that masks drift → P2

```hcl
# Suspicious — masks something the team might want to know about
lifecycle {
  ignore_changes = all
}
```

`ignore_changes = all` is a code smell. Prefer scoping to specific attributes (`ignore_changes = [tags]`) with a comment explaining why.

### `create_before_destroy = true` on a resource with hard external references → P2

Some resources can't have two instances simultaneously (e.g., DNS records on the same name, IAM roles with the same name). `create_before_destroy = true` on such resources causes apply errors.

**Don't flag:**

- `ignore_changes = [tags]` with a comment about a tag-management tool
- `prevent_destroy = true` additions — that's strictly safer
- `create_before_destroy = true` on resources where it's the recommended pattern (ALB target groups, ASG launch templates)

**When flagging, suggest:**

- The PR-description note explaining why prevent_destroy is being removed
- The narrower `ignore_changes` list inferred from what the team actually wants to ignore
