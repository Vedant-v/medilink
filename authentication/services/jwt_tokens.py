import time
from typing import Dict
import jwt

# =========================
# Global configuration
# =========================

# MUST be the same secret used in PostgREST config
JWT_SECRET = "568793549c2aa2c2bc59c5b457665b0198156004f2311f1625d111beada6ee5012af37b5376268b362951f346ff00ce93fdb50319e5574c830ff132b8ff3faf6"

JWT_ALGORITHM = "HS256"
JWT_AUDIENCE = "medilink"

USER_JWT_TTL_SECONDS = 15 * 60      # 15 minutes
SERVICE_JWT_TTL_SECONDS = 5 * 60    # 5 minutes


# =========================
# Internal helper
# =========================

def _encode_jwt(payload: Dict, ttl_seconds: int) -> str:
    now = int(time.time())

    payload.update({
        "aud": JWT_AUDIENCE,
        "iat": now,
        "exp": now + ttl_seconds,
    })

    return jwt.encode(
        payload,
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )


# =========================
# User JWT (client-facing)
# =========================

def generate_user_access_token(user_id: str, role: str) -> str:
    if not user_id:
        raise ValueError("user_id is required")

    if not role:
        raise ValueError("role is required")

    payload = {
        "sub": user_id,          # user identity
        "role": role,            # used by RLS
        "iss": "medilink-auth",
    }

    return _encode_jwt(payload, USER_JWT_TTL_SECONDS)


# =========================
# Service JWT (backend-only)
# =========================

def generate_service_access_token() -> str:
    """
    Backend → PostgREST token.
    Never exposed to clients.
    """

    payload = {
        "role": "medilink_ops",
        "iss": "medilink-backend",
    }

    return _encode_jwt(payload, SERVICE_JWT_TTL_SECONDS)
