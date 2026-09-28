output "region" {
  description = "Region of the state bucket and lock table."
  value       = var.region
}

output "state_bucket_name" {
  description = "Remote state bucket used by live/terragrunt.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "ci_user_name" {
  description = "IAM user to create an access key for; store it only in GitHub secrets."
  value       = aws_iam_user.github_ci.name
}

output "ci_role_arn" {
  description = "Set as the GitHub repository variable AWS_CI_ROLE_ARN."
  value       = aws_iam_role.github_ci.arn
}
