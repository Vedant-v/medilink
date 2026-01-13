BEGIN;

-- =========================================================
-- USERS
-- =========================================================

-- Primary key index is automatic (id)

-- Login identifier (EMAIL-BASED LOGIN)
-- Enforces uniqueness while allowing soft-deleted re-registration
CREATE UNIQUE INDEX IF NOT EXISTS uniq_users_email_active
ON auth.users (email)
WHERE deleted_at IS NULL;

-- Fast access for RLS + joins (active users only)
CREATE INDEX IF NOT EXISTS idx_users_active
ON auth.users (id)
WHERE deleted_at IS NULL;

-- Optional: if you actually filter by primary_role
CREATE INDEX IF NOT EXISTS idx_users_primary_role_active
ON auth.users (p_role)
WHERE deleted_at IS NULL;


-- =========================================================
-- SESSIONS
-- =========================================================

-- FK lookup: user → sessions
CREATE INDEX IF NOT EXISTS idx_sessions_user_id
ON auth.sessions (user_id);

-- Active sessions only (logout-all, RLS, dashboards)
CREATE INDEX IF NOT EXISTS idx_sessions_active
ON auth.sessions (user_id)
WHERE revoked_at IS NULL;

-- Cleanup / expiry jobs
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at
ON auth.sessions (expires_at);


-- =========================================================
-- SESSION TOKENS
-- =========================================================

-- Refresh-token lookup (CRITICAL)
-- Hash must be unique to guarantee replay detection
CREATE UNIQUE INDEX IF NOT EXISTS uniq_session_tokens_hash
ON auth.session_tokens (token_hash);

-- FK lookup: session → tokens
CREATE INDEX IF NOT EXISTS idx_session_tokens_session_id
ON auth.session_tokens (session_id);

-- Active tokens only (refresh flow)
CREATE INDEX IF NOT EXISTS idx_session_tokens_active
ON auth.session_tokens (session_id)
WHERE revoked_at IS NULL;


COMMIT;
