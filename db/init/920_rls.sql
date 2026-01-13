BEGIN;

-- =========================================================
-- 1. ENABLE RLS ON AUTH TABLES
-- =========================================================

ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.session_tokens ENABLE ROW LEVEL SECURITY;


-- =========================================================
-- 2. FORCE RLS (NO BYPASS, EVEN FOR OWNERS)
-- =========================================================

ALTER TABLE auth.users FORCE ROW LEVEL SECURITY;
ALTER TABLE auth.sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE auth.session_tokens FORCE ROW LEVEL SECURITY;


-- =========================================================
-- 3. USERS TABLE POLICIES
-- =========================================================

-- Users can see and update ONLY themselves
-- Soft-deleted users are invisible
CREATE POLICY users_self_access
ON auth.users
FOR SELECT
USING (
    id = current_setting('request.jwt.claims.sub', true)::uuid
    AND deleted_at IS null
);

CREATE POLICY users_self_update
ON auth.users
FOR UPDATE
USING (
    id = current_setting('request.jwt.claims.sub', true)::uuid
    AND deleted_at IS null
)
WITH CHECK (
    id = current_setting('request.jwt.claims.sub', true)::uuid
    AND deleted_at IS null
);


-- =========================================================
-- 4. SESSIONS TABLE POLICIES
-- =========================================================

-- Users can manage ONLY their own sessions
CREATE POLICY sessions_owner
ON auth.sessions
FOR ALL
USING (
    user_id = current_setting('request.jwt.claims.sub', true)::uuid
);


-- =========================================================
-- 5. SESSION TOKENS POLICIES
-- =========================================================

-- Tokens are accessible ONLY via user's sessions
CREATE POLICY tokens_via_session
ON auth.session_tokens
FOR ALL
USING (
    session_id IN (
        SELECT s.id
        FROM auth.sessions AS s
        WHERE s.user_id = current_setting('request.jwt.claims.sub', true)::uuid
    )
);


CREATE POLICY users_insert_service
ON auth.users
FOR INSERT
TO medilink_ops
WITH CHECK (true);


-- =========================================================
-- 6. OPTIONAL: BLOCK ANONYMOUS ACCESS EXPLICITLY
-- =========================================================

-- This prevents accidental anon leakage
REVOKE ALL ON auth.users FROM public;
REVOKE ALL ON auth.sessions FROM public;
REVOKE ALL ON auth.session_tokens FROM public;


COMMIT;
