BEGIN;

CREATE TABLE IF NOT EXISTS auth.user_roles (
    user_id UUID NOT NULL
    REFERENCES auth.users (id) ON DELETE CASCADE,

    role_id UUID NOT NULL
    REFERENCES auth.roles (id) ON DELETE CASCADE,

    assigned_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (user_id, role_id)
);

COMMIT;
