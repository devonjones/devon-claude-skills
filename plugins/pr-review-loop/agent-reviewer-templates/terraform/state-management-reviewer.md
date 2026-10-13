# state-management-reviewer
verification: evidence-query — greps the terraform block for backend, dynamodb_table and encrypt, and reads the diff for changed backend bucket, key or region.
**Checks:** State safety: no remote backend, missing locking or encrypt = true, backend changes without a migration plan.
**Spawn when:** Diff touches a terraform { backend } block, .tfbackend files or backend config in .tf. Skip modules marked local-state-only.
**Contents:** Patterns to flag · Backend not configured (local state for production resources) → P1 · Missing state locking → P2 · Missing encryption on state backend → P1 · Backend block changed in a PR without an accompanying state-migration plan → P1 · Don't flag · When flagging, suggest

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
