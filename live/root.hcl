locals {
  name_prefix = "example-name-gmbh"
  region      = "eu-north-1"

  # The folder name is the team's identity: live/team-alpha -> "alpha".
  team_name = trimprefix(basename(get_terragrunt_dir()), "team-")

  # Team-owned settings; only the keys mapped in `inputs` below are used.
  team = yamldecode(file("${get_terragrunt_dir()}/team.yaml"))

  # Platform-owned: the released module version every team runs. Written by the release
  # workflow after a successful rollout; "" means not released yet (use the working tree).
  # MODULE_VERSION_OVERRIDE is set only by the release workflow, to apply a version before it
  # is recorded. The regex rejects anything that is not a release tag like team_infrastructure/v1.2.3.
  module_repo     = "git::https://github.com/salehparsa/scalable-selfservice-platform.git"
  module_versions = yamldecode(file("${get_parent_terragrunt_dir()}/module-versions.yaml"))
  module_override = get_env("MODULE_VERSION_OVERRIDE", "") # empty = not overriding
  module_version = regex(
    "^(?:(?:[A-Za-z0-9_.-]+/)*v[0-9]+\\.[0-9]+\\.[0-9]+)?$",
    local.module_override != "" ? local.module_override : local.module_versions.default,
  )
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

# Teams run a released version, not the working tree, so a change to modules/ reaches them only
# through the release workflow. Release tags contain just the module, so there is no //subdir.
# To try unreleased module code against a real team: TG_SOURCE=$PWD/modules/team_infrastructure
terraform {
  source = local.module_version == "" ? "${get_repo_root()}/modules/team_infrastructure" : "${local.module_repo}?ref=${local.module_version}"
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

# Explicit mapping: team.yaml cannot override name_prefix, team_name or force_destroy.
inputs = {
  # Only scripts/offboard-team.sh sets TG_OFFBOARDING; normal applies never empty buckets.
  force_destroy = get_env("TG_OFFBOARDING", "false") == "true"

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
