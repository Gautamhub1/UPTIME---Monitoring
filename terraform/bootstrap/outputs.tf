# After "terraform apply", copy these values into GitHub:
#   Settings -> Secrets and variables -> Actions
#
# Variables tab: AWS_REGION, TF_STATE_BUCKET (and AWS_ROLE_ARN when use_oidc = true)
# Secrets tab:   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (when use_oidc = false)
#   Show the secret key with:  terraform output -raw AWS_SECRET_ACCESS_KEY

output "AWS_REGION" {
  description = "GitHub variable AWS_REGION"
  value       = var.aws_region
}

output "TF_STATE_BUCKET" {
  description = "GitHub variable TF_STATE_BUCKET"
  value       = aws_s3_bucket.tf_state.bucket
}

output "AWS_ROLE_ARN" {
  description = "GitHub variable AWS_ROLE_ARN (only with use_oidc = true)"
  value       = var.use_oidc ? aws_iam_role.github_deploy[0].arn : "not used (access key login)"
}

output "AWS_ACCESS_KEY_ID" {
  description = "GitHub secret AWS_ACCESS_KEY_ID (only with use_oidc = false)"
  value       = var.use_oidc ? "not used (OIDC login)" : aws_iam_access_key.github_deploy[0].id
}

output "AWS_SECRET_ACCESS_KEY" {
  description = "GitHub secret AWS_SECRET_ACCESS_KEY - show it with: terraform output -raw AWS_SECRET_ACCESS_KEY"
  value       = var.use_oidc ? "not used (OIDC login)" : aws_iam_access_key.github_deploy[0].secret
  sensitive   = true
}

output "ecr_repository_url" {
  description = "Where the pipeline pushes Docker images"
  value       = aws_ecr_repository.app.repository_url
}
