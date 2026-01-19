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

CREATE POLICY users_select_by_ops
ON auth.users
FOR SELECT
TO medilink_ops
USING (deleted_at IS null);


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
DROP POLICY IF EXISTS sessions_owner ON auth.sessions;

CREATE POLICY sessions_select
ON auth.sessions
FOR SELECT
USING (
    user_id = current_setting('request.jwt.claims.sub', true)::uuid
);

CREATE POLICY sessions_delete
ON auth.sessions
FOR DELETE
USING (
    user_id = current_setting('request.jwt.claims.sub', true)::uuid
);

-- =========================================================
-- 5. SESSION TOKENS POLICIES
-- =========================================================

-- Tokens are accessible ONLY via user's sessions
CREATE POLICY tokens_insert_backend
ON auth.session_tokens
FOR INSERT
TO medilink_ops
WITH CHECK (true);

CREATE POLICY tokens_update_backend
ON auth.session_tokens
FOR UPDATE
TO medilink_ops
USING (true);

CREATE POLICY tokens_delete_backend
ON auth.session_tokens
FOR DELETE
TO medilink_ops
USING (true);
-- =========================================================
-- 6. OPTIONAL: BLOCK ANONYMOUS ACCESS EXPLICITLY
-- =========================================================

-- This prevents accidental anon leakage
REVOKE ALL ON auth.users FROM public;
REVOKE ALL ON auth.sessions FROM public;
REVOKE ALL ON auth.session_tokens FROM public;
-- one physical role for all authenticated users
CREATE ROLE authenticated NOLOGIN;

-- allow PostgREST to switch to it
GRANT authenticated TO medilink_ops;

-- schema access
GRANT USAGE ON SCHEMA auth, appointments, public TO authenticated;

-- table access
GRANT SELECT ON auth.users TO authenticated;
GRANT ALL ON appointments.appointments TO authenticated;

-- sequences
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA appointments TO authenticated;

DROP POLICY IF EXISTS patient_view_own ON appointments.appointments;
CREATE POLICY patient_view_own
ON appointments.appointments
FOR SELECT
TO authenticated
USING (
    (current_setting('request.jwt.claims', true)::json ->> 'p_role') = 'patient'
    AND patient_id = (current_setting('request.jwt.claims', true)::json ->> 'sub')::uuid
    AND deleted_at IS null
);

DROP POLICY IF EXISTS doctor_view_own ON appointments.appointments;
CREATE POLICY doctor_view_own
ON appointments.appointments
FOR SELECT
TO authenticated
USING (
    (current_setting('request.jwt.claims', true)::json ->> 'p_role') = 'doctor'
    AND doctor_id = (current_setting('request.jwt.claims', true)::json ->> 'sub')::uuid
    AND deleted_at IS null
);


-- allow PostgREST to switch to it
GRANT authenticated TO medilink_ops;

-- schema access
GRANT USAGE ON SCHEMA auth, appointments, public TO authenticated;

-- table access
GRANT SELECT ON auth.users TO authenticated;
GRANT ALL ON appointments.appointments TO authenticated;

-- sequences
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA appointments TO authenticated;


COMMIT;
