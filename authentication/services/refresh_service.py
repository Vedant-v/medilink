import base64
import hashlib
import secrets
import requests
import os
from typing import Dict, Tuple
from datetime import datetime, timezone, timedelta

from authentication.services.jwt_tokens import (
    generate_service_access_token,
    generate_user_access_token,
)

# =====================================================
# CONSTANTS
# =====================================================

ACCESS_TOKEN_TTL_SECONDS = 15 * 60
REFRESH_TOKEN_TTL_DAYS = 14

# =====================================================
# HELPERS
# =====================================================

def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()

def _expiry_after_days(days: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=days)).isoformat()

def _hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()

def _generate_refresh_token() -> Tuple[str, bytes]:
    raw = secrets.token_bytes(32)
    token = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    token_hash = hashlib.sha256(token.encode()).digest()
    return token, token_hash

def _parse_timestamp(ts_str: str) -> datetime:
    """Parse ISO timestamp from DB (handles both Z and +00:00)"""
    return datetime.fromisoformat(ts_str.replace('Z', '+00:00'))

# =====================================================
# REFRESH SERVICE
# =====================================================

class RefreshService:
    POSTGREST_BASE = os.getenv("POSTGREST_URL", "http://postgrest:3000")

    def __init__(self, refresh_token: str):
        self.refresh_token = refresh_token
        self.service_jwt = generate_service_access_token()

    def _headers(self):
        return {
            "Authorization": f"Bearer {self.service_jwt}",
            "Content-Type": "application/json",
        }

    def refresh(self) -> Tuple[bool, Dict]:
        token_hash = _hash_token(self.refresh_token)
        
        # =================================================
        # 1. LOOKUP TOKEN (SERVICE JWT REQUIRED)
        # =================================================
        resp = requests.get(
            f"{self.POSTGREST_BASE}/session_tokens",
            headers=self._headers(),
            params={"token_hash": f"eq.{token_hash.hex()}"},
            timeout=5,
        )

        if resp.status_code != 200 or not resp.json():
            return False, {"error": "Invalid refresh token"}

        token_row = resp.json()[0]

        # =================================================
        # 2. CHECK TOKEN STATUS
        # =================================================
        
        # Check if already used or revoked
        if token_row.get("used_at") or token_row.get("revoked_at"):
            # REPLAY DETECTED → revoke entire session
            requests.patch(
                f"{self.POSTGREST_BASE}/sessions",
                headers=self._headers(),
                params={"id": f"eq.{token_row['session_id']}"},
                json={"revoked_at": _now_utc()},
                timeout=5,
            )
            return False, {"error": "Session revoked due to token reuse"}

        # Check if expired
        if token_row.get("expires_at"):
            expires_at = _parse_timestamp(token_row["expires_at"])
            if expires_at < datetime.now(timezone.utc):
                return False, {"error": "Refresh token expired"}

        # =================================================
        # 3. VALIDATE SESSION
        # =================================================
        session_resp = requests.get(
            f"{self.POSTGREST_BASE}/sessions",
            headers=self._headers(),
            params={"id": f"eq.{token_row['session_id']}"},
            timeout=5,
        )

        if session_resp.status_code != 200 or not session_resp.json():
            return False, {"error": "Session not found"}

        session = session_resp.json()[0]

        # Check if session revoked
        if session.get("revoked_at"):
            return False, {"error": "Session revoked"}

        # Check if session expired
        if session.get("expires_at"):
            expires_at = _parse_timestamp(session["expires_at"])
            if expires_at < datetime.now(timezone.utc):
                return False, {"error": "Session expired"}

        # =================================================
        # 4. FETCH USER DATA (for JWT claims)
        # =================================================
        user_resp = requests.get(
            f"{self.POSTGREST_BASE}/users",
            headers=self._headers(),
            params={"id": f"eq.{session['user_id']}"},
            timeout=5,
        )

        if user_resp.status_code != 200 or not user_resp.json():
            return False, {"error": "User not found"}

        user = user_resp.json()[0]

        # =================================================
        # 5. MARK OLD TOKEN AS USED
        # =================================================
        mark_used_resp = requests.patch(
            f"{self.POSTGREST_BASE}/session_tokens",
            headers=self._headers(),
            params={"id": f"eq.{token_row['id']}"},
            json={"used_at": _now_utc()},
            timeout=5,
        )

        if mark_used_resp.status_code != 204:
            return False, {"error": "Token rotation failed"}

        # =================================================
        # 6. CREATE NEW REFRESH TOKEN
        # =================================================
        new_refresh, new_hash = _generate_refresh_token()
        new_expires_at = _expiry_after_days(REFRESH_TOKEN_TTL_DAYS)

        new_token_resp = requests.post(
            f"{self.POSTGREST_BASE}/session_tokens",
            headers=self._headers(),
            json={
                "session_id": token_row["session_id"],
                "token_hash": new_hash.hex(),
                "expires_at": new_expires_at,
            },
            timeout=5,
        )

        if new_token_resp.status_code != 201:
            # CRITICAL: old token marked used, new token failed
            # User may be locked out - consider logging/alerting
            return False, {"error": "Token rotation failed"}

        # =================================================
        # 7. UPDATE SESSION LAST_USED_AT
        # =================================================
        requests.patch(
            f"{self.POSTGREST_BASE}/sessions",
            headers=self._headers(),
            params={"id": f"eq.{session['id']}"},
            json={"last_used_at": _now_utc()},
            timeout=5,
        )

        # =================================================
        # 8. ISSUE NEW ACCESS TOKEN (JWT)
        # =================================================
        access_token = generate_user_access_token(
            user_id=user["id"],
            role=user["p_role"],
            session_id=session["id"],
        )

        # =================================================
        # 9. RETURN TOKENS
        # =================================================
        return True, {
            "access_token": access_token,
            "refresh_token": new_refresh,
            "expires_in": ACCESS_TOKEN_TTL_SECONDS,
        }