output "team_name" {
  description = "Team identifier."
  value       = var.team_name
}

output "iam_role_arn" {
  description = "ARN of the team role."
  value       = aws_iam_role.team.arn
}

output "iam_role_name" {
  description = "Name of the team role."
  value       = aws_iam_role.team.name
}

output "bucket_names" {
  description = "Map of bucket suffix to bucket name."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "Map of bucket suffix to bucket ARN."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "tags" {
  description = "Tags applied to all team resources."
  value       = local.tags
}
