-- ============================================================
-- CareMate AI — PostgreSQL schema
-- Mirrors app/models/*.py. Applied in production via Alembic
-- migrations; this file is the reviewable, standalone reference.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), if you switch PKs to UUID later
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector, for knowledge_articles.embedding (RAG)

-- ---------- enums ----------
CREATE TYPE user_role        AS ENUM ('patient', 'doctor', 'admin');
CREATE TYPE approval_status  AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE appt_mode        AS ENUM ('video', 'in_person');
CREATE TYPE appt_status      AS ENUM ('scheduled', 'completed', 'cancelled', 'no_show');
CREATE TYPE record_type      AS ENUM ('lab_report', 'prescription', 'imaging', 'vaccination', 'other');
CREATE TYPE vital_type       AS ENUM ('weight', 'blood_pressure', 'blood_sugar', 'heart_rate', 'sleep');
CREATE TYPE message_role     AS ENUM ('user', 'assistant', 'system');
CREATE TYPE rx_status        AS ENUM ('active', 'completed', 'cancelled');
CREATE TYPE notification_type AS ENUM ('appointment', 'medication', 'health_alert', 'system');

-- ---------- users ----------
CREATE TABLE users (
    id               BIGSERIAL PRIMARY KEY,
    full_name        VARCHAR(120) NOT NULL,
    email            VARCHAR(255) NOT NULL UNIQUE,
    phone            VARCHAR(20),
    hashed_password  VARCHAR(255) NOT NULL,
    role             user_role NOT NULL DEFAULT 'patient',
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    is_verified      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_users_email ON users (email);

CREATE TABLE doctor_profiles (
    id                    BIGSERIAL PRIMARY KEY,
    user_id               BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    specialty             VARCHAR(100) NOT NULL,
    registration_number   VARCHAR(60) NOT NULL UNIQUE,
    years_experience      INTEGER NOT NULL DEFAULT 0,
    consultation_fee      NUMERIC(10,2) NOT NULL DEFAULT 0,
    bio                   VARCHAR(1000),
    approval_status       approval_status NOT NULL DEFAULT 'pending'
);

-- ---------- appointments ----------
CREATE TABLE appointments (
    id              BIGSERIAL PRIMARY KEY,
    patient_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    doctor_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scheduled_at    TIMESTAMPTZ NOT NULL,
    mode            appt_mode NOT NULL DEFAULT 'video',
    status          appt_status NOT NULL DEFAULT 'scheduled',
    reason          VARCHAR(300),
    video_room_url  VARCHAR(500),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_appointments_patient ON appointments (patient_id);
CREATE INDEX ix_appointments_doctor  ON appointments (doctor_id);
CREATE INDEX ix_appointments_scheduled_at ON appointments (scheduled_at);

-- ---------- medications ----------
CREATE TABLE medications (
    id                  BIGSERIAL PRIMARY KEY,
    patient_id          BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name                VARCHAR(150) NOT NULL,
    dosage              VARCHAR(60) NOT NULL,
    frequency           VARCHAR(60) NOT NULL,
    time_of_day         VARCHAR(20),
    refills_remaining   INTEGER NOT NULL DEFAULT 0,
    active              BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_medications_patient ON medications (patient_id);

CREATE TABLE medication_logs (
    id               BIGSERIAL PRIMARY KEY,
    medication_id    BIGINT NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
    scheduled_date   DATE NOT NULL,
    taken            BOOLEAN NOT NULL DEFAULT FALSE,
    taken_at         TIMESTAMPTZ,
    UNIQUE (medication_id, scheduled_date)
);
CREATE INDEX ix_medication_logs_medication ON medication_logs (medication_id);

-- ---------- health records ----------
CREATE TABLE health_records (
    id               BIGSERIAL PRIMARY KEY,
    patient_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    uploaded_by_id   BIGINT REFERENCES users(id),
    record_type      record_type NOT NULL DEFAULT 'other',
    title            VARCHAR(200) NOT NULL,
    file_url         VARCHAR(500),      -- object storage key, never raw bytes
    record_date      TIMESTAMPTZ NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_health_records_patient ON health_records (patient_id);

-- ---------- vitals ----------
CREATE TABLE vital_readings (
    id                BIGSERIAL PRIMARY KEY,
    patient_id        BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vital_type        vital_type NOT NULL,
    value             NUMERIC(6,2) NOT NULL,     -- systolic, for blood_pressure
    value_secondary   NUMERIC(6,2),              -- diastolic, for blood_pressure
    unit              VARCHAR(20),
    recorded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_vital_readings_patient_type ON vital_readings (patient_id, vital_type, recorded_at DESC);

-- ---------- chat / RAG ----------
CREATE TABLE chat_conversations (
    id           BIGSERIAL PRIMARY KEY,
    patient_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title        VARCHAR(150) NOT NULL DEFAULT 'New conversation',
    language     VARCHAR(20) NOT NULL DEFAULT 'en',
    escalated    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_chat_conversations_patient ON chat_conversations (patient_id);

CREATE TABLE chat_messages (
    id                 BIGSERIAL PRIMARY KEY,
    conversation_id    BIGINT NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role               message_role NOT NULL,
    content            TEXT NOT NULL,
    retrieved_sources  VARCHAR(300),      -- comma-separated knowledge_articles.id
    flagged_emergency  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_chat_messages_conversation ON chat_messages (conversation_id);

CREATE TABLE knowledge_articles (
    id               BIGSERIAL PRIMARY KEY,
    title            VARCHAR(200) NOT NULL,
    tag              VARCHAR(80),
    body             TEXT NOT NULL,
    source_citation  VARCHAR(300),
    embedding        VECTOR(1536),      -- text-embedding-3-small dimension
    times_used       INTEGER NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Approximate nearest-neighbor index for fast RAG retrieval at scale
CREATE INDEX ix_knowledge_articles_embedding ON knowledge_articles
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ---------- prescriptions ----------
CREATE TABLE prescriptions (
    id                     BIGSERIAL PRIMARY KEY,
    patient_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    doctor_id              BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    appointment_id         BIGINT REFERENCES appointments(id),
    medication_name        VARCHAR(150) NOT NULL,
    dosage_instructions    VARCHAR(200) NOT NULL,
    notes_for_pharmacist   TEXT,
    status                 rx_status NOT NULL DEFAULT 'active',
    issued_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_prescriptions_patient ON prescriptions (patient_id);
CREATE INDEX ix_prescriptions_doctor  ON prescriptions (doctor_id);

-- ---------- notifications ----------
CREATE TABLE notifications (
    id           BIGSERIAL PRIMARY KEY,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type         notification_type NOT NULL,
    title        VARCHAR(150) NOT NULL,
    body         VARCHAR(400),
    read         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_notifications_user ON notifications (user_id, read);

-- ---------- audit log (append-only) ----------
CREATE TABLE audit_logs (
    id           BIGSERIAL PRIMARY KEY,
    actor_id     BIGINT REFERENCES users(id),
    actor_label  VARCHAR(150) NOT NULL,
    action       VARCHAR(150) NOT NULL,
    detail       VARCHAR(400),
    ip_address   VARCHAR(64),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_logs_created_at ON audit_logs (created_at DESC);

-- Revoke UPDATE/DELETE on audit_logs from the application role in production
-- so the trail is truly append-only, e.g.:
-- REVOKE UPDATE, DELETE ON audit_logs FROM caremate_app;
