BEGIN;

CREATE TABLE auth.session_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    session_id UUID NOT NULL
    REFERENCES auth.sessions (id),

    token_hash BYTEA NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    used_at TIMESTAMPTZ,

    revoked_at TIMESTAMPTZ,

    expires_at TIMESTAMPTZ NOT NULL
    CHECK (expires_at > created_at),

    CONSTRAINT uniq_token_hash UNIQUE (token_hash)
);


COMMIT;
