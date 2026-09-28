data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  role_name   = "${var.name_prefix}-${var.team_name}-role"
  policy_name = "${var.name_prefix}-${var.team_name}-policy"

  # Keyed by suffix so reordering the list never replaces a bucket.
  buckets = {
    for b in var.buckets : b.suffix => {
      name       = "${var.name_prefix}-${var.team_name}-${b.suffix}-${local.account_id}"
      visibility = b.visibility
    }
  }

  # Built from names (not resource attributes) so the IAM policy is fully known at plan time.
  bucket_arns = { for k, b in local.buckets : k => "arn:${local.partition}:s3:::${b.name}" }

  # Platform tags last so teams cannot override them.
  tags = merge(var.tags, {
    Team       = var.team_name
    Owner      = var.owner
    CostCenter = var.cost_center
    ManagedBy  = "terraform"
    Project    = "scalable-selfservice-platform"
  })
}
