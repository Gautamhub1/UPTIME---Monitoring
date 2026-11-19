variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Prefix for every resource name (must match the bootstrap)"
  type        = string
  default     = "uptime-monitor"
}

variable "image_uri" {
  description = "Full ECR image URI including tag, set by the pipeline"
  type        = string
}

variable "app_version" {
  description = "Version shown on the dashboard and /health (the pipeline uses the Git commit SHA)"
  type        = string
  default     = "dev"
}

variable "target_urls" {
  description = "Comma-separated list of websites to monitor. httpbin.org/status/503 always fails on purpose, to demo the alerting."
  type        = string
  default     = "https://aws.amazon.com,https://github.com,https://www.wikipedia.org,https://httpbin.org/status/503"
}

variable "alarm_email" {
  description = "Email address for alerts (leave empty to disable). Confirm the subscription email AWS sends you."
  type        = string
  default     = ""
}

variable "check_interval_minutes" {
  description = "How often the websites are checked"
  type        = number
  default     = 5

  validation {
    condition     = var.check_interval_minutes >= 2 && var.check_interval_minutes <= 60
    error_message = "check_interval_minutes must be between 2 and 60."
  }
}

variable "retention_days" {
  description = "How many days of check history DynamoDB keeps"
  type        = number
  default     = 7
}
