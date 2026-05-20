# Configuration

```json
{
  "defaults_version_checked": "1.5.0",
  "disabled": [
    "silent-failure-hunter",
    "pr-test-analyzer",
    "comment-analyzer",
    "type-design-analyzer",
    "code-simplifier"
  ],
  "overlap_acknowledged": {}
}
```

**Why most defaults are disabled:**

Terraform is declarative IaC, not imperative code. Several baked-in default reviewers don't have a useful lens on `.tf` files:

- **`silent-failure-hunter`** — Terraform doesn't have try/catch or error-swallowing patterns; resources either apply or they don't. Disabled.
- **`pr-test-analyzer`** — Terraform's test conventions (terratest, kitchen-terraform) are project-by-project and rarely adopted. Defaulting to "you must have tests" produces noise on every TF PR; disabled. If a repo has chosen a TF testing framework, add a custom test-coverage-reviewer locally.
- **`comment-analyzer`** — covered by `clarity-reviewer`. Terraform variable/output descriptions ARE the doc surface; the pack's clarity-reviewer scopes to those plus README accuracy.
- **`type-design-analyzer`** — encapsulation/invariant patterns assume OOP design surface. Doesn't apply to HCL.
- **`code-simplifier`** — Terraform "simplification" is highly opinionated (count vs for_each vs map, dynamic blocks vs explicit, etc.). The generic simplifier conflicts with module-author intent. Disabled to avoid noise.

Only `code-reviewer` is kept among the baked-in defaults — it catches CLAUDE.md-level violations that the pack's specialized reviewers don't cover.

---

# Guidelines

A reviewer pack for Terraform / IaC projects. Each section under `# Agents` below is an independent reviewer prompt with its own scope, set of patterns to flag, and disposition.

This pack is **vendor-agnostic**. It does not encode any specific organization's layering rules (e.g., separating baseline infra from per-app infra). If your organization has such a layering convention, add a custom `## <name>-layer-boundary-reviewer` agent that knows your specific layer assignments.

## How the pack runs

Each reviewer runs independently and reports findings without coordination.

**Per-reviewer file scope:**

| Reviewer | Files in scope |
|----------|----------------|
| `provider-pinning-reviewer` | `versions.tf`, `**/versions.tf`, any `*.tf` containing a `required_providers` block |
| `variable-typing-reviewer` | `variables.tf`, `**/variables.tf`, any `*.tf` containing `variable` blocks |
| `iam-least-privilege-reviewer` | `*.tf` containing `aws_iam_policy`, `aws_iam_role`, `google_*_iam_binding`, `azurerm_*_role_assignment`, or equivalent |
| `hardcoded-values-reviewer` | all `*.tf` |
| `state-management-reviewer` | `backend.tf`, `**/backend.tf`, any `*.tf` containing a `terraform { backend ... }` block |
| `lifecycle-reviewer` | `*.tf` containing `lifecycle { ... }` blocks |
| `clarity-reviewer` | `*.md` (READMEs, module docs), variable/output `description` fields |

Skip reviewers whose file scope doesn't match the PR diff.

## Tooling assumed in CI

Reviewers do not duplicate work already done by CI. Each Terraform project running this pack should have these in CI:

- `terraform fmt -check -recursive` — formatter enforcement
- `terraform validate` — syntax + provider-config validation
- `tflint` (with the relevant cloud provider plugin) — lints for unused declarations, deprecated syntax, provider-specific anti-patterns
- `tfsec` or `checkov` — security scanner for IaC (catches public S3, overly permissive IAM, missing encryption)
- `terraform plan` against a stable workspace — drift / diff review surface

A missing tool is itself a **P1** finding on the first PR that brushes against its scope.

## Severity convention

Every finding must be tagged with a beads-style priority matching the pr-review-loop's Priority Mapping:

| Priority | Disposition | Examples |
|----------|-------------|----------|
| **P1** | Blocking — must fix before merge | IAM policy with `Action: "*"` + `Resource: "*"` on a non-admin role, hardcoded production account ID, removal of `prevent_destroy` from a stateful resource, backend change without coordinated state migration |
| **P2** | Should fix in this PR | Missing variable type, missing variable description on a required input, hardcoded region literal that should be a variable, IAM action wildcards scoped to a resource (`Action: "s3:*"` on `Resource: "<specific-bucket>"`) |
| **P3** | Advisory — deferrable with a beads ticket | Provider version pinned with overly-tight `=` instead of `~>`, output missing description, README staleness |

A reviewer may promote or demote a specific finding from its default, but must state why.

## Output format

Findings must be structured. Use this template:

```
[<reviewer>] [<severity>] <one-line title>

File: path/to/module.tf:LINE
Quote:
    <1-5 lines of HCL being flagged>

Issue: <one or two sentences on what's wrong>
Suggested fix:
    <concrete HCL replacement>
Reason (optional): <only if not obvious>
```

## Deferring findings with beads

To defer a P2 or P3 finding to a follow-up:

1. Create a beads ticket capturing reviewer name, severity, file, and quote.
2. Link the ticket in the PR description or as a reply to the reviewer's comment.
3. The reviewer accepts the deferral only when the beads ticket exists.

**P1 findings are not deferrable** — they must be fixed in-PR.

---

# Agents

## provider-pinning-reviewer

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

## variable-typing-reviewer

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

## iam-least-privilege-reviewer

Review IAM policies (AWS `aws_iam_policy_document`, `aws_iam_role_policy`, GCP `google_*_iam_binding`, Azure `azurerm_role_assignment`, etc.) for **principle of least privilege**.

**Patterns to flag:**

### `Action: "*"` + `Resource: "*"` on a non-admin role → P1

This grants full cloud admin. Only flag-not-flag for genuine admin roles (`administrator`, `breakglass`, etc.). Otherwise flag.

### Action wildcards scoped to a resource → P2

```hcl
# BAD — full S3 access to this bucket
{
  Action   = "s3:*"
  Resource = aws_s3_bucket.app_data.arn
}

# GOOD — explicit actions matching actual app needs
{
  Action = [
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",
  ]
  Resource = "${aws_s3_bucket.app_data.arn}/*"
}
```

### Trust policy too broad → P1

```hcl
# BAD — anyone in your account can assume this role
assume_role_policy = jsonencode({
  Statement = [{
    Effect = "Allow"
    Principal = { AWS = "*" }
    Action = "sts:AssumeRole"
  }]
})
```

Trust policies should name specific services (`Service = "lambda.amazonaws.com"`) or specific principal ARNs.

### Missing `Condition` for cross-account or external trust → P2

When a trust policy allows another account's principal, require a `Condition` (e.g., `sts:ExternalId`, `aws:SourceArn`) to prevent confused-deputy attacks.

**Don't flag:**

- Read-only permissions (`s3:Get*`, `s3:List*`) where the role's purpose is observability
- AWS managed policies attached to roles (these are AWS-curated baselines)
- Explicit deny statements (`Effect = "Deny"`) — strictness, not permissiveness

**When flagging, suggest:**

- The narrower action list inferred from the role's downstream usage
- A condition block matching the cross-account scenario

## hardcoded-values-reviewer

Review `.tf` files for **hardcoded environment-specific values** that should be variables, locals, or `data` source lookups.

**Patterns to flag:**

### Hardcoded account IDs (12-digit numerics) → P1

```hcl
# BAD — production account ID baked in
resource "aws_iam_role_policy" "x" {
  policy = jsonencode({
    Statement = [{
      Resource = "arn:aws:s3:::123456789012-prod-bucket"
    }]
  })
}

# GOOD — derive from data source
data "aws_caller_identity" "current" {}

# ... use data.aws_caller_identity.current.account_id
```

### Hardcoded region literals → P2

`"us-east-1"` baked into resource arguments couples the module to one region. Use `data.aws_region.current.name` or a `region` variable.

### Hardcoded ARNs from other Terraform stacks → P2

Pulling an ARN by string-literal (`"arn:aws:lambda:us-east-1:123:function:foo"`) instead of via `terraform_remote_state` or `data` lookup is brittle to renames.

### Hardcoded environment names in resource names → P3

`name = "myapp-prod-bucket"` couples the resource name to one environment. Prefer `name = "myapp-${var.environment}-bucket"`.

**Don't flag:**

- Service principal strings (`"lambda.amazonaws.com"`) — these are AWS-controlled, not environment-specific
- HTTP status codes, ports (80, 443), well-known protocol constants
- Magic numbers documented as semantically meaningful (`memory_size = 128` with a comment)

**When flagging, suggest:**

- The variable / data source to substitute
- Where the value should live (variables.tf, locals, or as a data source query)

## state-management-reviewer

Review `terraform { backend ... }` configuration and state-related changes for **state safety**.

**Patterns to flag:**

### Backend not configured (local state for production resources) → P1

```hcl
# BAD — no backend = state lives in terraform.tfstate locally
terraform {
  required_version = ">= 1.5"
}

# GOOD — remote state with locking
terraform {
  required_version = ">= 1.5"
  backend "s3" {
    bucket         = "myorg-terraform-state"
    key            = "myapp/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "myorg-terraform-locks"
    encrypt        = true
  }
}
```

Exceptions: scratch/playground modules explicitly marked as local-state-only.

### Missing state locking → P2

S3 backend without `dynamodb_table` (or equivalent locking mechanism for other backends) — concurrent applies will race.

### Missing encryption on state backend → P1

State files often contain secrets (DB connection strings, API keys). Always require `encrypt = true` on S3 and equivalent settings on other backends.

### Backend block changed in a PR without an accompanying state-migration plan → P1

Changing the backend bucket / key / region requires `terraform init -migrate-state` and careful coordination. PR diffs that change backend config without a migration runbook in the PR description should be flagged.

**Don't flag:**

- New modules genuinely starting at local state (with explicit comment + plan to migrate)
- Backend config in a separate `.tfbackend` partial file referenced via `-backend-config=`

**When flagging, suggest:**

- The specific backend block matching common org patterns
- The dependency creation (state bucket / lock table) if they don't exist yet

## lifecycle-reviewer

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

## clarity-reviewer

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
