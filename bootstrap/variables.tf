variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "eu-north-1"
}

variable "name_prefix" {
  description = "Company prefix shared by all platform resources. Team resources are named <name_prefix>-<team>-*."
  type        = string
  default     = "example-name-gmbh"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens."
  }
}

variable "ci_user_name" {
  description = "IAM user whose access keys GitHub Actions uses. Must not start with name_prefix, so CI can never modify its own identity."
  type        = string
  default     = "github-ci"
}
