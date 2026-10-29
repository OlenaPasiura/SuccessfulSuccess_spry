# -------------------------------------------------------------------------
# S3 Storage for Weekly Reports
# -------------------------------------------------------------------------

resource "aws_s3_bucket" "reports" {
  bucket = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"

  tags = {
    TestApply = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "DeleteAfter90Days"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

# -------------------------------------------------------------------------
# S3 VPC Gateway Endpoint
# -------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
}

# -------------------------------------------------------------------------
# SQS Queues for Asynchronous Report Requests
# -------------------------------------------------------------------------

resource "aws_sqs_queue" "report_requests_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  max_message_size          = 1048576
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "report_requests" {
  name                       = "${var.project_name}-report-requests"
  max_message_size           = 1048576
  visibility_timeout_seconds = 360

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# -------------------------------------------------------------------------
# Report Builder Lambda IAM Role & Function
# -------------------------------------------------------------------------

resource "aws_iam_role" "report_builder" {
  name = "${var.project_name}-report-builder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "report_builder_vpc" {
  role       = aws_iam_role.report_builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "report_builder_s3" {
  name = "S3ReportsAccess"
  role = aws_iam_role.report_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.reports.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "report_builder_sqs" {
  name = "SQSReportRequestsAccess"
  role = aws_iam_role.report_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.report_requests.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "report_builder" {
  name              = "/aws/lambda/${var.project_name}-report-builder"
  retention_in_days = 7
}

resource "aws_lambda_function" "report_builder" {
  function_name = "${var.project_name}-report-builder"
  description   = "Lab 4: Generates weekly meeting CSV reports and uploads to S3"
  package_type  = "Image"
  image_uri     = var.image_uri
  role          = aws_iam_role.report_builder.arn
  timeout       = 60
  memory_size   = 512

  image_config {
    command = ["app.reports.lambda_handler.handler"]
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = {
      REPORTS_BUCKET_NAME = aws_s3_bucket.reports.bucket
      DATABASE_URL        = var.database_url
      LOG_LEVEL           = "INFO"
    }
  }

  depends_on = [
    aws_vpc_endpoint.s3,
    aws_cloudwatch_log_group.report_builder,
  ]
}

resource "aws_lambda_event_source_mapping" "report_requests" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.report_builder.arn
  batch_size       = 1
  enabled          = true
}

# -------------------------------------------------------------------------
# EventBridge Scheduler Role & Weekly Report Schedule
# -------------------------------------------------------------------------

resource "aws_iam_role" "report_scheduler" {
  name = "${var.project_name}-report-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "report_scheduler_sqs" {
  name = "SendMessageReportRequestsQueue"
  role = aws_iam_role.report_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.report_requests.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "${var.project_name}-weekly-report-schedule"
  description                  = "Triggers weekly meeting report generator via SQS every Monday at 07:00 Kyiv time"
  schedule_expression          = "cron(0 7 ? * MON *)"
  schedule_expression_timezone = "Europe/Kyiv"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.report_scheduler.arn
    input    = "{\"week\": null, \"source\": \"schedule\"}"
  }
}

# -------------------------------------------------------------------------
# Report Mailer IAM Role & Lambda Function (Outside VPC)
# -------------------------------------------------------------------------

resource "aws_iam_role" "report_mailer" {
  name = "${var.project_name}-report-mailer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "report_mailer_basic" {
  role       = aws_iam_role.report_mailer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_mailer_s3_ses" {
  name = "MailerS3AndSESAccess"
  role = aws_iam_role.report_mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "sesv2:SendEmail",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "report_mailer" {
  name              = "/aws/lambda/${var.project_name}-report-mailer"
  retention_in_days = 7
}

resource "aws_lambda_function" "report_mailer" {
  function_name = "${var.project_name}-report-mailer"
  description   = "Lab 4 Step 5 & 6: Sends weekly meeting reports via email upon S3 upload"
  package_type  = "Image"
  image_uri     = var.image_uri
  role          = aws_iam_role.report_mailer.arn
  timeout       = 60
  memory_size   = 512

  image_config {
    command = ["app.reports.mailer_handler.handler"]
  }

  environment {
    variables = {
      SENDER_EMAIL          = "reports@${var.domain_name}"
      RECIPIENT_EMAIL       = var.recipient_email
      VERIFIED_SENDER_EMAIL = var.recipient_email
      LOG_LEVEL             = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.report_mailer]
}

resource "aws_lambda_permission" "report_mailer_s3" {
  statement_id   = "successfulsuccess-reports-ReportMailerPermission-uRnTep1WDiW8"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.report_mailer.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.report_mailer_s3]
}

# -------------------------------------------------------------------------
# SES Domain Identity
# -------------------------------------------------------------------------

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain_name
}

