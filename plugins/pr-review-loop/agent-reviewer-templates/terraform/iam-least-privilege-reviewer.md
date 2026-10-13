# iam-least-privilege-reviewer
**Checks:** Over-broad IAM: Action/Resource wildcards, Principal AWS "*" trust policies, cross-account trust without Condition (AWS, GCP, Azure).
**Spawn when:** Diff touches .tf with aws_iam_*, assume_role_policy, google_*_iam_*, azurerm_role_assignment or policy documents. Skip otherwise.
**Contents:** Patterns to flag · `Action: "*"` + `Resource: "*"` on a non-admin role → P1 · Action wildcards scoped to a resource → P2 · Trust policy too broad → P1 · Missing `Condition` for cross-account or external trust → P2 · Don't flag · When flagging, suggest

Review IAM policies (AWS `aws_iam_policy_document`, `aws_iam_role_policy`, GCP `google_*_iam_binding`, Azure `azurerm_role_assignment`, etc.) for **principle of least privilege**.

**Patterns to flag:**

### `Action: "*"` + `Resource: "*"` on a non-admin role → P1

This grants full cloud admin. Only exempt genuine admin roles (`administrator`, `breakglass`, etc.). Otherwise flag.

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
