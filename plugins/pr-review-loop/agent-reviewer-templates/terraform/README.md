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
