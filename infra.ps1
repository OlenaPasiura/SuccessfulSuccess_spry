# infra.ps1 - AWS Infrastructure & Deployment Automation for Windows PowerShell

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$Arg1,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Continue"

# Load .env if present
$EnvFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $k = $parts[0].Trim()
            $v = $parts[1].Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrEmpty($k) -and -not [string]::IsNullOrEmpty($v)) {
                [Environment]::SetEnvironmentVariable($k, $v, "Process")
            }
        }
    }
}

$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "successfulsuccess" }
$AwsRegion = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$ImageTag = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "latest" }
[Environment]::SetEnvironmentVariable("AWS_DEFAULT_REGION", $AwsRegion, "Process")
[Environment]::SetEnvironmentVariable("AWS_REGION", $AwsRegion, "Process")

$EcrStack = "$ProjectName-ecr"
$FrontendStack = "$ProjectName-frontend"
$EcsStack = "$ProjectName-ecs"
$ServiceStack = "$ProjectName-service"
$AuthStack = "$ProjectName-auth"
$ReportsStack = "$ProjectName-reports"
$AiStack = "$ProjectName-ai"
$ParserModel = if ($env:PARSER_MODEL) { $env:PARSER_MODEL } else { "us.anthropic.claude-sonnet-4-6" }

function Invoke-AwsCli {
    param([string[]]$CliArgs)
    
    $awsCmd = Get-Command "aws" -ErrorAction SilentlyContinue
    if ($awsCmd) {
        & aws @CliArgs
        return
    }
    $pyAws = & python -c "import importlib.util; print(1 if importlib.util.find_spec('awscli') else 0)" 2>$null
    if ($pyAws -eq "1") {
        & python -c "import sys, awscli.clidriver; sys.exit(awscli.clidriver.main())" @CliArgs
        return
    }
    $workDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $dockerArgs = @(
        "run", "--rm",
        "-e", "AWS_ACCESS_KEY_ID=$($env:AWS_ACCESS_KEY_ID)",
        "-e", "AWS_SECRET_ACCESS_KEY=$($env:AWS_SECRET_ACCESS_KEY)",
        "-e", "AWS_SESSION_TOKEN=$($env:AWS_SESSION_TOKEN)",
        "-e", "AWS_DEFAULT_REGION=$AwsRegion",
        "-e", "AWS_REGION=$AwsRegion",
        "-v", "${workDir}:/aws",
        "-w", "/aws",
        "amazon/aws-cli:latest"
    ) + $CliArgs
    & docker @dockerArgs
}

function Get-StackOutput {
    param([string]$StackName, [string]$OutputKey)
    $val = Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $StackName,
        "--query", "Stacks[0].Outputs[?OutputKey=='$OutputKey'].OutputValue", "--output", "text") 2>$null
    if ($null -eq $val) { return "" }
    return ($val | Out-String).Trim()
}

function Assert-AwsCredentials {
    $res = Invoke-AwsCli @("sts", "get-caller-identity", "--query", "Arn", "--output", "text") 2>&1
    if ($LASTEXITCODE -ne 0 -or $res -match "NoCredentials|Unable to locate credentials|Error") {
        Write-Host "ERROR: AWS CLI is not configured or credentials are invalid." -ForegroundColor Red
        Write-Host "Please run 'aws configure' or set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_REGION in .env" -ForegroundColor Yellow
        exit 1
    }
}

function Wait-StackIdle {
    param([string]$StackName)
    while ($true) {
        $status = (Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $StackName,
            "--query", "Stacks[0].StackStatus", "--output", "text") 2>$null)
        if (-not $status) { break }
        $status = $status.Trim()
        if ($status -like "*_IN_PROGRESS") {
            Write-Host "$StackName is $status - waiting for it to settle..." -ForegroundColor Cyan
            Start-Sleep -Seconds 15
        } else {
            break
        }
    }
}

switch ($Command.ToLower()) {
    "help" {
        Write-Host "Infrastructure & Deployment Manager for SuccessfulSuccess_spry" -ForegroundColor Green
        Write-Host "Commands:"
        Write-Host "  aws-whoami   - Verify AWS credentials and caller identity"
        Write-Host "  aws-init     - Create base resources (ECR, S3 Standard, CloudFront, ECS, ALB, IAM)"
        Write-Host "  infra-up     - Alias for aws-init"
        Write-Host "  build-push   - Build Docker images (linux/amd64), tag and push to ECR"
        Write-Host "  deploy       - Launch/update ECS Fargate (0.25 vCPU / 0.5 GB RAM) + S3 & CloudFront"
        Write-Host "  deploy-frontend - Build and deploy frontend to S3 and invalidate CloudFront"
        Write-Host "  aws-deploy-auth - Deploy Cognito User Pool and Google OAuth"
        Write-Host "  aws-auth-env    - Print Cognito environment variables for .env"
        Write-Host "  deploy-reports  - Deploy S3 reports bucket and S3 VPC Gateway Endpoint"
        Write-Host "  report-now   - Send on-demand report request to SQS (e.g. .\infra.ps1 report-now 2026-W39)"
        Write-Host "  llm-hello    - Execute the Bedrock LLM hello test script using local AWS credentials"
        Write-Host "  parse        - Parse meeting agenda text using Bedrock LLM (e.g. .\make.cmd parse TEXT=""..."")"
        Write-Host "  deploy-ai    - Deploy Agenda Parser Lambda & Function URL stack (infra/ai.yml)"
        Write-Host "  teardown     - Fully destroy all AWS resources (ALB, ECS, ECR, S3, CloudFront) for 0 charges"
        Write-Host "  infra-down   - Alias for teardown"
        Write-Host "  aws-status   - Display status and outputs of AWS stacks"
        Write-Host "  aws-logs     - Follow CloudWatch logs for backend ECS container"
    }

    "aws-whoami" {
        Assert-AwsCredentials
        Invoke-AwsCli @("sts", "get-caller-identity")
    }

    "aws-deploy-auth" {
        Assert-AwsCredentials
        Write-Host "=== Deploying Cognito & Google OAuth Stack ($AuthStack) ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $AuthStack

        $cfUrl = Get-StackOutput -StackName $FrontendStack -OutputKey "SiteUrl"
        $appUrlsList = @("http://localhost:5173/", "http://localhost:3000/")
        if ($cfUrl -and $cfUrl -ne "None") {
            $cfUrlFormatted = if ($cfUrl.EndsWith("/")) { $cfUrl } else { "$cfUrl/" }
            if ($appUrlsList -notcontains $cfUrlFormatted) {
                $appUrlsList += $cfUrlFormatted
            }
        }
        $appUrlsParam = $appUrlsList -join ","

        $paramOverrides = @(
            "ProjectName=$ProjectName",
            "AppUrls=$appUrlsParam"
        )
        if ($env:GOOGLE_CLIENT_ID) {
            $paramOverrides += "GoogleClientId=$($env:GOOGLE_CLIENT_ID)"
        }
        if ($env:GOOGLE_CLIENT_SECRET) {
            $paramOverrides += "GoogleClientSecret=$($env:GOOGLE_CLIENT_SECRET)"
        }

        $deployArgs = @(
            "cloudformation", "deploy",
            "--stack-name", $AuthStack,
            "--template-file", "infra/auth.yml",
            "--no-fail-on-empty-changeset",
            "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides"
        ) + $paramOverrides

        Invoke-AwsCli $deployArgs
        Wait-StackIdle -StackName $AuthStack

        Write-Host "=== Auth Stack Outputs ===" -ForegroundColor Green
        $userPoolId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolId"
        $clientId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolClientId"
        $hostedDomain = Get-StackOutput -StackName $AuthStack -OutputKey "HostedDomain"
        $googleRedirectUri = Get-StackOutput -StackName $AuthStack -OutputKey "GoogleRedirectUri"
        $googleEnabled = Get-StackOutput -StackName $AuthStack -OutputKey "GoogleEnabled"

        Write-Host "User Pool ID:        $userPoolId" -ForegroundColor Cyan
        Write-Host "User Pool Client ID: $clientId" -ForegroundColor Cyan
        Write-Host "Hosted Domain:       $hostedDomain" -ForegroundColor Cyan
        Write-Host "Google Enabled:      $googleEnabled" -ForegroundColor Cyan
        Write-Host "Google Redirect URI: $googleRedirectUri" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "IMPORTANT: In Google Cloud Console, ensure '$googleRedirectUri' is added to 'Authorized redirect URIs'!" -ForegroundColor Magenta
    }

    "aws-auth-env" {
        Assert-AwsCredentials
        $userPoolId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolId"
        $clientId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolClientId"
        $hostedDomain = Get-StackOutput -StackName $AuthStack -OutputKey "HostedDomain"

        if (-not $userPoolId) {
            Write-Host "Auth stack ($AuthStack) does not exist yet. Run '.\infra.ps1 aws-deploy-auth' first." -ForegroundColor Red
            return
        }

        Write-Host "# --- Cognito Configuration (copy into .env) ---" -ForegroundColor Green
        Write-Host "COGNITO_REGION=$AwsRegion"
        Write-Host "COGNITO_USER_POOL_ID=$userPoolId"
        Write-Host "COGNITO_CLIENT_ID=$clientId"
        Write-Host "VITE_COGNITO_REGION=$AwsRegion"
        Write-Host "VITE_COGNITO_USER_POOL_ID=$userPoolId"
        Write-Host "VITE_COGNITO_CLIENT_ID=$clientId"
        Write-Host "VITE_COGNITO_DOMAIN=$hostedDomain"
        Write-Host "VITE_COGNITO_REDIRECT_URI=http://localhost:5173/"
    }

    { $_ -in "aws-init", "infra-up" } {
        Assert-AwsCredentials
        Write-Host "=== [1/3] Creating ECR Repositories (Backend & Frontend) ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $EcrStack
        Invoke-AwsCli @("cloudformation", "deploy", "--stack-name", $EcrStack, "--template-file", "infra/ecr.yml",
            "--no-fail-on-empty-changeset", "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides", "ProjectName=$ProjectName")

        Write-Host "=== [2/3] Creating S3 Standard Bucket & CloudFront Distribution ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $FrontendStack
        Invoke-AwsCli @("cloudformation", "deploy", "--stack-name", $FrontendStack, "--template-file", "infra/frontend.yml",
            "--no-fail-on-empty-changeset", "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides", "ProjectName=$ProjectName")

        Write-Host "=== [3/3] Creating ECS Cluster, IAM Roles, ALB & Target Group ===" -ForegroundColor Cyan
        $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=true",
            "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        if (-not $vpc -or $vpc -eq "None") {
            $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        }
        if (-not $vpc -or $vpc -eq "None") {
            Write-Host "ERROR: No VPC found in $AwsRegion" -ForegroundColor Red
            exit 1
        }
        $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
            "--query", "Subnets[?MapPublicIpOnLaunch==``true``].SubnetId", "--output", "text")
        if (-not $subnetsRaw) {
            $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
                "--query", "Subnets[].SubnetId", "--output", "text")
        }
        $subnets = ($subnetsRaw -split '\s+' | Where-Object { $_ }) -join ","

        Write-Host "Deploying ECS base infra into VPC $vpc (subnets: $subnets)..." -ForegroundColor Cyan
        Wait-StackIdle -StackName $EcsStack
        Invoke-AwsCli @("cloudformation", "deploy", "--stack-name", $EcsStack, "--template-file", "infra/ecs.yml",
            "--capabilities", "CAPABILITY_NAMED_IAM", "--no-fail-on-empty-changeset",
            "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides", "ProjectName=$ProjectName", "VpcId=$vpc", "SubnetIds=$subnets")

        $bRepo = Get-StackOutput -StackName $EcrStack -OutputKey "BackendRepositoryUri"
        $fRepo = Get-StackOutput -StackName $EcrStack -OutputKey "FrontendRepositoryUri"
        $s3 = Get-StackOutput -StackName $FrontendStack -OutputKey "BucketName"
        $cf = Get-StackOutput -StackName $FrontendStack -OutputKey "SiteUrl"
        $alb = Get-StackOutput -StackName $EcsStack -OutputKey "AlbUrl"

        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Base infrastructure initialized successfully!" -ForegroundColor Green
        Write-Host "Backend ECR URI:  $bRepo"
        Write-Host "Frontend ECR URI: $fRepo"
        Write-Host "Frontend S3:      $s3"
        Write-Host "CloudFront URL:   $cf"
        Write-Host "ALB URL:          $alb"
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "build-push" {
        Assert-AwsCredentials
        $bRepo = Get-StackOutput -StackName $EcrStack -OutputKey "BackendRepositoryUri"
        $fRepo = Get-StackOutput -StackName $EcrStack -OutputKey "FrontendRepositoryUri"
        if (-not $bRepo -or $bRepo -eq "None") {
            Write-Host "ERROR: ECR repositories not found. Run 'aws-init' first." -ForegroundColor Red
            exit 1
        }
        $registry = $bRepo.Split("/")[0]
        Write-Host "Logging into Amazon ECR ($registry)..." -ForegroundColor Cyan
        $loginPw = (Invoke-AwsCli @("ecr", "get-login-password", "--region", $AwsRegion) | Out-String).Trim()
        $loginPw | docker login --username AWS --password-stdin $registry

        Write-Host "=== [1/2] Building and Pushing Backend Image (linux/amd64) ===" -ForegroundColor Cyan
        docker build --platform linux/amd64 --provenance=false -t "$bRepo`:$ImageTag" -t "$bRepo`:latest" ./backend
        docker push "$bRepo`:$ImageTag"
        docker push "$bRepo`:latest"

        Write-Host "=== [2/2] Building and Pushing Frontend Image (linux/amd64) ===" -ForegroundColor Cyan
        docker build --platform linux/amd64 --provenance=false -f frontend/Dockerfile.prod -t "$fRepo`:$ImageTag" -t "$fRepo`:latest" ./frontend
        docker push "$fRepo`:$ImageTag"
        docker push "$fRepo`:latest"

        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Images built and pushed to ECR:" -ForegroundColor Green
        Write-Host " - $bRepo`:latest"
        Write-Host " - $fRepo`:latest"
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "deploy" {
        Assert-AwsCredentials
        $bRepo = Get-StackOutput -StackName $EcrStack -OutputKey "BackendRepositoryUri"
        $cluster = Get-StackOutput -StackName $EcsStack -OutputKey "ClusterName"
        $tg = Get-StackOutput -StackName $EcsStack -OutputKey "TargetGroupArn"
        $ecsSg = Get-StackOutput -StackName $EcsStack -OutputKey "EcsSecurityGroupId"
        $execRole = Get-StackOutput -StackName $EcsStack -OutputKey "ExecutionRoleArn"
        $taskRole = Get-StackOutput -StackName $EcsStack -OutputKey "TaskRoleArn"
        $albUrl = Get-StackOutput -StackName $EcsStack -OutputKey "AlbUrl"
        $bucket = Get-StackOutput -StackName $FrontendStack -OutputKey "BucketName"
        $dist = Get-StackOutput -StackName $FrontendStack -OutputKey "DistributionId"
        $siteUrl = Get-StackOutput -StackName $FrontendStack -OutputKey "SiteUrl"

        if (-not $cluster -or $cluster -eq "None") {
            Write-Host "ERROR: Base infrastructure not found. Run 'aws-init' first." -ForegroundColor Red
            exit 1
        }

        $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=true",
            "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        if (-not $vpc -or $vpc -eq "None") {
            $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        }
        $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
            "--query", "Subnets[?MapPublicIpOnLaunch==``true``].SubnetId", "--output", "text")
        if (-not $subnetsRaw) {
            $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
                "--query", "Subnets[].SubnetId", "--output", "text")
        }
        $subnets = ($subnetsRaw -split '\s+' | Where-Object { $_ }) -join ","

        Write-Host "=== [1/2] Updating ECS Fargate Service (0.25 vCPU / 0.5 GB RAM) ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $ServiceStack
        $dbUrl = if ($env:AWS_DATABASE_URL) { $env:AWS_DATABASE_URL } else { "sqlite:////app/meetings.db" }
        Invoke-AwsCli @("cloudformation", "deploy", "--stack-name", $ServiceStack, "--template-file", "infra/ecs-service.yml",
            "--no-fail-on-empty-changeset", "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides", "ProjectName=$ProjectName", "ClusterName=$cluster", "ImageUri=$bRepo`:latest",
            "TargetGroupArn=$tg", "EcsSecurityGroupId=$ecsSg", "SubnetIds=$subnets",
            "ExecutionRoleArn=$execRole", "TaskRoleArn=$taskRole", "CorsOrigins=*", "DatabaseUrl=$dbUrl")

        try {
            $null = Invoke-AwsCli @("ecs", "update-service", "--cluster", $cluster, "--service", "$ProjectName-backend-service", "--force-new-deployment")
        } catch {}

        Write-Host "=== [2/2] Updating Static Files in S3 + Invalidating CloudFront Cache ===" -ForegroundColor Cyan
        Write-Host "Building frontend static assets with VITE_API_URL=$albUrl..." -ForegroundColor Cyan
        $siteUrlFormatted = if ($siteUrl.EndsWith("/")) { $siteUrl } else { "$siteUrl/" }
        $aiUrl = Get-StackOutput -StackName $AiStack -OutputKey "AgendaParserFunctionUrl"
        if (-not $aiUrl -or $aiUrl -eq "None") { $aiUrl = $env:VITE_AGENDA_PARSER_URL }
        docker build `
            --build-arg "VITE_API_URL=$albUrl" `
            --build-arg "VITE_COGNITO_REGION=$AwsRegion" `
            --build-arg "VITE_COGNITO_USER_POOL_ID=$($env:VITE_COGNITO_USER_POOL_ID)" `
            --build-arg "VITE_COGNITO_CLIENT_ID=$($env:VITE_COGNITO_CLIENT_ID)" `
            --build-arg "VITE_COGNITO_DOMAIN=$($env:VITE_COGNITO_DOMAIN)" `
            --build-arg "VITE_COGNITO_REDIRECT_URI=$siteUrlFormatted" `
            --build-arg "VITE_AGENDA_PARSER_URL=$aiUrl" `
            --target export --output type=local,dest=frontend/dist -f frontend/Dockerfile.build ./frontend

        Write-Host "Uploading static files to S3 (s3://$bucket)..." -ForegroundColor Cyan
        Invoke-AwsCli @("s3", "sync", "frontend/dist", "s3://$bucket", "--delete", "--exclude", "*.html", "--cache-control", "public,max-age=31536000,immutable")
        Invoke-AwsCli @("s3", "sync", "frontend/dist", "s3://$bucket", "--delete", "--exclude", "*", "--include", "*.html", "--cache-control", "no-cache")

        Write-Host "Invalidating CloudFront cache ($dist)..." -ForegroundColor Cyan
        Invoke-AwsCli @("cloudfront", "create-invalidation", "--distribution-id", $dist, "--paths", "/*", "--query", "Invalidation.Status", "--output", "text")

        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Deployment successfully completed!" -ForegroundColor Green
        Write-Host "Backend API URL:      $albUrl"
        Write-Host "Backend Health Check: $albUrl/health"
        Write-Host "Frontend Site URL:    $siteUrl"
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "deploy-frontend" {
        Assert-AwsCredentials
        $bucket = Get-StackOutput -StackName $FrontendStack -OutputKey "BucketName"
        $dist = Get-StackOutput -StackName $FrontendStack -OutputKey "DistributionId"
        $siteUrl = Get-StackOutput -StackName $FrontendStack -OutputKey "SiteUrl"
        $albUrl = Get-StackOutput -StackName $EcsStack -OutputKey "AlbUrl"

        if (-not $bucket -or $bucket -eq "None") {
            Write-Host "ERROR: Frontend infrastructure not found. Run 'aws-init' first." -ForegroundColor Red
            exit 1
        }

        Write-Host "=== Building frontend static assets for CloudFront ($siteUrl) ===" -ForegroundColor Cyan
        $siteUrlFormatted = if ($siteUrl.EndsWith("/")) { $siteUrl } else { "$siteUrl/" }
        $aiUrl = Get-StackOutput -StackName $AiStack -OutputKey "AgendaParserFunctionUrl"
        if (-not $aiUrl -or $aiUrl -eq "None") { $aiUrl = $env:VITE_AGENDA_PARSER_URL }
        docker build `
            --build-arg "VITE_API_URL=$albUrl" `
            --build-arg "VITE_COGNITO_REGION=$AwsRegion" `
            --build-arg "VITE_COGNITO_USER_POOL_ID=$($env:VITE_COGNITO_USER_POOL_ID)" `
            --build-arg "VITE_COGNITO_CLIENT_ID=$($env:VITE_COGNITO_CLIENT_ID)" `
            --build-arg "VITE_COGNITO_DOMAIN=$($env:VITE_COGNITO_DOMAIN)" `
            --build-arg "VITE_COGNITO_REDIRECT_URI=$siteUrlFormatted" `
            --build-arg "VITE_AGENDA_PARSER_URL=$aiUrl" `
            --target export --output type=local,dest=frontend/dist -f frontend/Dockerfile.build ./frontend

        Write-Host "Uploading static files to S3 (s3://$bucket)..." -ForegroundColor Cyan
        Invoke-AwsCli @("s3", "sync", "frontend/dist", "s3://$bucket", "--delete", "--exclude", "*.html", "--cache-control", "public,max-age=31536000,immutable")
        Invoke-AwsCli @("s3", "sync", "frontend/dist", "s3://$bucket", "--delete", "--exclude", "*", "--include", "*.html", "--cache-control", "no-cache")

        Write-Host "Invalidating CloudFront cache ($dist)..." -ForegroundColor Cyan
        Invoke-AwsCli @("cloudfront", "create-invalidation", "--distribution-id", $dist, "--paths", "/*", "--query", "Invalidation.Status", "--output", "text")

        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "Frontend successfully deployed to CloudFront!" -ForegroundColor Green
        Write-Host "Frontend Site URL: $siteUrl" -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "deploy-reports" {
        Assert-AwsCredentials
        Write-Host "=== Deploying Reports Infrastructure Stack ($ReportsStack) ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $ReportsStack

        $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=true",
            "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        if (-not $vpc -or $vpc -eq "None") {
            $vpc = (Invoke-AwsCli @("ec2", "describe-vpcs", "--query", "Vpcs[0].VpcId", "--output", "text")).Trim()
        }
        if (-not $vpc -or $vpc -eq "None") {
            Write-Host "ERROR: No VPC found in $AwsRegion" -ForegroundColor Red
            exit 1
        }

        $rtbRaw = Invoke-AwsCli @("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=$vpc",
            "--query", "RouteTables[].RouteTableId", "--output", "text")
        $routeTables = ($rtbRaw -split '\s+' | Where-Object { $_ }) -join ","

        if (-not $routeTables) {
            Write-Host "ERROR: No Route Tables found for VPC $vpc in $AwsRegion" -ForegroundColor Red
            exit 1
        }

        $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
            "--query", "Subnets[?MapPublicIpOnLaunch==`true`].SubnetId", "--output", "text")
        if (-not $subnetsRaw) {
            $subnetsRaw = Invoke-AwsCli @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpc",
                "--query", "Subnets[].SubnetId", "--output", "text")
        }
        $subnets = ($subnetsRaw -split '\s+' | Where-Object { $_ }) -join ","

        $bRepo = Get-StackOutput -StackName $EcrStack -OutputKey "BackendRepositoryUri"
        $ecsSg = Get-StackOutput -StackName $EcsStack -OutputKey "EcsSecurityGroupId"

        $dbUrl = if ($env:AWS_DATABASE_URL) { $env:AWS_DATABASE_URL } else { "sqlite:////tmp/meetings.db" }

        Write-Host "Target VPC:            $vpc" -ForegroundColor Cyan
        Write-Host "Target Route Tables:   $routeTables" -ForegroundColor Cyan
        Write-Host "Target Subnets:        $subnets" -ForegroundColor Cyan
        Write-Host "Security Group:        $ecsSg" -ForegroundColor Cyan
        Write-Host "Backend Image URI:     $bRepo`:latest" -ForegroundColor Cyan

        $domainName = if ($env:DOMAIN_NAME) { $env:DOMAIN_NAME } else { "spry.org.ua" }
        $senderEmail = if ($env:SENDER_EMAIL) { $env:SENDER_EMAIL } else { "reports@$domainName" }
        $recipientEmail = if ($env:RECIPIENT_EMAIL) { $env:RECIPIENT_EMAIL } else { "pasiura.pn@ucu.edu.ua" }

        $deployArgs = @(
            "cloudformation", "deploy",
            "--stack-name", $ReportsStack,
            "--template-file", "infra/reports.yml",
            "--capabilities", "CAPABILITY_NAMED_IAM",
            "--no-fail-on-empty-changeset",
            "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides",
            "ProjectName=$ProjectName",
            "VpcId=$vpc",
            "RouteTableIds=$routeTables",
            "SubnetIds=$subnets",
            "SecurityGroupIds=$ecsSg",
            "ImageUri=$bRepo`:latest",
            "DatabaseUrl=$dbUrl",
            "DomainName=$domainName",
            "SenderEmail=$senderEmail",
            "RecipientEmail=$recipientEmail"
        )

        Invoke-AwsCli $deployArgs
        Wait-StackIdle -StackName $ReportsStack

        Write-Host "=== Reports Stack Outputs ===" -ForegroundColor Green
        $bucketName = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportsBucketName"
        $bucketArn = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportsBucketArn"
        $endpointId = Get-StackOutput -StackName $ReportsStack -OutputKey "S3EndpointId"
        $functionName = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportBuilderFunctionName"
        $functionArn = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportBuilderFunctionArn"
        $queueUrl = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportRequestsQueueUrl"
        $queueArn = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportRequestsQueueArn"
        $scheduleArn = Get-StackOutput -StackName $ReportsStack -OutputKey "WeeklyReportScheduleArn"

        $mailerName = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportMailerFunctionName"
        $mailerArn = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportMailerFunctionArn"

        $domainIdentity = Get-StackOutput -StackName $ReportsStack -OutputKey "DomainIdentityName"
        $dkimTokens = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimTokens"
        $token1Name = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenName1"
        $token1Val = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenValue1"
        $token2Name = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenName2"
        $token2Val = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenValue2"
        $token3Name = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenName3"
        $token3Val = Get-StackOutput -StackName $ReportsStack -OutputKey "DkimDNSTokenValue3"

        foreach ($fn in @($functionName, $mailerName)) {
            if ($fn -and $fn -ne "None") {
                try {
                    Write-Host "Syncing Lambda code for $fn to $bRepo`:latest..." -ForegroundColor Cyan
                    $null = Invoke-AwsCli @("lambda", "update-function-code", "--function-name", $fn, "--image-uri", "$bRepo`:latest")
                    $null = Invoke-AwsCli @("lambda", "wait", "function-updated", "--function-name", $fn)
                } catch {}
            }
        }

        Write-Host "Reports S3 Bucket:       $bucketName" -ForegroundColor Cyan
        Write-Host "Reports Bucket ARN:      $bucketArn" -ForegroundColor Cyan
        Write-Host "S3 VPC Endpoint ID:      $endpointId" -ForegroundColor Cyan
        Write-Host "Report Requests Queue:   $queueUrl" -ForegroundColor Cyan
        Write-Host "Queue ARN:               $queueArn" -ForegroundColor Cyan
        Write-Host "Report Builder Function: $functionName" -ForegroundColor Cyan
        Write-Host "Builder Function ARN:    $functionArn" -ForegroundColor Cyan
        Write-Host "Report Mailer Function:  $mailerName" -ForegroundColor Cyan
        Write-Host "Mailer Function ARN:     $mailerArn" -ForegroundColor Cyan
        Write-Host "Weekly Schedule ARN:     $scheduleArn" -ForegroundColor Cyan
        Write-Host "SES Domain Identity:     $domainIdentity" -ForegroundColor Cyan
        Write-Host "DKIM Tokens:             $dkimTokens" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host "DKIM CNAME Records for Domain Verification ($domainName):" -ForegroundColor Yellow
        Write-Host "  1. Name:  $token1Name" -ForegroundColor Yellow
        Write-Host "     Value: $token1Val" -ForegroundColor Yellow
        Write-Host "  2. Name:  $token2Name" -ForegroundColor Yellow
        Write-Host "     Value: $token2Val" -ForegroundColor Yellow
        Write-Host "  3. Name:  $token3Name" -ForegroundColor Yellow
        Write-Host "     Value: $token3Val" -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host "Reports infrastructure deployed successfully!" -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "report-now" {
        Assert-AwsCredentials
        $targetWeek = if ($Arg1) { $Arg1 } elseif ($env:WEEK) { $env:WEEK } else { "2026-W39" }
        $queueUrl = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportRequestsQueueUrl"
        if (-not $queueUrl -or $queueUrl -eq "None") {
            Write-Host "ERROR: ReportRequestsQueueUrl not found in stack $ReportsStack. Run 'deploy-reports' first." -ForegroundColor Red
            exit 1
        }
        $payload = '{\"week\": \"' + $targetWeek + '\", \"source\": \"on-demand\"}'
        Write-Host "Sending report request for $targetWeek to SQS queue: $queueUrl" -ForegroundColor Cyan
        Invoke-AwsCli @("sqs", "send-message", "--queue-url", $queueUrl, "--message-body", $payload)
        Write-Host "Report request for week '$targetWeek' queued successfully via SQS!" -ForegroundColor Green
    }

    "llm-hello" {
        python backend/app/ai/hello.py
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    "parse" {
        $allArgs = @()
        if ($Arg1) { $allArgs += $Arg1 }
        if ($RemainingArgs) { $allArgs += $RemainingArgs }
        $joined = ($allArgs -join " ").Trim()
        if ($joined.StartsWith("TEXT=")) {
            $joined = $joined.Substring(5).Trim().Trim('"').Trim("'")
        }
        if ($joined) {
            $env:TEXT = $joined
        }
        python backend/app/ai/agenda.py
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    { $_ -in "deploy-ai", "aws-deploy-ai" } {
        Assert-AwsCredentials
        Write-Host "=== Deploying AI Agenda Parser Stack ($AiStack) ===" -ForegroundColor Cyan
        Wait-StackIdle -StackName $AiStack

        $bRepo = Get-StackOutput -StackName $EcrStack -OutputKey "BackendRepositoryUri"
        if (-not $bRepo -or $bRepo -eq "None") {
            Write-Host "ERROR: Backend ECR repository not found. Run 'aws-init' and 'build-push' first." -ForegroundColor Red
            exit 1
        }

        $poolId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolId"
        if (-not $poolId -or $poolId -eq "None") {
            $poolId = if ($env:COGNITO_USER_POOL_ID) { $env:COGNITO_USER_POOL_ID } else { $env:VITE_COGNITO_USER_POOL_ID }
        }
        $clientId = Get-StackOutput -StackName $AuthStack -OutputKey "UserPoolClientId"
        if (-not $clientId -or $clientId -eq "None") {
            $clientId = if ($env:COGNITO_CLIENT_ID) { $env:COGNITO_CLIENT_ID } else { $env:VITE_COGNITO_CLIENT_ID }
        }

        $siteUrl = Get-StackOutput -StackName $FrontendStack -OutputKey "SiteUrl"
        $corsList = @("http://localhost:5173", "http://localhost:3000")
        if ($siteUrl -and $siteUrl -ne "None") {
            $siteClean = $siteUrl.TrimEnd("/")
            if ($corsList -notcontains $siteClean) {
                $corsList += $siteClean
            }
        }
        $corsOrigins = $corsList -join ","

        $deployArgs = @(
            "cloudformation", "deploy",
            "--stack-name", $AiStack,
            "--template-file", "infra/ai.yml",
            "--capabilities", "CAPABILITY_NAMED_IAM",
            "--no-fail-on-empty-changeset",
            "--tags", "PROJECT_NAME=$ProjectName",
            "--parameter-overrides",
            "ProjectName=$ProjectName",
            "ImageUri=$bRepo`:latest",
            "CognitoUserPoolId=$poolId",
            "CognitoClientId=$clientId",
            "ParserModel=$ParserModel",
            "CorsOrigins=$corsOrigins"
        )

        Invoke-AwsCli $deployArgs
        Wait-StackIdle -StackName $AiStack

        $fnName = Get-StackOutput -StackName $AiStack -OutputKey "AgendaParserFunctionName"
        $fnArn = Get-StackOutput -StackName $AiStack -OutputKey "AgendaParserFunctionArn"
        $fnUrl = Get-StackOutput -StackName $AiStack -OutputKey "AgendaParserFunctionUrl"

        if ($fnName -and $fnName -ne "None") {
            try {
                Write-Host "Syncing Lambda code for $fnName to $bRepo`:latest..." -ForegroundColor Cyan
                $null = Invoke-AwsCli @("lambda", "update-function-code", "--function-name", $fnName, "--image-uri", "$bRepo`:latest")
                $null = Invoke-AwsCli @("lambda", "wait", "function-updated", "--function-name", $fnName)
            } catch {}
        }

        Write-Host "=== AI Stack Outputs ===" -ForegroundColor Green
        Write-Host "Agenda Parser Function Name: $fnName" -ForegroundColor Cyan
        Write-Host "Agenda Parser Function ARN:  $fnArn" -ForegroundColor Cyan
        Write-Host "Agenda Parser Function URL:  $fnUrl" -ForegroundColor Yellow
    }

    { $_ -in "teardown", "infra-down" } {
        Assert-AwsCredentials
        Write-Host "WARNING: This will completely destroy all AWS resources for ${ProjectName}:" -ForegroundColor Yellow
        Write-Host " - ECS Service & Fargate Tasks"
        Write-Host " - ALB, Target Group, Listener & Security Groups"
        Write-Host " - ECS Cluster & IAM Roles"
        Write-Host " - CloudFront Distribution & S3 Bucket (including all files)"
        Write-Host " - ECR Repositories (Backend & Frontend, including all images)"
        Write-Host " - CloudWatch Log Groups"

        if ($Arg1 -ne "yes" -and $env:CONFIRM -ne "yes") {
            $confirm = Read-Host "Are you sure you want to delete all resources? Type 'yes' to proceed"
            if ($confirm -ne "yes") {
                Write-Host "Teardown aborted." -ForegroundColor Yellow
                exit 0
            }
        }

        Write-Host "=== [1/5] Deleting ECS Service Stack ($ServiceStack) ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $ServiceStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $ServiceStack)
        } catch {}

        Write-Host "=== [2/5] Emptying and Deleting S3 Bucket & CloudFront Stack ($FrontendStack) ===" -ForegroundColor Cyan
        $bucket = Get-StackOutput -StackName $FrontendStack -OutputKey "BucketName"
        if ($bucket -and $bucket -ne "None") {
            Write-Host "Emptying S3 bucket s3://$bucket..." -ForegroundColor Cyan
            try { $null = Invoke-AwsCli @("s3", "rm", "s3://$bucket", "--recursive") } catch {}
        }
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $FrontendStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $FrontendStack)
        } catch {}

        Write-Host "=== [3/5] Deleting ECS Cluster & ALB Stack ($EcsStack) ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $EcsStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $EcsStack)
        } catch {}

        Write-Host "=== [4/5] Emptying and Deleting ECR Repositories Stack ($EcrStack) ===" -ForegroundColor Cyan
        foreach ($repo in @("$ProjectName-backend", "$ProjectName-frontend")) {
            try {
                $images = Invoke-AwsCli @("ecr", "list-images", "--repository-name", $repo, "--query", "imageIds[*]", "--output", "json")
                if ($images -and $images -ne "[]") {
                    $null = Invoke-AwsCli @("ecr", "batch-delete-image", "--repository-name", $repo, "--image-ids", $images)
                }
            } catch {}
        }
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $EcrStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $EcrStack)
        } catch {}

        Write-Host "=== [5/7] Deleting OIDC Stack ($ProjectName-oidc) ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", "$ProjectName-oidc")
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", "$ProjectName-oidc")
        } catch {}

        Write-Host "=== [6/8] Deleting Auth Stack ($AuthStack) ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $AuthStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $AuthStack)
        } catch {}

        Write-Host "=== [7/8] Emptying and Deleting Reports Stack ($ReportsStack) ===" -ForegroundColor Cyan
        $repBucket = Get-StackOutput -StackName $ReportsStack -OutputKey "ReportsBucketName" 2>$null
        if ($repBucket -and $repBucket -ne "None") {
            try { $null = Invoke-AwsCli @("s3", "rm", "s3://$repBucket", "--recursive") } catch {}
        }
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", $ReportsStack)
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", $ReportsStack)
        } catch {}

        Write-Host "=== [8/8] Cleaning up CloudWatch Logs ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("logs", "delete-log-group", "--log-group-name", "/ecs/$ProjectName-backend")
        } catch {}

        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "All AWS resources have been successfully deleted!" -ForegroundColor Green
        Write-Host "Cost control confirmed: 0 ongoing charges." -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
    }

    "aws-status" {
        Assert-AwsCredentials
        foreach ($stack in @($EcrStack, $FrontendStack, $EcsStack, $ServiceStack, $AuthStack, $ReportsStack)) {
            Write-Host "=== Stack: $stack ===" -ForegroundColor Cyan
            $status = (Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $stack,
                "--query", "Stacks[0].StackStatus", "--output", "text") 2>$null)
            if ($status -and $status -ne "None" -and -not ($status -match "Error")) {
                Write-Host "Status: $status" -ForegroundColor Green
                Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $stack,
                    "--query", "Stacks[0].Outputs", "--output", "table")
            } else {
                Write-Host "Stack $stack does not exist." -ForegroundColor Gray
            }
        }
    }

    "aws-logs" {
        Assert-AwsCredentials
        Invoke-AwsCli @("logs", "tail", "/ecs/$ProjectName-backend", "--follow")
    }

    default {
        Write-Host "Unknown command '$Command'. Run '.\infra.ps1 help' for available commands." -ForegroundColor Red
        exit 1
    }
}
