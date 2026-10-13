# hardcoded-values-reviewer
verification: evidence-query — greps the changed .tf files for 12-digit account IDs, region literals, ARN literals and environment names in resource names.
**Checks:** Hardcoded account IDs (P1), region literals, cross-stack ARNs (P2) and environment names in resource names (P3) in .tf files.
**Spawn when:** Diff adds or changes .tf files with resource, policy or ARN string literals. Skip diffs touching only variables, outputs or comments.
**Contents:** Patterns to flag · Hardcoded account IDs (12-digit numerics) → P1 · Hardcoded region literals → P2 · Hardcoded ARNs from other Terraform stacks → P2 · Hardcoded environment names in resource names → P3 · Don't flag · When flagging, suggest

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
