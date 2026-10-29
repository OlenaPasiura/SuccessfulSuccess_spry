# -------------------------------------------------------------------------
# Outputs (Auth)
# -------------------------------------------------------------------------

output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  description = "Cognito User Pool Web Client ID"
  value       = aws_cognito_user_pool_client.web.id
}

output "issuer" {
  description = "The 'iss' of every token; signing keys are at <Issuer>/.well-known/jwks.json"
  value       = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "hosted_domain" {
  description = "Cognito's OAuth domain, which the frontend sends Google sign-in through"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

output "google_redirect_uri" {
  description = "Add this to the Google client's 'Authorized redirect URIs'"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/idpresponse"
}

# -------------------------------------------------------------------------
# Outputs (Reports)
# -------------------------------------------------------------------------

output "reports_bucket_name" {
  description = "S3 bucket name for weekly meeting reports"
  value       = aws_s3_bucket.reports.bucket
}

output "report_requests_queue_url" {
  description = "URL of the SQS Queue for report requests"
  value       = aws_sqs_queue.report_requests.id
}

output "report_builder_function_name" {
  description = "Name of the report builder Lambda function"
  value       = aws_lambda_function.report_builder.function_name
}

output "report_mailer_function_name" {
  description = "Name of the report mailer Lambda function"
  value       = aws_lambda_function.report_mailer.function_name
}

# -------------------------------------------------------------------------
# Outputs (AI Agenda Parser)
# -------------------------------------------------------------------------

output "agenda_parser_function_url" {
  description = "HTTPS Function URL for the Agenda Parser Lambda"
  value       = aws_lambda_function_url.agenda_parser.function_url
}

output "agenda_parser_function_name" {
  description = "Name of the Agenda Parser Lambda Function"
  value       = aws_lambda_function.agenda_parser.function_name
}

output "agenda_parser_function_arn" {
  description = "ARN of the Agenda Parser Lambda Function"
  value       = aws_lambda_function.agenda_parser.arn
}
