BEGIN;

-- DBA role
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'medilink_dba') THEN
        CREATE ROLE medilink_dba
            password '${DBA_PASSWORD}'
            LOGIN
            CREATEDB
            CREATEROLE
            INHERIT;
    END IF;
END
$$;

-- PostgREST runtime role (NO LOGIN)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'medilink_ops') THEN
        CREATE ROLE medilink_ops
            NOLOGIN
            NOCREATEDB
            NOCREATEROLE
            INHERIT
            NOREPLICATION;
    END IF;
END
$$;

-- PostgREST connection role
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator
            LOGIN
            PASSWORD '${POSTGRES_PASSWORD}'
            NOINHERIT;
    END IF;
END
$$;

COMMIT;
