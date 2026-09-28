resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value.name
  force_destroy = var.force_destroy
  tags          = merge(local.tags, { Visibility = each.value.visibility })

  depends_on = [aws_iam_role.team]

  lifecycle {
    precondition {
      condition     = length(each.value.name) <= 63
      error_message = "Bucket name ${each.value.name} exceeds the 63-character S3 limit; shorten team_name or suffix."
    }
  }
}

# ACLs disabled; visibility is controlled only by the bucket policy.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Private: everything blocked. Public: ACLs stay blocked, only the bucket policy may grant public read.
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = each.value.visibility == "private"
  restrict_public_buckets = each.value.visibility == "private"
}

data "aws_iam_policy_document" "bucket" {
  for_each = local.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      local.bucket_arns[each.key],
      "${local.bucket_arns[each.key]}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Resource-side enforcement: only the team role may touch objects (public buckets keep anonymous reads).
  # Condition on aws:PrincipalArn instead of a Principal element avoids IAM propagation errors on a fresh role.
  # s3:DeleteObjectVersion is not denied so an admin can still empty the bucket when offboarding.
  statement {
    sid    = "DenyObjectAccessExceptTeamRole"
    effect = "Deny"
    actions = each.value.visibility == "public" ? [
      "s3:PutObject",
      "s3:DeleteObject",
      ] : [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${local.bucket_arns[each.key]}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.team.arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.visibility == "public" ? [1] : []

    content {
      sid       = "PublicReadObjects"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${local.bucket_arns[each.key]}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.bucket[each.key].json

  # A public policy is rejected while block_public_policy is still true.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
