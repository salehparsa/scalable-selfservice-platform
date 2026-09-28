locals {
  name_prefix = "example-name-gmbh"
  region      = "eu-north-1"

  # The folder name is the team's identity: live/team-alpha -> "alpha".
  team_name = trimprefix(basename(get_terragrunt_dir()), "team-")

  # Team-owned settings; only the keys mapped in `inputs` below are used.
  team = yamldecode(file("${get_terragrunt_dir()}/team.yaml"))
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket       = "${local.name_prefix}-tfstate-${get_aws_account_id()}"
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.region
    encrypt      = true
    use_lockfile = true

    # The state bucket is owned by bootstrap/; never let Terragrunt modify it.
    disable_bucket_update = true
  }
}

terraform {
  source = "${get_repo_root()}/modules/team_infrastructure"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"
    }
  EOF
}

# Explicit mapping: team.yaml cannot override name_prefix or team_name.
inputs = {
  name_prefix = local.name_prefix
  team_name   = local.team_name
  owner       = local.team.owner
  cost_center = local.team.cost_center
  buckets     = local.team.buckets
  tags        = local.team.tags

  # "{account_id}" in team.yaml is resolved here, so no account id is ever hardcoded.
  trusted_principal_arns = [
    for arn in local.team.trusted_principal_arns : replace(arn, "{account_id}", get_aws_account_id())
  ]
}
