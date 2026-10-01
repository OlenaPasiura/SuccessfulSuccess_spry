# PROJECT Specification: SuccessfulSuccess_spry

## 1. Overview

SuccessfulSuccess_spry is a monorepo application containing a FastAPI backend, a React frontend, and a PostgreSQL database orchestrated via Docker Compose. `docker compose up` is the single command required to build and run the whole system locally.

## 2. Repository Layout & Folder Purpose

- `backend/`
  - **Purpose:** FastAPI application, SQLAlchemy ORM models, and Alembic database migrations.
  - **Technologies:** Python 3.12 (`python:3.12-slim`), FastAPI, SQLAlchemy, Alembic, PostgreSQL driver (`psycopg2-binary` or `asyncpg`).
  - **Internal structure:**
    - `backend/app/main.py` — FastAPI app instantiation, router registration, CORS configuration. Contains no business logic.
    - `backend/app/api/meetings.py` — HTTP layer: route handlers for `GET /api/meetings` and `POST /api/meetings`. Parses requests, calls the service layer, returns responses. Contains no SQL or ORM calls directly.
    - `backend/app/models/meeting.py` — SQLAlchemy ORM model for `Meeting`.
    - `backend/app/schemas/meeting.py` — Pydantic schemas for request/response validation, separate from the ORM model.
    - `backend/app/services/meetings.py` — business logic: creating and listing meetings. The only layer that talks to the database session.
    - `backend/app/db.py` — SQLAlchemy engine, session factory, reads `DATABASE_URL` from environment.
    - `backend/alembic/` — migration scripts, managed by Alembic.
  - **Why split this way:** the HTTP layer, validation, business logic, and data access change for different reasons and at different rates. Keeping them in one `main.py` makes every change touch the same file and makes the contract between layers implicit instead of explicit.

- `frontend/`
  - **Purpose:** Single Page Application (SPA) for managing meetings.
  - **Technologies:** Node.js 20 (`node:20-alpine`), React, Vite, Tailwind CSS, shadcn/ui.
  - **Internal structure:**
    - `frontend/src/api/meetings.ts` — a thin client wrapping `fetch` calls to the backend, reading the base URL from `VITE_API_URL`.
    - `frontend/src/components/MeetingList.tsx` — renders the list of meetings.
    - `frontend/src/components/MeetingForm.tsx` — the creation form.
    - `frontend/src/App.tsx` — composes the page: list + form, re-fetches the list after a successful submit.

- `docker-compose.yml`
  - **Purpose:** Root container orchestration file. Running `docker compose up` is the single required command to build and launch all services locally.

## 3. Docker Compose Services & Dependency Contracts

### `postgres`

- **Image:** `postgres:16-alpine`
- **Ports:** `5432:5432`
- **Environment Variables:** `POSTGRES_DB=spry`, `POSTGRES_USER=spry`, `POSTGRES_PASSWORD=spry_secret`
- **Healthcheck:**
  ```yaml
  test: ["CMD-SHELL", "pg_isready -U spry -d spry"]
  interval: 5s
  timeout: 5s
  retries: 5
  ```

### `backend`

- **Build / Image:** Built from `backend/Dockerfile` using `python:3.12-slim`
- **Ports:** `8000:8000`
- **Dependencies:** `postgres` (Condition: `service_healthy`)
- **Environment Variables:**
  - `DATABASE_URL=postgresql://spry:spry_secret@postgres:5432/spry`
  - `CORS_ALLOWED_ORIGINS=http://localhost:5173`
- **Startup Sequence:** Runs Alembic database migrations (`alembic upgrade head`) first, then starts the Uvicorn server (`uvicorn app.main:app --host 0.0.0.0 --port 8000`). Both commands run as the container's entrypoint, in that order, on every container start — not at image build time, and not by hand.

### `frontend`

- **Build / Image:** Built from `frontend/Dockerfile` using `node:20-alpine`
- **Ports:** `5173:5173`
- **Dependencies:** `backend` (the frontend starts once the backend container is up; the UI itself tolerates the API being briefly unavailable and shows a loading/error state)
- **Environment Variables:**
  - `VITE_API_URL=http://localhost:8000`
- **How it talks to the backend:** the frontend calls `VITE_API_URL` directly from the browser (no dev-server proxy). The backend must therefore allow this origin via `CORS_ALLOWED_ORIGINS` / FastAPI `CORSMiddleware`.

## 4. API & Data Contracts

### Meeting Model

- `id`: Integer (Primary Key, auto-increment)
- `title`: String
- `starts_at`: ISO 8601 Timestamp String, UTC (e.g., `2026-10-01T10:00:00Z`)
- `ends_at`: ISO 8601 Timestamp String, UTC (e.g., `2026-10-01T11:00:00Z`)
- `attendee_count`: Integer

### API Endpoints

**1. List Meetings**

- HTTP Method: `GET`
- Path: `/api/meetings`
- Response Status: `200 OK`
- Response Body Schema:
  ```json
  [
    {
      "id": 1,
      "title": "Project Kickoff",
      "starts_at": "2026-10-01T10:00:00Z",
      "ends_at": "2026-10-01T11:00:00Z",
      "attendee_count": 4
    }
  ]
  ```

**2. Create Meeting**

- HTTP Method: `POST`
- Path: `/api/meetings`
- Request Body Schema:
  ```json
  {
    "title": "Architecture Review",
    "starts_at": "2026-10-01T14:00:00Z",
    "ends_at": "2026-10-01T15:00:00Z",
    "attendee_count": 3
  }
  ```
- Response Status: `201 Created`
- Response Body Schema: Returns the created Meeting object with assigned `id`.
- Validation: `title` is required and non-empty; `starts_at` must be earlier than `ends_at`; `attendee_count` must be a non-negative integer. A validation failure returns `422 Unprocessable Entity` with FastAPI's default error body.

## 5. Frontend UI Scope

A single-page view containing:

1. A list displaying all scheduled meetings fetched from `GET /api/meetings`.
2. A creation form allowing users to submit new meeting details to `POST /api/meetings` and update the list upon submission.

## 6. Notes on Secrets

`POSTGRES_PASSWORD` and `DATABASE_URL` are hardcoded in this file and in `docker-compose.yml` for local development only. When the project is deployed (CI/CD to AWS), these values must instead come from GitHub Actions secrets / the hosting platform's secret manager, never committed to the repository in their production form.
