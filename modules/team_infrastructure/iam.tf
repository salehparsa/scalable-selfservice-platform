data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "TrustedPrincipals"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "team" {
  name                 = local.role_name
  description          = "Access to the ${var.team_name} team's S3 buckets only."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = local.tags

  lifecycle {
    # Trusting another account's root would hand that whole account access.
    precondition {
      condition = alltrue([
        for a in var.trusted_principal_arns :
        !endswith(a, ":root") || a == "arn:${local.partition}:iam::${local.account_id}:root"
      ])
      error_message = "Only this account's root ARN (arn:${local.partition}:iam::${local.account_id}:root) may be trusted; use role/user ARNs for other accounts."
    }
  }
}

# Scoped to this team's bucket ARNs only; no wildcards across buckets or accounts.
data "aws_iam_policy_document" "team" {
  statement {
    sid = "TeamBuckets"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]
    resources = values(local.bucket_arns)
  }

  # s3:DeleteObjectVersion is deliberately withheld: teams cannot permanently delete versioned data.
  statement {
    sid = "TeamObjects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [for arn in values(local.bucket_arns) : "${arn}/*"]
  }
}

resource "aws_iam_policy" "team" {
  name        = local.policy_name
  description = "Least-privilege S3 access for the ${var.team_name} team."
  policy      = data.aws_iam_policy_document.team.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "team" {
  role       = aws_iam_role.team.name
  policy_arn = aws_iam_policy.team.arn
}
