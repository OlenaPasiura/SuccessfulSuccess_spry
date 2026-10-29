variable "project_name" {
  description = "Prefix for the names of all AWS resources in this project."
  type        = string
  default     = "successfulsuccess"
}

variable "region" {
  description = "AWS region where resources are deployed."
  type        = string
  default     = "us-east-1"
}

variable "app_urls" {
  description = "Every URL the site is served from (each ending in '/'), used for Cognito OAuth callbacks and sign-out."
  type        = list(string)
  default = [
    "http://localhost:3000/",
    "http://localhost:5173/",
    "https://d4tkkvw104ufg.cloudfront.net/",
  ]
}

variable "google_client_id" {
  description = "OAuth client ID of a Google Cloud Web application client."
  type        = string
  default     = "50820414424-tq4b6c6rohlld8gte4taifmtenst1ahb.apps.googleusercontent.com"
}

variable "google_client_secret" {
  description = "OAuth client secret for Google sign-in."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vpc_id" {
  description = "Target VPC ID where the backend and report builder operate."
  type        = string
  default     = "vpc-07393edb281ad5f39"
}

variable "route_table_ids" {
  description = "Route table IDs to associate with the S3 VPC Gateway Endpoint."
  type        = list(string)
  default     = ["rtb-07d9386495e03579e"]
}

variable "subnet_ids" {
  description = "Subnet IDs for launching VPC-attached Lambda functions."
  type        = list(string)
  default = [
    "subnet-0a14f218c7e49de71",
    "subnet-0e4492a64370dc3e6",
    "subnet-0161f67e8e46667e6",
    "subnet-026303aeb1d6cc053",
    "subnet-0c755f167d056f672",
    "subnet-0f8f0a908445f2d26",
  ]
}

variable "security_group_ids" {
  description = "Security group IDs for the report builder Lambda function."
  type        = list(string)
  default     = ["sg-04d486bff3df09a34"]
}

variable "image_uri" {
  description = "ECR Docker image URI containing backend and Lambda handlers."
  type        = string
  default     = "565905128959.dkr.ecr.us-east-1.amazonaws.com/successfulsuccess-backend:latest"
}

variable "database_url" {
  description = "Database connection string for fetching meeting data."
  type        = string
  default     = "sqlite:////tmp/meetings.db"
}

variable "domain_name" {
  description = "Project domain name for SES Email Identity and DKIM setup."
  type        = string
  default     = "spry.org.ua"
}

variable "sender_email" {
  description = "Sender email address for weekly reports via Amazon SES."
  type        = string
  default     = "reports@spry.org.ua"
}

variable "recipient_email" {
  description = "Recipient email address for weekly reports via Amazon SES."
  type        = string
  default     = "pasiura.pn@ucu.edu.ua"
}

variable "parser_model" {
  description = "Amazon Bedrock model or inference profile ID for agenda parsing."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "cors_origins" {
  description = "Origins allowed to call the Agenda Parser Lambda Function URL."
  type        = list(string)
  default = [
    "http://localhost:5173",
    "http://localhost:3000",
    "https://d4tkkvw104ufg.cloudfront.net",
  ]
}
