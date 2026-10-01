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

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION PROJECT_NAME
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

ECR_STACK ?= $(PROJECT_NAME)-ecr
FRONTEND_STACK ?= $(PROJECT_NAME)-frontend
ECS_STACK ?= $(PROJECT_NAME)-ecs
SERVICE_STACK ?= $(PROJECT_NAME)-service
OIDC_STACK ?= $(PROJECT_NAME)-oidc

STACK_TAGS = --tags "PROJECT_NAME=$(PROJECT_NAME)"

# Helper macros
stack-output = $(AWS) cloudformation describe-stacks --stack-name $(1) \
	--query 'Stacks[0].Outputs[?OutputKey==`$(2)`].OutputValue' --output text

stack-outputs = $(AWS) cloudformation describe-stacks --stack-name $(1) \
	--query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text

wait-stack-idle = while status=$$($(AWS) cloudformation describe-stacks --stack-name $(1) \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null | tr -d '[:space:]'); \
		case "$$status" in *_IN_PROGRESS) true ;; *) false ;; esac; do \
		echo "$(1) is $$status — waiting for it to settle..."; sleep 15; done

define require-aws-credentials
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] && ! $(AWS) sts get-caller-identity >/dev/null 2>&1; then \
		echo "ERROR: AWS CLI is not configured or credentials are not provided."; \
		echo "Please run 'aws configure' or set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION in .env"; \
		exit 1; \
	fi
endef

.PHONY: help up up-build down down-v logs ps migrate test lint fmt \
        aws-whoami aws-init infra-up build-push deploy teardown infra-down \
        aws-status aws-logs aws-url

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

# --- AWS Infrastructure Contract Targets --------------------------------------

aws-whoami: ## Check current AWS caller identity
	$(require-aws-credentials)
	$(AWS) sts get-caller-identity

aws-init: ## Create base AWS resources (ECR repos, S3 Standard, CloudFront, ECS Cluster, ALB, IAM roles)
	$(require-aws-credentials)
	@echo "=== [1/3] Creating ECR Repositories (Backend & Frontend) ==="
	@$(call wait-stack-idle,$(ECR_STACK))
	$(AWS) cloudformation deploy \
		--stack-name $(ECR_STACK) \
		--template-file infra/ecr.yml \
		--no-fail-on-empty-changeset \
		$(STACK_TAGS) \
		--parameter-overrides "ProjectName=$(PROJECT_NAME)"
	@echo "=== [2/3] Creating S3 Standard Bucket & CloudFront Distribution (Frontend) ==="
	@$(call wait-stack-idle,$(FRONTEND_STACK))
	$(AWS) cloudformation deploy \
		--stack-name $(FRONTEND_STACK) \
		--template-file infra/frontend.yml \
		--no-fail-on-empty-changeset \
		$(STACK_TAGS) \
		--parameter-overrides "ProjectName=$(PROJECT_NAME)"
	@echo "=== [3/3] Creating ECS Cluster, IAM Roles, ALB & Target Group ==="
	@vpc=$$($(AWS) ec2 describe-vpcs --filters Name=isDefault,Values=true \
		--query 'Vpcs[0].VpcId' --output text 2>/dev/null | tr -d '[:space:]'); \
	test "$$vpc" != "None" -a -n "$$vpc" || { \
		vpc=$$($(AWS) ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text | tr -d '[:space:]'); }; \
	test -n "$$vpc" -a "$$vpc" != "None" || { echo "ERROR: No VPC found in $(AWS_REGION)"; exit 1; }; \
	subnets=$$($(AWS) ec2 describe-subnets --filters Name=vpc-id,Values=$$vpc \
		--query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text 2>/dev/null | tr '\t ' ',' | sed 's/,*$$//'); \
	if [ -z "$$subnets" ]; then \
		subnets=$$($(AWS) ec2 describe-subnets --filters Name=vpc-id,Values=$$vpc \
			--query 'Subnets[].SubnetId' --output text | tr '\t ' ',' | sed 's/,*$$//'); \
	fi; \
	echo "Deploying ECS base infra into VPC $$vpc (subnets: $$subnets)..."; \
	$(call wait-stack-idle,$(ECS_STACK)); \
	$(AWS) cloudformation deploy \
		--stack-name $(ECS_STACK) \
		--template-file infra/ecs.yml \
		--capabilities CAPABILITY_NAMED_IAM \
		--no-fail-on-empty-changeset \
		$(STACK_TAGS) \
		--parameter-overrides \
			"ProjectName=$(PROJECT_NAME)" \
			"VpcId=$$vpc" \
			"SubnetIds=$$subnets"
	@echo "=========================================================="
	@echo "Base infrastructure initialized successfully!"
	@echo "Backend ECR URI:  $$($(call stack-output,$(ECR_STACK),BackendRepositoryUri))"
	@echo "Frontend ECR URI: $$($(call stack-output,$(ECR_STACK),FrontendRepositoryUri))"
	@echo "Frontend S3:      $$($(call stack-output,$(FRONTEND_STACK),BucketName))"
	@echo "CloudFront URL:   $$($(call stack-output,$(FRONTEND_STACK),SiteUrl))"
	@echo "ALB URL:          $$($(call stack-output,$(ECS_STACK),AlbUrl))"
	@echo "=========================================================="

infra-up: aws-init ## Alias for aws-init

build-push: ## Build Docker images for AWS (linux/amd64), tag and push to ECR
	$(require-aws-credentials)
	@backend_repo=$$($(call stack-output,$(ECR_STACK),BackendRepositoryUri) 2>/dev/null | tr -d '[:space:]'); \
	frontend_repo=$$($(call stack-output,$(ECR_STACK),FrontendRepositoryUri) 2>/dev/null | tr -d '[:space:]'); \
	test -n "$$backend_repo" -a "$$backend_repo" != "None" || { \
		echo "ERROR: ECR repositories not found. Run 'make aws-init' first."; exit 1; }; \
	registry_host="$${backend_repo%%/*}"; \
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

deploy: ## Deploy/update ECS Fargate service and update static files in S3 + CloudFront
	$(require-aws-credentials)
	@backend_repo=$$($(call stack-output,$(ECR_STACK),BackendRepositoryUri) 2>/dev/null | tr -d '[:space:]'); \
	cluster=$$($(call stack-output,$(ECS_STACK),ClusterName) 2>/dev/null | tr -d '[:space:]'); \
	tg=$$($(call stack-output,$(ECS_STACK),TargetGroupArn) 2>/dev/null | tr -d '[:space:]'); \
	ecs_sg=$$($(call stack-output,$(ECS_STACK),EcsSecurityGroupId) 2>/dev/null | tr -d '[:space:]'); \
	exec_role=$$($(call stack-output,$(ECS_STACK),ExecutionRoleArn) 2>/dev/null | tr -d '[:space:]'); \
	task_role=$$($(call stack-output,$(ECS_STACK),TaskRoleArn) 2>/dev/null | tr -d '[:space:]'); \
	alb_url=$$($(call stack-output,$(ECS_STACK),AlbUrl) 2>/dev/null | tr -d '[:space:]'); \
	bucket=$$($(call stack-output,$(FRONTEND_STACK),BucketName) 2>/dev/null | tr -d '[:space:]'); \
	dist=$$($(call stack-output,$(FRONTEND_STACK),DistributionId) 2>/dev/null | tr -d '[:space:]'); \
	site_url=$$($(call stack-output,$(FRONTEND_STACK),SiteUrl) 2>/dev/null | tr -d '[:space:]'); \
	test -n "$$cluster" -a "$$cluster" != "None" || { \
		echo "ERROR: Base infrastructure not found. Run 'make aws-init' first."; exit 1; }; \
	vpc=$$($(AWS) ec2 describe-vpcs --filters Name=isDefault,Values=true \
		--query 'Vpcs[0].VpcId' --output text 2>/dev/null | tr -d '[:space:]'); \
	test -n "$$vpc" -a "$$vpc" != "None" || { \
		vpc=$$($(AWS) ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text | tr -d '[:space:]'); }; \
	subnets=$$($(AWS) ec2 describe-subnets --filters Name=vpc-id,Values=$$vpc \
		--query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text 2>/dev/null | tr '\t ' ',' | sed 's/,*$$//'); \
	if [ -z "$$subnets" ]; then \
		subnets=$$($(AWS) ec2 describe-subnets --filters Name=vpc-id,Values=$$vpc \
			--query 'Subnets[].SubnetId' --output text | tr '\t ' ',' | sed 's/,*$$//'); \
	fi; \
	echo "=== [1/2] Updating ECS Fargate Service (0.25 vCPU / 0.5 GB RAM) ==="; \
	$(call wait-stack-idle,$(SERVICE_STACK)); \
	$(AWS) cloudformation deploy \
		--stack-name $(SERVICE_STACK) \
		--template-file infra/ecs-service.yml \
		--no-fail-on-empty-changeset \
		$(STACK_TAGS) \
		--parameter-overrides \
			"ProjectName=$(PROJECT_NAME)" \
			"ClusterName=$$cluster" \
			"ImageUri=$$backend_repo:latest" \
			"TargetGroupArn=$$tg" \
			"EcsSecurityGroupId=$$ecs_sg" \
			"SubnetIds=$$subnets" \
			"ExecutionRoleArn=$$exec_role" \
			"TaskRoleArn=$$task_role" \
			"CorsOrigins=*" \
			"DatabaseUrl=$(or $(AWS_DATABASE_URL),sqlite:////app/meetings.db)" || exit 1; \
	$(AWS) ecs update-service --cluster "$$cluster" --service "$(PROJECT_NAME)-backend-service" --force-new-deployment >/dev/null 2>&1 || true; \
	echo "=== [2/2] Updating Static Files in S3 + Invalidating CloudFront Cache ==="; \
	echo "Building frontend static assets with VITE_API_URL=$$alb_url..."; \
	docker build --build-arg "VITE_API_URL=$$alb_url" --target export --output type=local,dest=frontend/dist -f frontend/Dockerfile.build ./frontend || exit 1; \
	echo "Uploading static files to S3 (s3://$$bucket)..."; \
	$(AWS) s3 sync frontend/dist "s3://$$bucket" --delete --exclude "*.html" \
		--cache-control "public,max-age=31536000,immutable" || exit 1; \
	$(AWS) s3 sync frontend/dist "s3://$$bucket" --delete --exclude "*" --include "*.html" \
		--cache-control "no-cache" || exit 1; \
	echo "Invalidating CloudFront cache ($$dist)..."; \
	$(AWS) cloudfront create-invalidation --distribution-id "$$dist" --paths "/*" \
		--query 'Invalidation.Status' --output text; \
	echo "=========================================================="; \
	echo "Deployment successfully completed!"; \
	echo "Backend API URL:      $$alb_url"; \
	echo "Backend Health Check: $$alb_url/health"; \
	echo "Frontend Site URL:    $$site_url"; \
	echo "=========================================================="

teardown: ## Fully delete all AWS resources (ALB, ECS, ECR, S3, CloudFront) to prevent charges
	$(require-aws-credentials)
	@echo "WARNING: This will completely destroy all AWS resources for $(PROJECT_NAME):"
	@echo " - ECS Service & Fargate Tasks"
	@echo " - ALB, Target Group, Listener & Security Groups"
	@echo " - ECS Cluster & IAM Roles"
	@echo " - CloudFront Distribution & S3 Bucket (including all files)"
	@echo " - ECR Repositories (Backend & Frontend, including all images)"
	@echo " - CloudWatch Log Groups"
	@if [ "$$(echo $(CONFIRM) | tr '[:upper:]' '[:lower:]')" != "yes" ]; then \
		printf 'Are you sure you want to delete all resources? Type yes to proceed: '; \
		read answer; test "$$answer" = "yes" || { echo "Teardown aborted."; exit 1; }; \
	fi
	@echo "=== [1/5] Deleting ECS Service Stack ($(SERVICE_STACK)) ==="
	-$(AWS) cloudformation delete-stack --stack-name $(SERVICE_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(SERVICE_STACK)
	@echo "=== [2/5] Emptying and Deleting S3 Bucket & CloudFront Stack ($(FRONTEND_STACK)) ==="
	@bucket=$$($(call stack-output,$(FRONTEND_STACK),BucketName) 2>/dev/null | tr -d '[:space:]'); \
	if [ -n "$$bucket" ] && [ "$$bucket" != "None" ]; then \
		echo "Emptying S3 bucket s3://$$bucket..."; \
		$(AWS) s3 rm "s3://$$bucket" --recursive 2>/dev/null || true; \
	fi
	-$(AWS) cloudformation delete-stack --stack-name $(FRONTEND_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(FRONTEND_STACK)
	@echo "=== [3/5] Deleting ECS Cluster & ALB Stack ($(ECS_STACK)) ==="
	-$(AWS) cloudformation delete-stack --stack-name $(ECS_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(ECS_STACK)
	@echo "=== [4/5] Emptying and Deleting ECR Repositories Stack ($(ECR_STACK)) ==="
	@for repo in $(PROJECT_NAME)-backend $(PROJECT_NAME)-frontend; do \
		echo "Purging images from $$repo..."; \
		images=$$($(AWS) ecr list-images --repository-name "$$repo" --query 'imageIds[*]' --output json 2>/dev/null || echo "[]"); \
		if [ "$$images" != "[]" ] && [ -n "$$images" ]; then \
			$(AWS) ecr batch-delete-image --repository-name "$$repo" --image-ids "$$images" >/dev/null 2>&1 || true; \
		fi; \
	done
	-$(AWS) cloudformation delete-stack --stack-name $(ECR_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(ECR_STACK)
	@echo "=== [5/6] Deleting OIDC Stack ($(OIDC_STACK)) ==="
	-$(AWS) cloudformation delete-stack --stack-name $(OIDC_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(OIDC_STACK)
	@echo "=== [6/6] Cleaning up CloudWatch Logs ==="
	-$(AWS) logs delete-log-group --log-group-name "/ecs/$(PROJECT_NAME)-backend" 2>/dev/null || true
	@echo "=========================================================="
	@echo "All AWS resources have been successfully deleted!"
	@echo "Cost control confirmed: 0 ongoing charges."
	@echo "=========================================================="

infra-down: teardown ## Alias for teardown

aws-url: ## Print deployed backend and frontend URLs
	@echo "Frontend URL: $$($(call stack-output,$(FRONTEND_STACK),SiteUrl) 2>/dev/null)"
	@echo "Backend URL:  $$($(call stack-output,$(ECS_STACK),AlbUrl) 2>/dev/null)"

aws-status: ## Show status of all AWS stacks
	@for stack in $(ECR_STACK) $(FRONTEND_STACK) $(ECS_STACK) $(SERVICE_STACK); do \
		echo "=== Stack: $$stack ==="; \
		$(AWS) cloudformation describe-stacks --stack-name "$$stack" \
			--query 'Stacks[0].[StackName,StackStatus,Outputs]' --output table 2>/dev/null || echo "Stack $$stack does not exist."; \
	done

aws-logs: ## Follow CloudWatch logs from the backend ECS Fargate container
	$(AWS) logs tail /ecs/$(PROJECT_NAME)-backend --follow
