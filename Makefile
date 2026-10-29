COMPOSE ?= docker compose

# Windows: run recipes using Git for Windows bash when present
ifeq ($(OS),Windows_NT)
ifeq ($(findstring msys,$(MAKE_HOST))$(findstring cygwin,$(MAKE_HOST)),)
GIT_HOME ?= C:/Program Files/Git
export PATH := $(GIT_HOME)/bin;$(GIT_HOME)/usr/bin;$(PATH)
SHELL := bash.exe
.SHELLFLAGS := -c
endif
endif

# Load environment configuration from .env if present
-include .env

# Defaults
PROJECT_NAME ?= successfulsuccess
AWS_REGION ?= us-east-1
IMAGE_TAG ?= latest
PARSER_MODEL ?= us.anthropic.claude-sonnet-4-6
TEXT ?=

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION PROJECT_NAME PARSER_MODEL TEXT
export MSYS_NO_PATHCONV := 1
export MSYS2_ARG_CONV_EXCL := *

# Prefer native AWS CLI if installed, otherwise fallback to Docker amazon/aws-cli
ifeq ($(shell which aws 2>/dev/null),)
AWS ?= docker run --rm \
	-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
	-e AWS_DEFAULT_REGION=$(AWS_REGION) -e AWS_REGION=$(AWS_REGION) \
	-v $(CURDIR):/aws -w /aws \
	amazon/aws-cli:latest
else
AWS ?= aws
endif

# Helper macro for reading Terraform outputs from infra/
tf-output = terraform -chdir=infra output -raw $(1)

define require-aws-credentials
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] && ! $(AWS) sts get-caller-identity >/dev/null 2>&1; then \
		echo "ERROR: AWS CLI is not configured or credentials are not provided."; \
		echo "Please run 'aws configure' or set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION in .env"; \
		exit 1; \
	fi
endef

.PHONY: help up up-build down down-v logs ps migrate test lint fmt \
        aws-whoami build-push deploy deploy-frontend \
        aws-logs aws-url report-now llm-hello parse \
        tf-init infra-plan tf-plan aws-auth-env

help: ## Show this help message
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- Local Docker Compose Targets ---------------------------------------------

up: ## Start local docker-compose stack
	$(COMPOSE) up

up-build: ## Rebuild images and start local stack
	$(COMPOSE) up --build

down: ## Stop local stack
	$(COMPOSE) down

down-v: ## Stop local stack and remove database volumes
	$(COMPOSE) down -v

logs: ## Tail container logs
	$(COMPOSE) logs -f

ps: ## List running services
	$(COMPOSE) ps

migrate: ## Apply database migrations locally
	$(COMPOSE) exec backend alembic upgrade head

test: ## Run backend unit tests
	docker build --platform linux/amd64 -t backend:test ./backend
	docker run --rm --entrypoint pytest backend:test -q

lint: ## Run linters on backend and frontend
	$(COMPOSE) exec backend ruff check .
	$(COMPOSE) exec frontend npm run lint

fmt: ## Format backend and frontend code
	$(COMPOSE) exec backend ruff format .
	$(COMPOSE) exec frontend npm run format

# --- Terraform Infrastructure Targets (HCP Terraform: SuccessfulSuccess_spry-dev) ---

tf-init: ## Initialize Terraform working directory in infra/
	terraform -chdir=infra init

infra-plan: ## Format check, validate, and run remote Terraform plan in infra/
	terraform -chdir=infra fmt -check
	terraform -chdir=infra validate
	terraform -chdir=infra plan

tf-plan: infra-plan ## Alias for infra-plan

aws-auth-env: ## Print Cognito configuration environment variables from Terraform outputs
	@echo "# --- Cognito Configuration (copy into .env) ---"
	@echo "COGNITO_REGION=$(AWS_REGION)"
	@echo "COGNITO_USER_POOL_ID=$$(terraform -chdir=infra output -raw user_pool_id)"
	@echo "COGNITO_CLIENT_ID=$$(terraform -chdir=infra output -raw user_pool_client_id)"
	@echo "VITE_COGNITO_REGION=$(AWS_REGION)"
	@echo "VITE_COGNITO_USER_POOL_ID=$$(terraform -chdir=infra output -raw user_pool_id)"
	@echo "VITE_COGNITO_CLIENT_ID=$$(terraform -chdir=infra output -raw user_pool_client_id)"
	@echo "VITE_COGNITO_DOMAIN=$$(terraform -chdir=infra output -raw hosted_domain)"
	@echo "VITE_COGNITO_REDIRECT_URI=http://localhost:5173/"

WEEK ?= 2026-W39
report-now: ## Send on-demand report request to SQS queue (e.g. make report-now WEEK=2026-W39)
	$(require-aws-credentials)
	@queue_url=$$(terraform -chdir=infra output -raw report_requests_queue_url | tr -d '[:space:]'); \
	test -n "$$queue_url" -a "$$queue_url" != "None" || { echo "ERROR: report_requests_queue_url not found in Terraform outputs."; exit 1; }; \
	payload='{"week": "$(WEEK)", "source": "on-demand"}'; \
	echo "Sending on-demand report request for $(WEEK) to SQS queue: $$queue_url"; \
	echo "Payload: $$payload"; \
	$(AWS) sqs send-message --queue-url "$$queue_url" --message-body "$$payload"; \
	echo "Report request queued successfully via SQS!"

llm-hello: ## Run LLM Bedrock test script using local AWS credentials
	@if python -c "import anthropic" >/dev/null 2>&1; then \
		python backend/app/ai/hello.py; \
	elif python3 -c "import anthropic" >/dev/null 2>&1; then \
		python3 backend/app/ai/hello.py; \
	else \
		docker build -q -t backend:llm ./backend >/dev/null && \
		docker run --rm \
			-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
			-e AWS_DEFAULT_REGION=$(AWS_REGION) -e AWS_REGION=$(AWS_REGION) \
			-e PARSER_MODEL=$(PARSER_MODEL) \
			-v "$$HOME/.aws:/root/.aws:ro" \
			--entrypoint python backend:llm -m app.ai.hello; \
	fi

parse: ## Parse meeting agenda text with Bedrock LLM (e.g. make parse TEXT="...")
	@if python -c "import anthropic" >/dev/null 2>&1; then \
		python backend/app/ai/agenda.py; \
	elif python3 -c "import anthropic" >/dev/null 2>&1; then \
		python3 backend/app/ai/agenda.py; \
	else \
		docker build -q -t backend:llm ./backend >/dev/null && \
		docker run --rm \
			-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
			-e AWS_DEFAULT_REGION=$(AWS_REGION) -e AWS_REGION=$(AWS_REGION) \
			-e PARSER_MODEL=$(PARSER_MODEL) -e TEXT \
			-v "$$HOME/.aws:/root/.aws:ro" \
			--entrypoint python backend:llm -m app.ai.agenda; \
	fi

# --- AWS Compute & Frontend Targets -------------------------------------------

aws-whoami: ## Check current AWS caller identity
	$(require-aws-credentials)
	$(AWS) sts get-caller-identity

build-push: ## Build Docker images for AWS (linux/amd64), tag and push to ECR
	$(require-aws-credentials)
	@account_id=$$($(AWS) sts get-caller-identity --query Account --output text | tr -d '[:space:]'); \
	registry_host="$$account_id.dkr.ecr.$(AWS_REGION).amazonaws.com"; \
	backend_repo="$$registry_host/$(PROJECT_NAME)-backend"; \
	frontend_repo="$$registry_host/$(PROJECT_NAME)-frontend"; \
	echo "Logging into Amazon ECR ($$registry_host)..."; \
	$(AWS) ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin "$$registry_host" || exit 1; \
	echo "=== [1/2] Building and Pushing Backend Image (linux/amd64) ==="; \
	docker build --platform linux/amd64 --provenance=false \
		-t "$$backend_repo:$(IMAGE_TAG)" -t "$$backend_repo:latest" ./backend || exit 1; \
	docker push "$$backend_repo:$(IMAGE_TAG)"; \
	docker push "$$backend_repo:latest"; \
	echo "=== [2/2] Building and Pushing Frontend Image (linux/amd64) ==="; \
	docker build --platform linux/amd64 --provenance=false \
		-f frontend/Dockerfile.prod \
		-t "$$frontend_repo:$(IMAGE_TAG)" -t "$$frontend_repo:latest" ./frontend || exit 1; \
	docker push "$$frontend_repo:$(IMAGE_TAG)"; \
	docker push "$$frontend_repo:latest"; \
	echo "=========================================================="; \
	echo "Images built and pushed to ECR:"; \
	echo " - $$backend_repo:latest"; \
	echo " - $$frontend_repo:latest"; \
	echo "=========================================================="

deploy: ## Update Lambda / ECS services and static files using Terraform outputs
	$(require-aws-credentials)
	@user_pool_id=$$(terraform -chdir=infra output -raw user_pool_id | tr -d '[:space:]'); \
	client_id=$$(terraform -chdir=infra output -raw user_pool_client_id | tr -d '[:space:]'); \
	cognito_domain=$$(terraform -chdir=infra output -raw hosted_domain | tr -d '[:space:]'); \
	ai_url=$$(terraform -chdir=infra output -raw agenda_parser_function_url | tr -d '[:space:]'); \
	report_builder_fn=$$(terraform -chdir=infra output -raw report_builder_function_name | tr -d '[:space:]'); \
	report_mailer_fn=$$(terraform -chdir=infra output -raw report_mailer_function_name | tr -d '[:space:]'); \
	ai_parser_fn=$$(terraform -chdir=infra output -raw agenda_parser_function_name | tr -d '[:space:]'); \
	account_id=$$($(AWS) sts get-caller-identity --query Account --output text | tr -d '[:space:]'); \
	image_uri="$$account_id.dkr.ecr.$(AWS_REGION).amazonaws.com/$(PROJECT_NAME)-backend:latest"; \
	echo "=== Updating Lambda functions with latest ECR image ($$image_uri) ==="; \
	$(AWS) lambda update-function-code --function-name "$$report_builder_fn" --image-uri "$$image_uri" >/dev/null; \
	$(AWS) lambda update-function-code --function-name "$$report_mailer_fn" --image-uri "$$image_uri" >/dev/null; \
	$(AWS) lambda update-function-code --function-name "$$ai_parser_fn" --image-uri "$$image_uri" >/dev/null; \
	echo "Cognito User Pool ID: $$user_pool_id"; \
	echo "Cognito Client ID:    $$client_id"; \
	echo "Cognito Domain:       $$cognito_domain"; \
	echo "AI Agenda Parser URL: $$ai_url"

aws-url: ## Print deployed endpoints from Terraform outputs
	@echo "Cognito Hosted Domain: https://$$(terraform -chdir=infra output -raw hosted_domain)"
	@echo "Cognito Issuer URL:    $$(terraform -chdir=infra output -raw issuer)"
	@echo "AI Agenda Parser URL:  $$(terraform -chdir=infra output -raw agenda_parser_function_url)"
	@echo "Reports S3 Bucket:     $$(terraform -chdir=infra output -raw reports_bucket_name)"
	@echo "Reports SQS Queue URL: $$(terraform -chdir=infra output -raw report_requests_queue_url)"

aws-logs: ## Follow CloudWatch logs from the backend container
	$(AWS) logs tail /ecs/$(PROJECT_NAME)-backend --follow
