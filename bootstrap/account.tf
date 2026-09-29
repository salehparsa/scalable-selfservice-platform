# Account-wide S3 Block Public Access. New AWS accounts turn all four settings on, which rejects
# every public bucket policy and so stops any team bucket with visibility "public".
# ACL blocks stay on (nothing here ever uses ACLs); only public *policies* become possible.
# Private buckets are still protected by their own per-bucket block, set by the team module.
resource "aws_s3_account_public_access_block" "this" {
  account_id = local.account_id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}
