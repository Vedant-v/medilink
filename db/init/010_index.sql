BEGIN;

-- =========================================================
-- USERS
-- =========================================================

-- Enforce unique email for active (non-deleted) users
CREATE UNIQUE INDEX IF NOT EXISTS uniq_users_email_active
ON auth.users (email)
WHERE deleted_at IS NULL;

-- OPTIONAL: keep ONLY if you query users by role
CREATE INDEX IF NOT EXISTS idx_users_primary_role_active
ON auth.users (p_role)
WHERE deleted_at IS NULL;


-- =========================================================
-- SESSIONS
-- =========================================================

-- Lookup sessions for a user (logout-all, dashboards)
CREATE INDEX IF NOT EXISTS idx_sessions_user_id
ON auth.sessions (user_id);

-- Sessions that are not revoked
-- (expiration handled at query-time)
CREATE INDEX IF NOT EXISTS idx_sessions_not_revoked
ON auth.sessions (user_id)
WHERE revoked_at IS NULL;

-- Cleanup / expiry sweeps
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at
ON auth.sessions (expires_at);


-- =========================================================
-- SESSION TOKENS (REFRESH TOKENS)
-- =========================================================

-- CRITICAL SECURITY INVARIANT:
-- Only ONE usable refresh token per session
CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_refresh_token
ON auth.session_tokens (session_id)
WHERE revoked_at IS NULL
AND used_at IS NULL;

-- Session → tokens lookup (rotation, revocation)
CREATE INDEX IF NOT EXISTS idx_session_tokens_session_id
ON auth.session_tokens (session_id);

-- Tokens that are not revoked
-- (expiration handled at query-time)
CREATE INDEX IF NOT EXISTS idx_session_tokens_not_revoked
ON auth.session_tokens (session_id)
WHERE revoked_at IS NULL;

-- Cleanup / incident response
CREATE INDEX IF NOT EXISTS idx_session_tokens_expires_at
ON auth.session_tokens (expires_at);

COMMIT;
