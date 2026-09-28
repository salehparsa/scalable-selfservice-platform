locals {
  ci_role_name   = "${var.ci_user_name}-terraform-role"
  ci_policy_name = "${var.ci_user_name}-terraform-policy"

  team_bucket_arn = "arn:${local.partition}:s3:::${var.name_prefix}-*"
  team_role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-*-role"
  team_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${var.name_prefix}-*-policy"
}

# Access keys are created manually and stored only in GitHub secrets;
# an aws_iam_access_key resource would put the secret in Terraform state.
resource "aws_iam_user" "github_ci" {
  name = var.ci_user_name
}

data "aws_iam_policy_document" "github_ci_user" {
  statement {
    sid       = "AssumeCiRoleOnly"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [aws_iam_role.github_ci.arn]
  }
}

resource "aws_iam_user_policy" "github_ci" {
  name   = "assume-${local.ci_role_name}"
  user   = aws_iam_user.github_ci.name
  policy = data.aws_iam_policy_document.github_ci_user.json
}

data "aws_iam_policy_document" "github_ci_trust" {
  statement {
    sid     = "TrustCiUser"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.github_ci.arn]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name                 = local.ci_role_name
  description          = "Assumed by GitHub Actions to plan/apply team infrastructure."
  assume_role_policy   = data.aws_iam_policy_document.github_ci_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_ci_permissions" {
  statement {
    sid       = "Identity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.state.arn]
  }

  # Covers state files and their S3 native lock files (<key>.tflock).
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid = "TeamBuckets"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:Get*",
      "s3:List*",
      "s3:PutBucket*",
      "s3:DeleteBucketPolicy",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [local.team_bucket_arn]
  }

  statement {
    sid = "TeamRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.team_role_arn]
  }

  statement {
    sid       = "TeamRolePolicyAttachment"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.team_role_arn]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = [local.team_policy_arn]
    }
  }

  statement {
    sid = "TeamPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.team_policy_arn]
  }

  # The state bucket also matches the team bucket pattern; allow only state reads/writes on it.
  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    not_actions = [
      "s3:Get*",
      "s3:List*",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "github_ci" {
  name        = local.ci_policy_name
  description = "Least-privilege permissions for GitHub Actions to manage ${var.name_prefix} team infrastructure."
  policy      = data.aws_iam_policy_document.github_ci_permissions.json
}

resource "aws_iam_role_policy_attachment" "github_ci" {
  role       = aws_iam_role.github_ci.name
  policy_arn = aws_iam_policy.github_ci.arn
}
