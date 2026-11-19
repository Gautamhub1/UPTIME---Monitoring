variable "github_owner" {
  description = "Your GitHub username"
  type        = string
  default     = "Gautamhub1"
}

variable "github_repo" {
  description = "Name of the GitHub repository"
  type        = string
  default     = "aws-uptime-monitor"
}

variable "aws_region" {
  description = "AWS region. On new Free-plan accounts this must be your project's home region (see settings.aws.com -> Projects)."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "uptime-monitor"
}

variable "use_oidc" {
  description = <<-EOT
    true  = GitHub logs in with OIDC (no stored keys). Needs an account that allows IAM identity providers.
    false = GitHub logs in with a least-privilege IAM user access key stored in GitHub Secrets.
            Use this on AWS Free-plan accounts, which block creating identity providers.
  EOT
  type        = bool
  default     = false
}

variable "create_oidc_provider" {
  description = "Only used when use_oidc = true. Set to false if your account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}
