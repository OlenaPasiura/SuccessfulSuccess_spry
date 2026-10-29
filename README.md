# SuccessfulSuccess — Meetings

[![Style](https://github.com/dobosevych/SuccessfulSuccess/actions/workflows/style.yml/badge.svg)](https://github.com/dobosevych/SuccessfulSuccess/actions/workflows/style.yml)

A small web app for today's meetings: see what is on today (name, description,
participants) and add a new one from the UI. Built to `SPEC.md`.

- **Frontend** — Next.js (App Router) + shadcn/ui, styled after Canva's visual language
- **Backend** — FastAPI + SQLAlchemy 2 (async) + Alembic
- **Database** — PostgreSQL 17

## Quick start

```bash
cp .env.example .env
docker compose up --build
```

Then open:

| What | URL |
|------|-----|
| App | http://localhost:3000 |
| API docs (Swagger) | http://localhost:8000/docs |
| Health check | http://localhost:8000/health |

The backend applies migrations on start.

### Sign-in (Cognito)

Every page except the login page, and every `/api/v1` endpoint, needs a
signed-in user, and each user sees only their own meetings. Sign-in is an AWS
Cognito user pool (`infra/auth.tf`): email + password, and Google when it is
configured. Even for local development the pool lives in AWS (it is free at
this scale):

```bash
make tf-init           # initialize Terraform in infra/ (HCP Terraform: SuccessfulSuccess_spry-dev)
make infra-plan        # format check, validate, and run remote Terraform plan
make aws-auth-env      # prints COGNITO_* lines from terraform output -raw: paste them into .env
docker compose up -d   # restart so the API and the frontend pick them up
```

**Google sign-in** (optional): in Google Cloud console create an OAuth client of
type *Web application*, put its id and secret in `.env` as `GOOGLE_CLIENT_ID` /
`GOOGLE_CLIENT_SECRET`, run `make aws-deploy-auth`, and add the redirect URI it
prints (`https://<prefix>.auth.<region>.amazoncognito.com/oauth2/idpresponse`)
to the client's *Authorized redirect URIs*. Without it the Google button says
Google sign-in is not enabled.

The first time someone signs in, the frontend sends their ID token to
`POST /api/v1/me/sync`, which stores their profile (email, name, picture,
provider, last login) in the `users` table. Meetings reference `users.id`, the
Cognito `sub`.

Demo data is per user: `make seed owner=<sub>` adds a few meetings for today to
that user (their `sub` is on the user's page in the Cognito console, or `id` in
`GET /api/v1/me`).

> **Ports already in use?** Every host port is configurable in `.env`
> (`FRONTEND_PORT`, `BACKEND_PORT`, `POSTGRES_PORT`). If you change the frontend
> or backend port, update `CORS_ORIGINS` and `NEXT_PUBLIC_API_BASE_URL` to match —
> the browser talks to the published host port, not the compose service name.

## Common tasks

```bash
make up          # start the stack
make down        # stop it
make down-v      # stop it and drop the database volume
make test        # backend test suite (creates meetings_test automatically)
make lint        # ruff + eslint
make migrate     # alembic upgrade head
make seed owner=<sub>  # demo meetings for today for one user
make psql        # psql shell against the app database
make help        # everything else
```

## Windows

The same `make` targets work on Windows, with Docker Desktop (WSL 2 backend)
and [Git for Windows](https://git-scm.com/download/win) installed. There is no
need to install GNU make first: `make.cmd` in the repository root runs the
Makefile, and when `make.exe` is missing it offers to install it with winget
(`ezwinports.make`) and carries on.

```powershell
Copy-Item .env.example .env
.\make help        # PowerShell only runs scripts from the current folder with .\
.\make up-build
```

In `cmd.exe`, plain `make help` finds `make.cmd`; once make is installed,
`make help` works everywhere.

Every recipe runs in Git's bash (`C:/Program Files/Git` by default; pass
`GIT_HOME=...` if it is installed elsewhere), so `make test`, `make seed`, the
`aws-*` targets and the rest behave as on macOS and Linux. Inside WSL, plain
`make` works as on Linux.

Things that are already taken care of, and why:

- `.gitattributes` checks every file out with LF line endings. Git on Windows
  converts to CRLF by default, and a CRLF `entrypoint.sh` stops the backend
  container with `exec /app/entrypoint.sh: no such file or directory`. A clone
  made before `.gitattributes` existed keeps its CRLF files until you run
  `git rm --cached -r . && git reset --hard` (this discards local changes).
- File-change events from a Windows folder do not reach the containers, so hot
  reload polls: `WATCHPACK_POLLING` for Next.js, `WATCHFILES_FORCE_POLLING` for
  uvicorn. For faster reloads keep the clone inside WSL rather than on `C:\`.
- Git's bash rewrites arguments that look like paths (`/aws` becomes
  `C:/Program Files/Git/aws`); the Makefile turns that off with
  `MSYS_NO_PATHCONV`.
- Keep `.env` with LF line endings (copying `.env.example` does): `make` reads
  it directly, and a CRLF `.env` leaves a stray `\r` on every value.

## Deploy to AWS (ECS Fargate + S3 / CloudFront)

The project includes declarative CloudFormation templates in `infra/` and contract Makefile/make.cmd commands for managing the AWS infrastructure within **AWS Free Tier**:

- **Backend:** ECS Fargate service running behind an Application Load Balancer (ALB)
  - Tasks configured at **0.25 vCPU (256 CPU units) and 0.5 GB RAM (512 MB memory)**
  - Single Target Group (port 8000) with health check at `/health`
- **Frontend:** Static React/Vite SPA hosted in a private **S3 Standard** bucket behind **CloudFront** (HTTPS with Origin Access Control)
- **Registries:** Amazon ECR repositories for backend and frontend images (`linux/amd64`) with 5-image lifecycle expiration to keep storage within 500 MB Free Tier
- **Teardown & Cost Control:** A dedicated teardown command that cleanly destroys all resources (ALB, ECS, ECR, S3, CloudFront) to guarantee $0 balance leakage.

### Architecture

```
User Browser
  ├──HTTPS──→ CloudFront ──→ Private S3 Bucket (React SPA static assets)
  └──HTTP───→ Application Load Balancer (ALB :80) ──→ ECS Fargate Task (:8000)
```

### AWS CLI Setup & Credentials

Before deploying, ensure AWS credentials are configured. Fill them in `.env`:

```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
# Optional: only for temporary credentials (e.g. AWS Academy or SSO)
# AWS_SESSION_TOKEN=...
AWS_REGION=us-east-1
PROJECT_NAME=successfulsuccess
```

You can verify credentials anytime:
```bash
make aws-whoami
# or on Windows:
.\make.cmd aws-whoami
```

### Contract Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `make tf-init` | — | **Initialize Terraform:** Initializes provider plugins (`hashicorp/aws ~> 6.0`) and the remote HCP Terraform backend (`ooad-OlenaPasiura` / `SuccessfulSuccess_spry-dev`) in `infra/`. |
| `make infra-plan` | `make tf-plan` | **Preview Infrastructure Plan:** Runs `terraform fmt -check`, `terraform validate`, and a remote `terraform plan` in HCP Terraform Workspace `SuccessfulSuccess_spry-dev` across `infra/auth.tf`, `infra/reports.tf`, `infra/ai.tf`, and `infra/outputs.tf`. |
| `make aws-auth-env` | — | **Export Auth Outputs:** Reads Cognito identifiers via `terraform -chdir=infra output -raw <name>` and prints `.env` variables. |
| `make report-now` | — | **Trigger On-Demand Weekly Report:** Reads `report_requests_queue_url` via `terraform -chdir=infra output -raw` and sends an SQS message. |
| `make build-push` | — | **Build & push Docker images:** Builds images for AWS architecture (`x86_64` / `linux/amd64`), logs into ECR, tags images as `:latest`, and pushes to AWS ECR. |
| `make deploy` | — | **Deploy application updates:** Updates Lambda functions with the latest ECR image and reads infrastructure outputs via `terraform -chdir=infra output -raw`. |
| `make aws-logs` | — | Tail CloudWatch logs from the backend container. |
| `make aws-url` | — | Print deployed Cognito, Reports, and AI Agenda Parser endpoints from Terraform outputs. |

### Terraform & HCP Terraform Infrastructure (`infra/*.tf`)

All cloud infrastructure for Authentication, Weekly Reports, and AI Agenda Parsing was migrated from legacy CloudFormation YAML templates to **Terraform (`>= 1.10`)** with the **AWS Provider (`~> 6.0`)** in `infra/`, managed via **HCP Terraform**:

- **HCP Terraform Organization:** `ooad-OlenaPasiura`
- **HCP Terraform Workspace:** `SuccessfulSuccess_spry-dev` (Remote execution mode)
- **Dynamic AWS OIDC Authentication:** Configured via workspace variables `TFC_AWS_PROVIDER_AUTH = true` and `TFC_AWS_RUN_ROLE_ARN = arn:aws:iam::565905128959:role/tfc-workload-identity-role`
- **Architecture Decision Record:** See [`docs/adr/0007-terraform.md`](docs/adr/0007-terraform.md)

#### Files in `infra/`
- `infra/versions.tf` — Terraform `>= 1.10`, `hashicorp/aws ~> 6.0`, HCP Terraform `cloud` block (`SuccessfulSuccess_spry-dev`), and provider `default_tags` (`PROJECT_NAME` and `ManagedBy = "terraform"`).
- `infra/variables.tf` — Typed input variables (`project_name`, `region`, `google_client_secret` marked `sensitive = true`, VPC/subnet IDs, SES domain settings, and `parser_model = "us.anthropic.claude-sonnet-4-6"`).
- `infra/auth.tf` — Cognito User Pool (`successfulsuccess-users`), User Pool Domain (`successfulsuccess-565905128959`), Google OAuth Identity Provider, and public Web Client (`successfulsuccess-web`).
- `infra/reports.tf` — S3 bucket for weekly reports (`successfulsuccess-reports-565905128959`), S3 VPC Gateway Endpoint, SQS queue + DLQ, Report Builder & Report Mailer Lambda functions, EventBridge Scheduler cron (`cron(0 7 ? * MON *)`), and SES domain identity (`spry.org.ua`). Resolves S3-to-Lambda circular dependencies via separate `aws_s3_bucket.reports`, `aws_lambda_permission.report_mailer_s3`, and `aws_s3_bucket_notification.reports` resources.
- `infra/ai.tf` — Sidecar `successfulsuccess-agenda-parser` Lambda function outside the VPC, CloudWatch log group, IAM role with `bedrock:InvokeModel`, and Lambda Function URL with CORS.
- `infra/outputs.tf` — Outputs consumed by `Makefile` via `terraform -chdir=infra output -raw <output_name>`.

### Windows Support

On Windows, all commands can be run via:
- `make <command>` (if GNU make is installed)
- `.\make.cmd <command>` (Command Prompt or PowerShell)
- `.\infra.ps1 <command>` (PowerShell directly)

```bash
# .env
AWS_FRONTEND_DOMAIN=app.example.com

make aws-frontend-cert      # request + DNS-validate the certificate in us-east-1
make aws-deploy-frontend    # attach the domain to the distribution
make aws-deploy-backend     # add the new origin to the API's CORS
```

CloudFront only reads ACM certificates from **us-east-1**, and that is where
everything is deployed. `make aws-frontend-cert` (`infra/certificate.sh`) reuses
an issued or pending certificate for the domain, or requests one, then waits for
DNS validation. If the domain's Route 53 hosted zone is in this account, it
writes the validation record itself, and the frontend stack adds the A/AAAA
alias records pointing at the distribution. Otherwise both print the records
to add at your DNS provider: the validation CNAME, then a CNAME from the domain
to the distribution's `*.cloudfront.net` name.

The API keeps its function URL: a function URL cannot take a custom domain.

### Cost

- **Lambda** — 1M requests and 400,000 GB-seconds a month, always free. The
  function URL costs nothing beyond the invocation.
- **Aurora Serverless v2** is not in the free tier. It bills per ACU-hour while
  awake, nothing for compute while paused, plus storage and I/O. A demo that
  sits idle costs cents a month.
- **CloudFront** — the flat-rate Free plan: $0, 1M requests and 100 GB a month,
  never an overage charge (traffic past it may be slowed, not billed).
  **S3** — 5 GB and 20,000 GETs in the free tier; CloudFront caches most reads.
  ACM certificates are free.
- **ECR** — 500 MB in the free tier; the lifecycle policy keeps five images.

`make aws-destroy` deletes everything, database included, with no snapshot left
behind. Accounts opened after July 2025 get credits instead of the classic free
tier — check your billing console rather than assuming.

### Known trade-offs

- **No custom domain on the API**: function URLs cannot take one. Putting one on
  it would need API Gateway or a second CloudFront distribution in front.
- The database password reaches the function as a plain environment variable.
  Moving it to SSM Parameter Store or Secrets Manager is the first thing to
  harden.
- **Cold starts**: the first request after a few idle minutes waits ~1–2 s while
  Lambda starts the container, and up to ~15 s more if Aurora has paused.
- Every warm instance holds one database connection. Nothing is reserved by
  default (`MaxConcurrency=0`): new accounts have a Lambda concurrency limit of
  10 in total and Lambda refuses to reserve any of it, so that limit is the cap,
  well under the cluster's connection limit. Once the limit is raised, set
  `MaxConcurrency` to keep a spike off the database; requests beyond it get
  HTTP 429. RDS Proxy is the proper fix, and it is not free.
- The function URL is public: FastAPI checks the Cognito access token on every
  `/api/v1` request, but there is no request throttling in front of it beyond
  the concurrency limit.
- Cognito sends its emails (sign-up codes, password resets) itself, capped at 50
  a day. Switch the pool to SES before real traffic.
- Signing up with a password and later with Google under the same email makes
  two separate Cognito users, with separate meetings. Linking them needs a
  pre-sign-up Lambda trigger.
- Deleting the backend stack takes ~20 minutes: Lambda releases its VPC network
  interfaces slowly, and the security groups wait for them.
- One Aurora instance: there is no reader to fail over to.

## API

Base path `/api/v1`. Full schema at `/docs`. Everything under it needs
`Authorization: Bearer <Cognito access token>` (`401` otherwise) and only ever
touches the caller's own meetings: someone else's meeting is a `404`.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/meetings?date=&q=&limit=&offset=` | Meetings overlapping a day (today by default) |
| `GET` | `/meetings/{id}` | One meeting |
| `POST` | `/meetings` | Create a meeting |
| `PUT` | `/meetings/{id}` | Replace a meeting's details and participants |
| `DELETE` | `/meetings/{id}` | Delete a meeting and its participants |
| `GET` | `/me` | The signed-in user's profile |
| `POST` | `/me/sync` | Store the profile from the user's ID token (after sign-in) |
| `GET` | `/health` | Liveness + database check |

Every error uses one envelope:

```json
{ "error": { "code": "validation_error", "message": "…", "details": [{ "field": "ends_at", "message": "…" }] } }
```

### Time handling

Timestamps are stored in UTC and **served with the application timezone's offset**
(`APP_TIMEZONE`, default `Europe/Kyiv`). "Today" is that timezone's calendar day,
and a meeting is listed if it *overlaps* the day — so a 23:00–00:30 meeting appears
on both days. The UI reads the wall-clock time straight from the offset the API
sent, so every client shows the same time as the day it was listed under.

## Layout

```
backend/    FastAPI app (api → services → repositories → models), Alembic, tests
frontend/   Next.js app, shadcn/ui primitives in components/ui
infra/      Terraform HCL configuration (auth.tf, reports.tf, ai.tf, outputs.tf)
docs/adr/   Architecture Decision Records (including 0007-terraform.md)
docker-compose.yml
```

## Continuous integration

`.github/workflows/style.yml` runs on every push to `main` and gates style only:

| Job | Runs | Against |
|-----|------|---------|
| Backend — ruff | `ruff check` (GitHub annotations) + `ruff format --diff` | `backend/` |
| Frontend — ESLint | `npm ci` + `npm run lint` | `frontend/` |

Ruff is pinned to the version the backend image ships (0.16.6) and Node matches
the container's Node 22, so CI and local containers agree on what passes.

Reproduce either job locally:

```bash
make lint                                   # both, through the running containers
cd backend  && uvx ruff@0.16.6 check . && uvx ruff@0.16.6 format --diff .
cd frontend && npm ci && npm run lint
```

There is no deploy (CD) stage — no target is configured yet.

## Development notes

- The backend bind-mounts `./backend`, so `uvicorn --reload` picks up edits live.
- The frontend runs `next dev` in the container with the same bind mount.
- Backend tests run against a real Postgres (`meetings_test`), truncating tables
  between tests; `make test` creates that database if it is missing.



## Monorepo Architecture & Rationale

This repository is structured as a **monorepo** containing the `backend/`, `frontend/`, and infrastructure configuration (`docker-compose.yml`).

### Architectural Rationale
1. **Atomic Changes:** Having the API specification, frontend client, and database migrations in a single codebase allows unified commits. Endpoint modifications and client updates never drift apart or cause contract mismatch issues.
2. **AI Agent Context Window:** In an AI-assisted development workflow, the repository serves as the complete context window. Housing all services in a single repository tree enables the AI coding agent to inspect backend routes, ORM models, and frontend components simultaneously in a single pass without hallucinating interface contracts.
