# Unit tests for the team_infrastructure module. Every run is a plan with fake credentials:
# nothing is created and AWS is never called. The account lookups are overridden, so names
# and IAM policy JSON (built locally by the provider) can be asserted exactly.
# Run: make test-module   (or: terraform -chdir=modules/team_infrastructure test)

provider "aws" {
  region                      = "eu-north-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}

variables {
  name_prefix            = "example-name-gmbh"
  team_name              = "alpha"
  owner                  = "alpha@example.com"
  cost_center            = "cc-0001"
  trusted_principal_arns = ["arn:aws:iam::123456789012:root"]
  tags                   = { ManagedBy = "terraform" }
  buckets = [
    { suffix = "data", visibility = "private" },
    { suffix = "assets", visibility = "public" },
  ]
}

# --- Naming ---------------------------------------------------------------------------

run "names_follow_the_convention" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this["data"].bucket == "example-name-gmbh-alpha-data-123456789012"
    error_message = "Bucket name must be <prefix>-<team>-<suffix>-<account_id>."
  }
  assert {
    condition     = aws_iam_role.team.name == "example-name-gmbh-alpha-role"
    error_message = "Role name must be <prefix>-<team>-role (the CI policy is scoped to that pattern)."
  }
  assert {
    condition     = aws_iam_policy.team.name == "example-name-gmbh-alpha-policy"
    error_message = "Policy name must be <prefix>-<team>-policy (the CI policy is scoped to that pattern)."
  }
}

# --- Public vs private ----------------------------------------------------------------

run "private_bucket_blocks_everything" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this["data"].block_public_acls,
      aws_s3_bucket_public_access_block.this["data"].ignore_public_acls,
      aws_s3_bucket_public_access_block.this["data"].block_public_policy,
      aws_s3_bucket_public_access_block.this["data"].restrict_public_buckets,
    ])
    error_message = "A private bucket must have all four public access blocks on."
  }
  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket["data"].json).Statement : s.Sid], "PublicReadObjects")
    error_message = "A private bucket must not have a public-read statement."
  }
}

run "public_bucket_allows_policy_read_only" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this["assets"].block_public_acls
      && aws_s3_bucket_public_access_block.this["assets"].ignore_public_acls
      && !aws_s3_bucket_public_access_block.this["assets"].block_public_policy
      && !aws_s3_bucket_public_access_block.this["assets"].restrict_public_buckets
    )
    error_message = "A public bucket must keep ACLs blocked and allow only a public bucket policy."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(data.aws_iam_policy_document.bucket["assets"].json).Statement :
      s.Sid == "PublicReadObjects" && s.Action == "s3:GetObject" && s.Effect == "Allow"
    ])
    error_message = "A public bucket must grant anonymous s3:GetObject."
  }
}

# --- Isolation ------------------------------------------------------------------------

run "every_bucket_denies_non_tls_and_other_principals" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["data", "assets"] : contains([for s in jsondecode(data.aws_iam_policy_document.bucket[k].json).Statement : s.Sid], "DenyInsecureTransport")
    ])
    error_message = "Every bucket must deny non-TLS access."
  }
  assert {
    condition = alltrue([
      for k in ["data", "assets"] : anytrue([
        for s in jsondecode(data.aws_iam_policy_document.bucket[k].json).Statement :
        s.Sid == "DenyObjectAccessExceptTeamRole" && s.Effect == "Deny"
        && s.Condition.ArnNotEquals["aws:PrincipalArn"] == "arn:aws:iam::123456789012:role/example-name-gmbh-alpha-role"
      ])
    ])
    error_message = "Every bucket policy must deny object access to all principals except the team role."
  }
}

run "team_policy_only_names_own_buckets" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(data.aws_iam_policy_document.team.json).Statement : [
        for r in flatten([s.Resource]) :
        can(regex("^arn:aws:s3:::example-name-gmbh-alpha-(data|assets)-123456789012(/\\*)?$", r))
      ]
    ]))
    error_message = "The team policy may only reference this team's own bucket ARNs (no wildcards)."
  }
  assert {
    condition = !contains(flatten([
      for s in jsondecode(data.aws_iam_policy_document.team.json).Statement : flatten([s.Action])
    ]), "s3:DeleteObjectVersion")
    error_message = "Teams must not be able to permanently delete object versions."
  }
}

# --- Tags and safety defaults ---------------------------------------------------------

run "platform_tags_cannot_be_overridden" {
  command = plan

  variables {
    tags = { ManagedBy = "terraform", Team = "someone-else", Extra = "kept" }
  }

  assert {
    condition     = aws_iam_role.team.tags["Team"] == "alpha" && aws_iam_role.team.tags["Extra"] == "kept"
    error_message = "Platform tags must win over team tags; extra team tags must be kept."
  }
  assert {
    condition     = aws_s3_bucket.this["data"].tags["CostCenter"] == "cc-0001" && aws_s3_bucket.this["data"].tags["Visibility"] == "private"
    error_message = "Buckets must carry CostCenter and Visibility tags."
  }
}

run "force_destroy_is_off_by_default" {
  command = plan

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : b.force_destroy == false])
    error_message = "force_destroy must default to false (only offboarding sets it)."
  }
}

# --- Rejected inputs ------------------------------------------------------------------

run "rejects_invalid_visibility" {
  command = plan
  variables {
    buckets = [{ suffix = "data", visibility = "internal" }]
  }
  expect_failures = [var.buckets]
}

run "rejects_duplicate_suffixes" {
  command = plan
  variables {
    buckets = [{ suffix = "data", visibility = "private" }, { suffix = "data", visibility = "public" }]
  }
  expect_failures = [var.buckets]
}

run "rejects_empty_bucket_list" {
  command = plan
  variables {
    buckets = []
  }
  expect_failures = [var.buckets]
}

run "rejects_invalid_team_name" {
  command = plan
  variables {
    team_name = "Bad_Name"
  }
  expect_failures = [var.team_name]
}

run "rejects_reserved_team_name" {
  command = plan
  variables {
    team_name = "ci"
  }
  expect_failures = [var.team_name]
}

run "rejects_wildcard_trust" {
  command = plan
  variables {
    trusted_principal_arns = ["*"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_other_accounts_root" {
  command = plan
  variables {
    trusted_principal_arns = ["arn:aws:iam::999999999999:root"]
  }
  expect_failures = [aws_iam_role.team]
}

run "rejects_missing_managed_by_tag" {
  command = plan
  variables {
    tags = { Owner = "x" }
  }
  expect_failures = [var.tags]
}

run "rejects_bucket_name_over_63_chars" {
  command = plan
  variables {
    name_prefix = "example-name-gmbh-with-a-long-prefix"
    team_name   = "fifteen-chars-x"
    buckets     = [{ suffix = "fourteen-chars", visibility = "private" }]
  }
  expect_failures = [aws_s3_bucket.this]
}
