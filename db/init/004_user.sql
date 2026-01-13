BEGIN;

CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    password_hash text NOT NULL,
    username text NOT NULL UNIQUE,
    CHECK (username ~ '^[a-zA-Z][a-zA-Z0-9_]{2,29}$'),
    first_name text NOT NULL,
    middle_name text,
    last_name text NOT NULL,
    email text NOT NULL UNIQUE,
    CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    p_role auth.primary_role NOT NULL DEFAULT 'patient',
    is_active boolean DEFAULT TRUE,
    is_verified boolean DEFAULT FALSE,
    deleted boolean DEFAULT FALSE,
    deleted_at timestamptz DEFAULT NULL,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

COMMIT;
