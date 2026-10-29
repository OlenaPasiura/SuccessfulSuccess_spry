# 0007. Migration of Cloud Infrastructure from AWS CloudFormation to Terraform

Date: 2026-10-29  
Status: Accepted

## Context

In earlier iterations of **SuccessfulSuccess** (Labs 2–6), AWS infrastructure was provisioned across multiple standalone CloudFormation YAML templates (`infra/auth.yml`, `infra/reports.yml`, `infra/ai.yml`, etc.), orchestrated by shell recipes in `Makefile` and `infra.ps1`.

As the architecture evolved to include Amazon Cognito authentication (`successfulsuccess-users`), an asynchronous S3 + SQS + EventBridge Scheduler + SES weekly reporting pipeline (`successfulsuccess-report-builder`, `successfulsuccess-report-mailer`), and a sidecar Amazon Bedrock AI Agenda Parser Lambda (`successfulsuccess-agenda-parser`) with a public Function URL, managing separate CloudFormation stacks introduced several operational bottlenecks:

1. **Cross-stack wiring complexity**: Passing resource identifiers (such as `CognitoUserPoolId`, `CognitoClientId`, S3 bucket names, SQS queue URLs, and VPC/Subnet IDs) between independent CloudFormation stacks required imperative shell scripts (`aws cloudformation describe-stacks --query ...`) in `Makefile`.
2. **Circular dependencies within templates**: In Lab 5 (`reports.yml`), configuring an S3 bucket (`AWS::S3::Bucket`) with an inline `NotificationConfiguration` referencing a Lambda function (`AWS::Lambda::Function`) and its `AWS::Lambda::Permission` caused circular dependency issues during stack creation and updates.
3. **Slow feedback loop & opaque diffs**: `aws cloudformation deploy` does not provide a fast, attribute-level preview before mutating resources, making drift detection and security reviews of IAM policies difficult.
4. **Inconsistent resource tagging**: CloudFormation requires repeating `Tags` blocks on every individual resource (with inconsistent syntax such as `UserPoolTags` vs `Tags`), whereas Terraform supports provider-level `default_tags`.
5. **Single-cloud lock-in**: CloudFormation is strictly AWS-only, preventing unified multi-cloud resource management (e.g., AWS + Google Cloud Platform or external DNS/SaaS providers) within a single declarative workflow.

## Decision

We migrate the project's infrastructure from AWS CloudFormation YAML templates to **Terraform (`>= 1.10`)** using the **AWS Provider (`hashicorp/aws ~> 6.0`)** in `infra/`, backed by **HCP Terraform** (`organization = "ooad-OlenaPasiura"`, workspace `SuccessfulSuccess_spry-dev`) in **Remote Execution Mode** authenticated via **AWS IAM OIDC Workload Identity**:

1. **Modular HCL structure in `infra/`**:
   - `infra/versions.tf`: Pins `terraform >= 1.10` and `hashicorp/aws ~> 6.0`, configures the `cloud` backend for HCP Terraform (`SuccessfulSuccess_spry-dev`), and defines provider-level `default_tags` (`PROJECT_NAME = var.project_name`, `ManagedBy = "terraform"`).
   - `infra/variables.tf`: Declares typed input variables (`project_name`, `region`, `google_client_id`, `google_client_secret` marked `sensitive = true`, VPC/subnet IDs, SES domain configuration, and `parser_model = "us.anthropic.claude-sonnet-4-6"`).
   - `infra/auth.tf`: Manages the Cognito User Pool, User Pool Domain, Google OAuth Identity Provider, and Web Client.
   - `infra/reports.tf`: Manages the S3 reports bucket, S3 VPC Gateway Endpoint, SQS queue + DLQ, Report Builder & Report Mailer Lambda functions, EventBridge weekly schedule, and SES Domain Identity. Break circular dependencies by separating `aws_s3_bucket.reports`, `aws_lambda_function.report_mailer`, `aws_lambda_permission.report_mailer_s3`, and `aws_s3_bucket_notification.reports`.
   - `infra/ai.tf`: Manages the sidecar `successfulsuccess-agenda-parser` Lambda function outside the VPC, CloudWatch log group, least-privilege IAM role for Bedrock (`bedrock:InvokeModel`), and public Lambda Function URL with CORS.
   - `infra/outputs.tf`: Exposes resource identifiers and URLs (`user_pool_id`, `user_pool_client_id`, `hosted_domain`, `reports_bucket_name`, `report_requests_queue_url`, `agenda_parser_function_url`, etc.) consumed via `terraform -chdir=infra output -raw <name>`.
2. **Zero-Downtime Adoption via Declarative Imports**:
   - All 38 existing AWS resources were imported into Terraform state using declarative `import {}` blocks (`38 imported, 0 added, 0 destroyed`), after which the legacy CloudFormation stacks were removed with resources retained.

## Alternatives Considered

### 1. AWS CloudFormation (Status Quo)
- **Pros**: Native AWS service; no external state backend required.
- **Cons**: Verbose YAML templates, slow stack update cycles, awkward cross-stack output queries in shell scripts, poor drift visualization, and inability to manage non-AWS resources (such as Google Cloud or GitHub resources).

### 2. AWS CDK (Cloud Development Kit)
- **Pros**: Allows defining infrastructure in TypeScript or Python with loops, abstractions, and IDE autocompletion.
- **Cons**: AWS CDK still synthesizes templates to **AWS CloudFormation** under the hood (`cdk synth` -> CloudFormation changesets). Consequently, it inherits CloudFormation's slow deployment speeds, stack rollback states, and AWS-only scope, while adding Node.js/Python runtime dependencies and synthesis complexity.

### 3. OpenTofu
- **Pros**: Open-source, community-driven fork of Terraform (MPL 2.0) with drop-in CLI compatibility for HCL configurations.
- **Cons**: While OpenTofu is syntax-compatible, this project relies on **HCP Terraform** (Workspace `SuccessfulSuccess_spry-dev`) for managed remote state storage, state locking, audit history, and native OIDC dynamic provider credentials (`TFC_AWS_PROVIDER_AUTH`). Official HashiCorp Terraform (`>= 1.10`) integrates natively with HCP Terraform's remote execution runners and declarative `import` blocks without third-party state hosting overhead.

---

## Operational Governance & Required Answers

### 1. Who changes infrastructure and how? (Pull Requests + HCP Terraform Remote Execution)
- Infrastructure changes are never applied ad-hoc from developer laptops using static long-lived IAM keys. Instead, engineers modify `.tf` files in `infra/` on a feature branch and run `make infra-plan` (`terraform -chdir=infra plan`), which triggers a speculative remote plan in HCP Terraform (`SuccessfulSuccess_spry-dev`).
- Changes go through a **Pull Request (PR)** workflow: teammates review both the HCL diff and the HCP Terraform plan output (`to add`, `to change`, `to destroy`) before merging.
- Execution runs remotely inside **HCP Terraform Remote Execution** workers (`execution-mode = "remote"`), which authenticate to AWS dynamically via short-lived OIDC tokens (`sts:AssumeRoleWithWebIdentity` assuming `arn:aws:iam::565905128959:role/tfc-workload-identity-role`). Direct `terraform apply` calls are omitted from `Makefile` to prevent accidental unreviewed mutations.

### 2. Where are secrets and state stored? (State in HCP Terraform, Sensitive Variables in Workspace)
- **Terraform State (`terraform.tfstate`)**: Stored remotely and encrypted at rest inside the **HCP Terraform** workspace `SuccessfulSuccess_spry-dev` (organization `ooad-OlenaPasiura`). Local `.tfstate` and `.tfvars` files are explicitly excluded via `.gitignore` so state never leaks into Git history. HCP Terraform also enforces automatic state locking during runs to prevent concurrent state corruption.
- **Secrets (`google_client_secret`, OIDC Role Config)**: Marked with `sensitive = true` in `infra/variables.tf` and stored as encrypted **Sensitive Workspace Variables** inside HCP Terraform (`google_client_secret`) alongside dynamic OIDC environment variables (`TFC_AWS_PROVIDER_AUTH = true`, `TFC_AWS_RUN_ROLE_ARN`). Sensitive values are redacted (`(sensitive value)`) in all plan/apply logs and cannot be read back via the UI or API.

### 3. What to do if HCP Terraform is unavailable? (Break-Glass Recovery Procedure)
If HCP Terraform experiences an outage and an urgent production hotfix must be applied:
1. **Switch Backend Temporarily**: Comment out the `cloud {}` block in `infra/versions.tf` (or replace it with an S3 backend block pointing to a restricted recovery S3 bucket in AWS) and run `terraform init -migrate-state` or pull the latest state snapshot if cached.
2. **Re-import or Restore State**: Because all resource definitions in `infra/*.tf` are deterministic and match exact AWS physical names (`successfulsuccess-users`, `successfulsuccess-reports-565905128959`, `successfulsuccess-agenda-parser`), if the latest state snapshot is unreachable during a prolonged outage, `import {}` blocks (recoverable from git history) can reconstruct the state against live AWS APIs in under two minutes with zero resource recreation.
3. **Authenticate via Local/CI AWS Role**: Authenticate locally using temporary AWS credentials (`aws sts assume-role`) and apply the emergency fix, then re-enable the `cloud {}` block and push the updated state back to HCP Terraform (`terraform state push`) once the service recovers.

### 4. Why specifically Terraform for this project?
1. **Unified Single Graph Instead of 3 Disconnected Stacks**: Terraform combines `auth.tf`, `reports.tf`, and `ai.tf` into a single dependency graph. `aws_lambda_function.agenda_parser` directly references `aws_cognito_user_pool.main.id` and `aws_cognito_user_pool_client.web.id` in HCL without fragile bash scripts querying CloudFormation outputs.
2. **Clean Resolution of S3–Lambda Circular Dependencies**: Breaking `aws_s3_bucket.reports`, `aws_lambda_permission.report_mailer_s3`, and `aws_s3_bucket_notification.reports` into discrete Terraform resources eliminates the Lab 5 CloudFormation circular dependency problem.
3. **First-Class Declarative Imports (`import {}`)**: Terraform `>= 1.10` allowed adopting all 38 live AWS resources in place (`0 destroyed`) and verifying zero configuration drift (`No changes. Your infrastructure matches the configuration.`).
4. **Multi-Cloud & OIDC Native Readiness**: Combined with HCP Terraform and AWS OIDC Workload Identity, Terraform eliminates static AWS credentials in CI/CD and supports multi-cloud extensions (such as GCP `hashicorp/google`) within the same syntax.

## Consequences

- **Positive**:
  - Single source of truth for Auth, Reports, and AI infrastructure in `infra/*.tf`.
  - Automated `default_tags` (`PROJECT_NAME = "successfulsuccess"`, `ManagedBy = "terraform"`) across all resources.
  - Remote state locking, audit trail of runs in HCP Terraform, and passwordless AWS authentication via OIDC.
- **Negative / Trade-offs**:
  - Requires HCP Terraform workspace availability (or break-glass backend failover) for state operations.
