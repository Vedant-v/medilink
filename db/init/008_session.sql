BEGIN;

CREATE TABLE auth.sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID NOT NULL
    REFERENCES auth.users (id),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    expires_at TIMESTAMPTZ NOT NULL
    CHECK (expires_at > created_at),

    revoked_at TIMESTAMPTZ,

    user_agent TEXT,
    ip_address INET
);

COMMIT;
