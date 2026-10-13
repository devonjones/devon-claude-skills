# provider-pinning-reviewer
**Checks:** Provider version discipline in required_providers: missing or loose (>=, *) constraints, and missing required_version.
**Spawn when:** Diff touches a terraform { } block, required_providers or required_version in .tf files (usually versions.tf). Skip otherwise.
**Contents:** Patterns to flag · Missing version constraint → P2 · Loose constraints (`>=`, `*`) on production providers → P2 · Missing `required_version` on the `terraform` block → P3 · Don't flag · When flagging, suggest

Review `terraform { required_providers { ... } }` blocks for **provider version discipline**. Loose pins cause silent drift; missing pins cause CI/CD churn when new provider versions ship.

**Patterns to flag:**

### Missing version constraint → P2

```hcl
# BAD — no version pin at all
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# GOOD — pessimistic constraint (compatible minor + patch)
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }
}
```

### Loose constraints (`>=`, `*`) on production providers → P2

`>= 5.0` allows any future major version, which can introduce breaking changes silently. Prefer `~> 5.x` (pessimistic) or `= 5.x.y` (exact).

### Missing `required_version` on the `terraform` block → P3

```hcl
terraform {
  required_version = ">= 1.5"   # at minimum specify the Terraform version
  # ...
}
```

**Don't flag:**

- Exact version pins (`= 5.30.1`) — over-tight but not unsafe
- `~> 5.30` (pessimistic) — the recommended pattern
- `version = "~> 5.30, < 5.50"` — explicit upper bound — fine

**When flagging, suggest:**

- The pessimistic constraint matching the currently-installed provider version
- A pointer to upgrade-cadence docs if the project has them
