# variable-typing-reviewer
**Checks:** Variable blocks missing type or description, type = any without reason, secret-named variables lacking sensitive = true.
**Spawn when:** Diff adds or edits a variable block in .tf files (typically variables.tf). Skip diffs with no variable changes.
**Contents:** Patterns to flag · Missing `type` → P2 · Missing `description` on a required variable (no default) → P2 · `type = any` without justification → P2 · Sensitive variable missing `sensitive = true` → P1 · Don't flag · When flagging, suggest

Review `variable` blocks for **type and description discipline**. Untyped variables accept any value; undescribed variables hide intent from consumers.

**Patterns to flag:**

### Missing `type` → P2

```hcl
# BAD — no type, accepts anything
variable "instance_count" {
  default = 3
}

# GOOD — explicit type
variable "instance_count" {
  type        = number
  description = "Number of EC2 instances in the ASG."
  default     = 3
}
```

### Missing `description` on a required variable (no default) → P2

A variable without a default MUST be provided by the caller; the description is the only signal for what to pass.

### `type = any` without justification → P2

`any` defeats the type system. Acceptable for genuinely heterogeneous structures (e.g., `tags = map(any)` for tag maps) but should be narrowed when possible (`map(string)`).

### Sensitive variable missing `sensitive = true` → P1

Any variable named `*_password`, `*_secret`, `*_key`, `*_token` must have `sensitive = true` so its value doesn't leak to plan output.

**Don't flag:**

- Variables with `validation` blocks — those typically include description as part of the validation
- Computed locals (`locals { ... }`) — different surface, doesn't have type/description shape

**When flagging, suggest:**

- The specific `type` based on the default value (number, string, bool, list(string), map(string), object({...}))
- A one-sentence description derived from the variable name and context
