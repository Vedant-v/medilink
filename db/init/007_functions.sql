BEGIN;

CREATE OR REPLACE FUNCTION auth.get_user_for_login(p_identifier TEXT)
RETURNS TABLE (
    id UUID,
    password_hash TEXT,
    p_role TEXT
)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT
        u.id,
        u.password_hash,
        u.p_role
    FROM auth.users u
    WHERE u.deleted_at IS NULL
      AND (
        u.username = p_identifier
        OR u.email = p_identifier
        OR u.phone_number = p_identifier
      )
    LIMIT 1;
$$;

COMMIT;
