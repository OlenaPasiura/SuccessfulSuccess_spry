# -------------------------------------------------------------------------
# Sidecar AI Agenda Parser Lambda (Outside VPC) & Function URL
# -------------------------------------------------------------------------

resource "aws_iam_role" "agenda_parser" {
  name = "${var.project_name}-agenda-parser-role"

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

resource "aws_iam_role_policy_attachment" "agenda_parser_basic" {
  role       = aws_iam_role.agenda_parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "agenda_parser_bedrock" {
  name = "BedrockInferenceAccess"
  role = aws_iam_role.agenda_parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock-mantle:CreateInference",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "agenda_parser" {
  name              = "/aws/lambda/${var.project_name}-agenda-parser"
  retention_in_days = 7
}

resource "aws_lambda_function" "agenda_parser" {
  function_name = "${var.project_name}-agenda-parser"
  description   = "Lab 5: Parses meeting notes/emails into structured agenda via Amazon Bedrock"
  package_type  = "Image"
  image_uri     = var.image_uri
  role          = aws_iam_role.agenda_parser.arn
  timeout       = 30
  memory_size   = 512

  image_config {
    command = ["app.ai.agenda_lambda.handler"]
  }

  environment {
    variables = {
      COGNITO_REGION       = data.aws_region.current.region
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
      USER_POOL_ID         = aws_cognito_user_pool.main.id
      USER_POOL_CLIENT_ID  = aws_cognito_user_pool_client.web.id
      PARSER_MODEL         = var.parser_model
      LOG_LEVEL            = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.agenda_parser]
}

resource "aws_lambda_function_url" "agenda_parser" {
  function_name      = aws_lambda_function.agenda_parser.arn
  authorization_type = "NONE"
  invoke_mode        = "BUFFERED"

  cors {
    allow_origins = var.cors_origins
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 86400
  }
}

resource "aws_lambda_permission" "agenda_parser_url" {
  statement_id           = "successfulsuccess-ai-AgendaParserUrlPermission-vuJplsoAk5xT"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.agenda_parser.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "agenda_parser_invoke" {
  statement_id             = "successfulsuccess-ai-AgendaParserInvokePermission-PrtwI3go37sT"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.agenda_parser.function_name
  principal                = "*"
  invoked_via_function_url = true
}

