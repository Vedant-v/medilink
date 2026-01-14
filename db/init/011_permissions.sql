BEGIN;

-- Schema visibility
GRANT USAGE ON SCHEMA auth TO medilink_ops;

-- Table access
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA auth
TO medilink_ops;

-- Future tables auto-granted
ALTER DEFAULT PRIVILEGES IN SCHEMA auth
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO medilink_ops;

GRANT medilink_ops TO authenticator;
GRANT EXECUTE ON FUNCTION auth.debug_role() TO medilink_ops;
GRANT EXECUTE ON FUNCTION auth.get_user_for_login(text) TO medilink_ops;


COMMIT;
