# -----------------------------------------------------------------------------
# ONE-TIME SETUP (run once from AWS CloudShell or your laptop).
#
# Creates the things the CI/CD pipeline needs before it can deploy anything:
#   1. S3 bucket      -> stores the Terraform state of the app
#   2. ECR repository -> stores the Docker images of the Lambda function
#   3. GitHub login to AWS, one of two ways (variable use_oidc):
#      - use_oidc = false (default, works on the AWS Free plan): an IAM user
#        with a least-privilege policy; its access key goes into GitHub Secrets
#      - use_oidc = true (paid/standard accounts): OIDC provider + IAM role,
#        short-lived credentials, no stored keys
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform-bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region
  name       = var.project_name

  # Resources created by the app's Terraform all start with this prefix.
  # The deploy role may only manage resources whose names match it.
  app_prefix = var.project_name

  github_oidc_url = "https://token.actions.githubusercontent.com"

  github_oidc_provider_arn = (
    !var.use_oidc ? null
    : var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

# --- 1. Terraform state bucket ----------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket        = "${local.name}-tfstate-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- 2. ECR repository for the Docker image ---------------------------------

resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- 3a. GitHub Actions -> AWS login with OIDC (use_oidc = true) -------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.use_oidc && var.create_oidc_provider ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.use_oidc && !var.create_oidc_provider ? 1 : 0

  url = local.github_oidc_url
}

resource "aws_iam_role" "github_deploy" {
  count = var.use_oidc ? 1 : 0

  name        = "github-deploy-${local.name}"
  description = "Assumed by GitHub Actions (main branch of ${var.github_owner}/${var.github_repo} only)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# Least privilege: the pipeline can only touch resources named "uptime-monitor*".
locals {
  deploy_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TerraformState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [aws_s3_bucket.tf_state.arn, "${aws_s3_bucket.tf_state.arn}/*"]
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "EcrRepository"
        Effect   = "Allow"
        Action   = "ecr:*"
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = "lambda:*"
        Resource = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.app_prefix}*"
      },
      {
        Sid      = "LambdaExecutionRole"
        Effect   = "Allow"
        Action   = "iam:*"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/${local.app_prefix}-*"
      },
      {
        Sid      = "PassRoleOnlyToLambda"
        Effect   = "Deny"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringNotEquals = { "iam:PassedToService" = "lambda.amazonaws.com" }
        }
      },
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = "dynamodb:*"
        Resource = "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${local.app_prefix}-*"
      },
      {
        Sid      = "HttpApi"
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = "arn:${local.partition}:apigateway:${local.region}::/*"
      },
      {
        Sid      = "Schedule"
        Effect   = "Allow"
        Action   = "events:*"
        Resource = "arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${local.app_prefix}-*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = "logs:*"
        Resource = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.app_prefix}*"
      },
      {
        Sid    = "ReadOnlyLookups"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "events:Describe*",
          "events:List*",
          "lambda:GetAccountSettings",
          "lambda:List*",
          "dynamodb:Describe*",
          "dynamodb:List*",
          "sns:Get*",
          "sns:List*",
          "iam:Get*",
          "iam:List*",
          "ecr:Describe*",
        ]
        Resource = "*"
      },
      {
        Sid      = "Alerts"
        Effect   = "Allow"
        Action   = "sns:*"
        Resource = "arn:${local.partition}:sns:${local.region}:${local.account_id}:${local.app_prefix}-*"
      },
      {
        Sid    = "AlarmsAndDashboard"
        Effect = "Allow"
        Action = "cloudwatch:*"
        Resource = [
          "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${local.app_prefix}-*",
          "arn:${local.partition}:cloudwatch::${local.account_id}:dashboard/${local.app_prefix}*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  count = var.use_oidc ? 1 : 0

  name   = "deploy-${local.name}"
  role   = aws_iam_role.github_deploy[0].id
  policy = local.deploy_policy
}

# --- 3b. GitHub Actions -> AWS login with an access key (use_oidc = false) ----

resource "aws_iam_user" "github_deploy" {
  count = var.use_oidc ? 0 : 1

  name = "github-deploy-${local.name}"
}

resource "aws_iam_user_policy" "github_deploy" {
  count = var.use_oidc ? 0 : 1

  name   = "deploy-${local.name}"
  user   = aws_iam_user.github_deploy[0].name
  policy = local.deploy_policy
}

resource "aws_iam_access_key" "github_deploy" {
  count = var.use_oidc ? 0 : 1

  user = aws_iam_user.github_deploy[0].name
}
