# -----------------------------------------------------------------------------
# The application infrastructure. Applied automatically by GitHub Actions on
# every push to main (see .github/workflows/pipeline.yml).
#
#   EventBridge (every 5 min) ─┐
#                              ├─> Lambda (Docker image from ECR) ─> DynamoDB
#   Browser ─> API Gateway ────┘                                  └─> CloudWatch ─> SNS email
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
  }

  # "bucket" and "region" are passed by the pipeline with -backend-config.
  # use_lockfile = S3-native state locking (no DynamoDB lock table needed).
  backend "s3" {
    key          = "uptime-monitor/app.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

locals {
  name = var.project_name
  urls = [for u in split(",", var.target_urls) : trimspace(u) if trimspace(u) != ""]
}

# --- Storage: check history ---------------------------------------------------

resource "aws_dynamodb_table" "checks" {
  name         = "${local.name}-checks"
  billing_mode = "PAY_PER_REQUEST" # pay per request, no idle cost
  hash_key     = "url"
  range_key    = "checked_at"

  attribute {
    name = "url"
    type = "S"
  }

  attribute {
    name = "checked_at"
    type = "S"
  }

  # Items are deleted automatically after RETENTION_DAYS.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# --- Compute: Lambda function packaged as a Docker image --------------------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 7
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least privilege: only what the code actually does.
resource "aws_iam_role_policy" "lambda" {
  name = "${local.name}-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid      = "CheckHistory"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.checks.arn
      },
      {
        Sid      = "PublishMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = local.name }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "app" {
  function_name = local.name
  description   = "Uptime monitor - scheduled checks, dashboard and API"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.image_uri
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 30

  environment {
    variables = {
      TARGET_URLS      = join(",", local.urls)
      TABLE_NAME       = aws_dynamodb_table.checks.name
      METRIC_NAMESPACE = local.name
      APP_VERSION      = var.app_version
      RETENTION_DAYS   = tostring(var.retention_days)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [aws_iam_role_policy.lambda]
}

# --- Trigger 1: schedule (EventBridge) ----------------------------------------

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${local.name}-schedule"
  description         = "Run the uptime checks every ${var.check_interval_minutes} minutes"
  schedule_expression = "rate(${var.check_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.app.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# --- Trigger 2: HTTP API (API Gateway) ----------------------------------------

resource "aws_apigatewayv2_api" "http" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "Public dashboard and API for the uptime monitor"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app.invoke_arn
  payload_format_version = "2.0"
}

# "$default" sends every path (/, /health, /api/...) to the Lambda function,
# which does the routing itself.
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # Rate limiting protects the free tier from abuse.
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*"
}

# --- Alerting: CloudWatch alarms -> SNS -> email -------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "site_down" {
  alarm_name          = "${local.name}-site-down"
  alarm_description   = "One or more monitored websites failed 2 checks in a row."
  namespace           = local.name
  metric_name         = "SitesDown"
  statistic           = "Maximum"
  period              = var.check_interval_minutes * 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "The uptime monitor Lambda function itself is failing."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.app.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Observability: CloudWatch dashboard ---------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Response time per website (ms)"
          region  = var.aws_region
          view    = "timeSeries"
          stat    = "Average"
          period  = 300
          metrics = [for u in local.urls : [local.name, "LatencyMs", "Url", u]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Websites down"
          region  = var.aws_region
          view    = "timeSeries"
          stat    = "Maximum"
          period  = 300
          metrics = [[local.name, "SitesDown"]]
          annotations = {
            horizontal = [{ value = 1, label = "Alarm threshold", color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda invocations and errors"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.name],
            ["AWS/Lambda", "Errors", "FunctionName", local.name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Lambda duration (ms)"
          region  = var.aws_region
          view    = "timeSeries"
          stat    = "Average"
          period  = 300
          metrics = [["AWS/Lambda", "Duration", "FunctionName", local.name]]
        }
      },
    ]
  })
}
