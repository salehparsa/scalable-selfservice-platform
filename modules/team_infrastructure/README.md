# team_infrastructure

Creates one team's isolated S3 buckets and a single IAM role that can access
only those buckets. Consumed through Terragrunt from `live/team-<name>/`;
`name_prefix` and `team_name` are injected by `live/root.hcl`, so a team file
only declares its own buckets, trust and ownership.

## What it creates

For each bucket in `buckets`:

- S3 bucket named `<name_prefix>-<team_name>-<suffix>-<account_id>`
- ACLs disabled (`BucketOwnerEnforced`), versioning on, SSE-S3 encryption
- Public access block: all four settings on for `private`; for `public` the
  ACL settings stay on and only the bucket policy may grant public read
- Bucket policy:
  - deny non-TLS access on every bucket
  - deny object read/write/delete to every principal except the team role
    (public buckets: only write/delete are restricted, reads stay public)
  - `s3:GetObject` for everyone on `public` buckets only

For the team (created **before** the buckets; buckets `depends_on` the role
and their policies reference its ARN):

- IAM role `<name_prefix>-<team_name>-role`, trusted by
  `trusted_principal_arns` (the generated default is this account's root,
  i.e. delegated to IAM policies that grant `sts:AssumeRole` on the role)
- IAM policy `<name_prefix>-<team_name>-policy`, limited to this team's
  bucket ARNs (list, get, put, delete; no permanent version deletes)

Access to a team's objects is therefore enforced on both sides: the role's
identity policy only names this team's buckets, and the bucket policy only
admits this team's role.

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `name_prefix` | `string` | yes | Company prefix (set by `root.hcl`) |
| `team_name` | `string` | yes | Team id, 1-15 chars (set by `root.hcl` from the folder name) |
| `owner` | `string` | yes | Owner contact, applied as `Owner` tag |
| `cost_center` | `string` | yes | Applied as `CostCenter` tag |
| `buckets` | `list(object({ suffix = string, visibility = string }))` | yes | `visibility` must be `"public"` or `"private"`; no default. Suffixes unique, 1-14 chars |
| `trusted_principal_arns` | `list(string)` | yes | Who may assume the team role: this account's `:root` (access delegated to IAM policies) and/or role/user ARNs. Other accounts' `:root` and wildcards rejected |
| `tags` | `map(string)` | yes | Must include `ManagedBy = "terraform"`; extra keys allowed, platform tags cannot be overridden |

## Outputs

| Name | Description |
|---|---|
| `team_name` | Team id |
| `iam_role_arn` / `iam_role_name` | Team role |
| `bucket_names` / `bucket_arns` | Maps of suffix to bucket name / ARN |
| `tags` | Tags applied to all team resources |

## Tags

`Team`, `Owner`, `CostCenter`, `ManagedBy`, `Project` on every resource, plus
`Visibility` on buckets. Platform tags are merged last, so team `tags` can add
keys but never override these.

## Tests

`tests/team_infrastructure.tftest.hcl` runs with `terraform test`, fully offline: every run is
a plan with fake credentials. It covers naming, public/private handling, bucket and IAM
policy scoping, tags and rejected inputs. Run `make test-module` from the repository root;
see the root README's *Testing* section for details.
