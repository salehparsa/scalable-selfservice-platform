variable "name_prefix" {
  description = "Company prefix for every resource name. Set by live/root.hcl, not by teams."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens."
  }
}

variable "team_name" {
  description = "Team identifier, derived from the live/team-<name> folder by live/root.hcl."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$", var.team_name))
    error_message = "team_name must be 1-15 chars, lowercase alphanumeric or hyphens, not starting or ending with a hyphen."
  }

  validation {
    condition     = !contains(["tfstate", "github", "ci", "admin", "platform", "root"], var.team_name)
    error_message = "team_name is reserved by the platform."
  }
}

variable "owner" {
  description = "Owning person or team contact (e-mail or handle). Applied as the Owner tag."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "cost_center" {
  description = "Cost center for cost allocation. Applied as the CostCenter tag."
  type        = string

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be empty."
  }
}

variable "buckets" {
  description = "Buckets to create. Every entry must set visibility explicitly to \"public\" or \"private\"; there is no default."
  type = list(object({
    suffix     = string
    visibility = string
  }))

  validation {
    condition     = length(var.buckets) > 0
    error_message = "At least one bucket is required."
  }

  validation {
    condition     = alltrue([for b in var.buckets : contains(["public", "private"], b.visibility)])
    error_message = "Each bucket's visibility must be exactly \"public\" or \"private\"."
  }

  validation {
    condition     = alltrue([for b in var.buckets : can(regex("^[a-z0-9]([a-z0-9-]{0,12}[a-z0-9])?$", b.suffix))])
    error_message = "Each bucket suffix must be 1-14 chars, lowercase alphanumeric or hyphens, not starting or ending with a hyphen."
  }

  validation {
    condition     = length(distinct([for b in var.buckets : b.suffix])) == length(var.buckets)
    error_message = "Bucket suffixes must be unique within a team."
  }
}

variable "trusted_principal_arns" {
  description = "Principals allowed to assume the team role: this account's root ARN (access delegated to IAM policies granting sts:AssumeRole on the role) and/or Terraform-managed role/user ARNs."
  type        = list(string)

  validation {
    condition     = length(var.trusted_principal_arns) > 0
    error_message = "At least one trusted principal ARN is required."
  }

  validation {
    condition     = alltrue([for a in var.trusted_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", a))])
    error_message = "trusted_principal_arns must be arn:aws:iam::<12-digit account>:root, :role/<name> or :user/<name>; wildcards and unresolved placeholders are not allowed."
  }
}

variable "tags" {
  description = "Team tags for all resources. Must include ManagedBy = \"terraform\". Cannot override the platform tags (Team, Owner, CostCenter, ManagedBy, Project)."
  type        = map(string)

  validation {
    condition     = lookup(var.tags, "ManagedBy", "") == "terraform"
    error_message = "tags must include ManagedBy = \"terraform\"."
  }
}

variable "force_destroy" {
  description = "Empty buckets (all object versions) on destroy. Set only by the offboarding pipeline via TG_OFFBOARDING; never in team.yaml."
  type        = bool
  default     = false
}
