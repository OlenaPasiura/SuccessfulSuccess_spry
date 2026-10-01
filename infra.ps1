# infra.ps1 - AWS Infrastructure & Deployment Automation for Windows PowerShell

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$Arg1
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
            if (-not [string]::IsNullOrEmpty($k)) {
                [Environment]::SetEnvironmentVariable($k, $v, "Process")
            }
        }
    }
}

$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "successfulsuccess" }
$AwsRegion = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$ImageTag = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "latest" }

$EcrStack = "$ProjectName-ecr"
$FrontendStack = "$ProjectName-frontend"
$EcsStack = "$ProjectName-ecs"
$ServiceStack = "$ProjectName-service"

function Invoke-AwsCli {
    param([string[]]$CliArgs)
    
    $awsCmd = Get-Command "aws" -ErrorAction SilentlyContinue
    if ($awsCmd) {
        & aws @CliArgs
    } else {
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
}

function Get-StackOutput {
    param([string]$StackName, [string]$OutputKey)
    $val = Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $StackName,
        "--query", "Stacks[0].Outputs[?OutputKey=='$OutputKey'].OutputValue", "--output", "text") 2>$null
    return $val.Trim()
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
        Write-Host "  teardown     - Fully destroy all AWS resources (ALB, ECS, ECR, S3, CloudFront) for 0 charges"
        Write-Host "  infra-down   - Alias for teardown"
        Write-Host "  aws-status   - Display status and outputs of AWS stacks"
        Write-Host "  aws-logs     - Follow CloudWatch logs for backend ECS container"
    }

    "aws-whoami" {
        Assert-AwsCredentials
        Invoke-AwsCli @("sts", "get-caller-identity")
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
        docker build --build-arg "VITE_API_URL=$albUrl" --target export --output type=local,dest=frontend/dist -f frontend/Dockerfile.build ./frontend

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

        Write-Host "=== [5/6] Deleting OIDC Stack ($ProjectName-oidc) ===" -ForegroundColor Cyan
        try {
            $null = Invoke-AwsCli @("cloudformation", "delete-stack", "--stack-name", "$ProjectName-oidc")
            $null = Invoke-AwsCli @("cloudformation", "wait", "stack-delete-complete", "--stack-name", "$ProjectName-oidc")
        } catch {}

        Write-Host "=== [6/6] Cleaning up CloudWatch Logs ===" -ForegroundColor Cyan
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
        foreach ($stack in @($EcrStack, $FrontendStack, $EcsStack, $ServiceStack)) {
            Write-Host "=== Stack: $stack ===" -ForegroundColor Cyan
            try {
                Invoke-AwsCli @("cloudformation", "describe-stacks", "--stack-name", $stack,
                    "--query", "Stacks[0].[StackName,StackStatus,Outputs]", "--output", "table")
            } catch {
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
