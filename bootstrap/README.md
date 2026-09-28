# bootstrap

> **Bootstrapping only.** This stack is applied **once per AWS account, by a
> human admin, from a local machine**. It is never applied by CI; the GitHub
> workflow only runs `fmt`/`validate` on it.

It creates the two things everything else depends on but cannot create itself:

1. **Remote state backend** used by every team under `live/`.
2. **CI identity** that GitHub Actions uses to plan/apply team infrastructure.

State for this stack is kept **locally** (`terraform.tfstate`, gitignored),
because the remote state bucket does not exist until this stack has run.

## What it creates

### Remote state

| Resource | Name | Notes |
|---|---|---|
| S3 bucket | `example-name-gmbh-tfstate-<account_id>` | Versioned, SSE-S3, all public access blocked, TLS-only policy, old versions expire after 90 days, `prevent_destroy` |
| DynamoDB table | `example-name-gmbh-tfstate-lock` | `PAY_PER_REQUEST`, hash key `LockID`, deletion protection on |

The names are derived from the account id, so `live/terragrunt.hcl` rebuilds
them with `get_aws_account_id()`, with no manual copying between stacks.

### CI identity

GitHub Actions can't use OIDC in this setup (the AWS free-tier account has no
OIDC identity provider configured), so CI authenticates with static access
keys. To keep those keys as weak as possible, the identity is split in two:

```
GitHub secrets ──► IAM user "github-ci" ──sts:AssumeRole──► IAM role "github-ci-terraform-role"
                   (can ONLY assume the role)              (holds the Terraform permissions,
                                                             1h session credentials)
```

| Resource | Name | Purpose |
|---|---|---|
| IAM user | `github-ci` | Owns the access key stored in GitHub secrets. Its only permission is `sts:AssumeRole` / `sts:TagSession` on the CI role. No console access. |
| IAM role | `github-ci-terraform-role` | Trusts only the `github-ci` user. This is what the workflow runs Terraform as. |
| IAM policy | `github-ci-terraform-policy` | Least-privilege permissions attached to the role (below). |

**What the CI role can do:**

- Read/write Terraform state objects and the lock table.
- Manage team buckets matching `example-name-gmbh-*`.
- Manage team roles `example-name-gmbh-*-role` and policies
  `example-name-gmbh-*-policy`, and attach **only** those team policies to
  team roles (no `AdministratorAccess` or other AWS-managed policies).

**What it cannot do:**

- Change or delete the state bucket itself (explicit Deny; only object
  reads/writes are allowed on it).
- Modify its own user, role or policy. The CI names deliberately don't start
  with `example-name-gmbh-`, so they fall outside every pattern above.
- Touch anything else in the account.

**Why the access key is not created here:** an `aws_iam_access_key`
resource would store the secret key in plain text in Terraform state. The key
is created manually and goes straight into GitHub secrets.

**Moving to OIDC later:** add a GitHub OIDC identity provider, change the
role's trust policy to trust it, and delete the `github-ci` user. The role's
permissions don't change.

## Usage

Prerequisites: Terraform >= 1.6 and credentials for an **admin** IAM identity
(not the root user) in the target account.

```sh
cd bootstrap
terraform init
terraform plan
terraform apply
```

Inputs (all optional):

| Variable | Default | Description |
|---|---|---|
| `region` | `eu-north-1` | Region for the state bucket and lock table |
| `name_prefix` | `example-name-gmbh` | Company prefix for platform resources |
| `ci_user_name` | `github-ci` | CI IAM user name; must **not** start with `name_prefix` |

### After apply (manual, one-time)

1. Create an access key for the `github-ci` user in the IAM console
   (Users → `github-ci` → Security credentials → Create access key).
2. Paste it directly into the GitHub repository settings. Never write it to a
   file, shell history or chat:
   - Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
   - Variables: `AWS_CI_ROLE_ARN` (from `terraform output ci_role_arn`),
     `AWS_REGION` (`eu-north-1`), `AWS_CI_ENABLED` (`true`)
3. Rotate the key every 90 days.

## Outputs

| Output | Used for |
|---|---|
| `state_bucket_name`, `lock_table_name`, `region` | Reference / sanity check against `live/terragrunt.hcl` |
| `ci_user_name` | Which user to create the access key for |
| `ci_role_arn` | GitHub variable `AWS_CI_ROLE_ARN` |
