# CareMate AI — Backend (FastAPI)

REST API for the CareMate AI healthcare platform: patient, doctor and admin
experiences, JWT auth with role-based access control, and an AI chatbot
endpoint backed by Retrieval-Augmented Generation (RAG) over a medical
knowledge base.

## Stack
- **FastAPI** + **Pydantic v2** — API layer & validation
- **SQLAlchemy 2.0** + **Alembic** — ORM & migrations
- **PostgreSQL** (+ **pgvector** extension for RAG embeddings)
- **python-jose** / **passlib[bcrypt]** — JWT auth & password hashing
- **OpenAI SDK** — chat completions + embeddings (swappable — see `app/services/`)

## Quickstart (local dev)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# Local dev can run entirely on SQLite (no Postgres needed) — the default
# DATABASE_URL in .env.example already points at sqlite:///./caremate_dev.db.
# Leave OPENAI_API_KEY blank to run the chatbot in deterministic demo mode.

uvicorn app.main:app --reload
# Dashboard: http://127.0.0.1:8000/
# API reference: http://127.0.0.1:8000/docs
```

The dashboard uses preview values until a patient signs in. Patient-specific
chat, vitals, medicines, appointments, and records load from the API after
authentication.

## Windows executable

After installing the project requirements, install PyInstaller and build the
one-folder bundle from the repository root:

```bash
pip install pyinstaller
pyinstaller --noconfirm app/main.spec
```

Run `dist/main/main.exe`; keep the adjacent `dist/main/_internal` folder with
it. The dashboard opens in your browser automatically. It uses port 8000 by
default and selects a free port if 8000 is already occupied.

## Running against real PostgreSQL

```bash
createdb caremate_db
psql caremate_db -c "CREATE EXTENSION IF NOT EXISTS vector;"
# either apply the raw reference schema directly:
psql caremate_db -f schema.sql
# ...or, preferred for ongoing development, use Alembic migrations:
alembic revision --autogenerate -m "init"
alembic upgrade head
```

Then set `DATABASE_URL` in `.env` to your Postgres connection string and
restart the app.

## Tests

```bash
pytest -q
```

Tests run against an in-memory SQLite database (see `tests/conftest.py`) so
they need no external services.

## Project layout

```
app/
  core/       settings, JWT/password helpers, RBAC dependencies
  db/         SQLAlchemy engine/session, declarative Base
  models/     one file per table (SQLAlchemy ORM)
  schemas/    Pydantic request/response models
  api/v1/     routers, one file per resource, aggregated in api.py
  services/   business logic that isn't a simple CRUD endpoint
              (rag_service.py, ai_chat_service.py)
  main.py     FastAPI app instance, middleware, router mounting
tests/        pytest suite
alembic/      migration environment (run `alembic revision --autogenerate`)
schema.sql    standalone, reviewable PostgreSQL DDL (mirrors app/models)
```

## Auth & RBAC

- `POST /api/v1/auth/register` (role: `patient` or `doctor` — doctors also
  submit `specialty` + `registration_number` and start in the doctor
  approval queue) and `POST /api/v1/auth/login` return a short-lived access
  token (60 min) and a longer refresh token (14 days). `admin` accounts are
  provisioned directly in the database — not self-registered.
- Every protected route depends on `require_patient` / `require_doctor` /
  `require_admin` / `require_doctor_or_admin` from `app/core/deps.py`, which
  read the `role` claim out of the JWT.

## AI chatbot / RAG flow

See `app/services/ai_chat_service.py`. Every inbound message is checked
against a fixed emergency-keyword list **before** any LLM call; a match
short-circuits generation and returns a reviewed, non-model-generated
escalation message pointing to emergency services. Otherwise the message is
embedded, the top-K nearest `knowledge_articles` rows are retrieved via
pgvector cosine distance, and both are passed to the LLM as grounding
context with a safety-first system prompt. See `/docs` (this repo's
companion architecture document) for the full sequence diagram.

## Security notes for production

- Swap `SECRET_KEY` for a long random value from a secrets manager (AWS
  Secrets Manager / GCP Secret Manager), never commit it.
- Health record files belong in encrypted object storage (S3 + SSE-KMS),
  never in the database — `health_records.file_url` stores only the key.
  `app/api/v1/routers/health_records.py` has a placeholder for the actual
  upload call.
- `audit_logs` should be append-only at the database-role level
  (`REVOKE UPDATE, DELETE ...`) — see the note at the bottom of `schema.sql`.
- Put the API behind HTTPS/TLS termination (ALB / API Gateway) and rotate
  JWT secrets periodically.
