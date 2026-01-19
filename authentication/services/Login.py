import os
import base64
import hashlib
import secrets
import requests
from typing import Dict, Tuple
from datetime import datetime, timedelta, timezone

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from authentication.services.jwt_tokens import (
    generate_service_access_token,
    generate_user_access_token,
)

# =====================================================
# CONSTANTS
# =====================================================

ACCESS_TOKEN_TTL_SECONDS = 15 * 60       # 15 minutes
REFRESH_TOKEN_TTL_DAYS = 14              # 14 days

PH = PasswordHasher()

# =====================================================
# HELPERS
# =====================================================

def _now_utc() -> str:
    """Return current UTC timestamp as ISO-8601 string"""
    return datetime.now(timezone.utc).isoformat()

def _expiry_after_days(days: int) -> str:
    """Return future timestamp as ISO-8601 string"""
    return (
        datetime.now(timezone.utc) + timedelta(days=days)
    ).isoformat()

def _generate_refresh_token() -> Tuple[str, str]:
    """
    Generate a cryptographically secure refresh token.
    
    Returns:
        raw_refresh_token (str): Base64-encoded token for client
        token_hash (str): Hex-encoded SHA256 hash for database storage
    """
    raw = secrets.token_bytes(32)
    token = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    token_hash = hashlib.sha256(token.encode()).hexdigest()  # ← .hexdigest() for string
    return token, token_hash


# =====================================================
# LOGIN SERVICE
# =====================================================

class LoginService:
    POSTGREST_BASE = os.getenv("POSTGREST_URL", "http://postgrest:3000")
    LOGIN_RPC = f"{POSTGREST_BASE}/rpc/get_user_for_login"

    def __init__(self, data: Dict, user_agent: str = "", ip_address: str = ""):
        self.password = data.get("password")
        self.identifier = (
            data.get("username")
            or data.get("email")
            or data.get("phone_number")
        )

        self.user_agent = user_agent or "Unknown"
        self.ip_address = ip_address or "127.0.0.1"
        # Generate service JWT for all PostgREST operations
        self.service_jwt = generate_service_access_token()

    def _headers(self):
        """Standard headers for PostgREST requests with service JWT"""
        return {
            "Authorization": f"Bearer {self.service_jwt}",
            "Content-Type": "application/json",
        }

    # -------------------------------------------------
    # AUTHENTICATE
    # -------------------------------------------------

    def authenticate(self) -> Tuple[bool, Dict]:
        """
        Authenticate user and issue access + refresh tokens.
        
        Returns:
            (success: bool, result: Dict)
            
        On success, result contains:
            - access_token (JWT)
            - refresh_token (opaque)
            - expires_in (seconds)
            - user_id
            - role
            
        On failure, result contains:
            - error (message)
        """
        
        # =================================================
        # 1. VALIDATE INPUT
        # =================================================
        if not self.identifier or not self.password:
            return False, {"error": "Invalid credentials"}

        # =================================================
        # 2. FETCH USER VIA RPC (SERVICE JWT)
        # =================================================
        try:
            resp = requests.post(
                self.LOGIN_RPC,
                headers=self._headers(),
                json={"p_identifier": self.identifier},
                timeout=5,
            )
        except requests.RequestException as e:
            return False, {"error": "Authentication service unavailable"}

        if resp.status_code != 200 or not resp.json():
            return False, {"error": "Invalid credentials"}

        user = resp.json()[0]

        # =================================================
        # 3. VERIFY PASSWORD
        # =================================================
        try:
            PH.verify(user["password_hash"], self.password)
        except VerifyMismatchError:
            return False, {"error": "Invalid credentials"}
        except Exception as e:
            return False, {"error": "Authentication failed"}

        # Optional: Rehash if needed (Argon2 parameter updates)
        if PH.check_needs_rehash(user["password_hash"]):
            # Note: You'd need to update the password_hash in DB here
            # For now, we'll skip this to keep the flow simple
            pass

        # =================================================
        # 4. CREATE SESSION (sessions)
        # =================================================
        session_expires_at = _expiry_after_days(REFRESH_TOKEN_TTL_DAYS)
        now = _now_utc()

        try:
            session_resp = requests.post(
                f"{self.POSTGREST_BASE}/sessions",  # ← SCHEMA-QUALIFIED
                headers={
                    **self._headers(),
                    "Prefer": "return=representation",
                },
                json={
                    "user_id": user["id"],
                    "created_at": now,
                    "last_used_at": now,
                    "expires_at": session_expires_at,
                    "user_agent": self.user_agent[:255],  # Prevent overflow
                    "ip_address": self.ip_address[:45],   # IPv6 max length
                },
                timeout=5,
            )
        except requests.RequestException:
            return False, {"error": "Session creation failed"}

        if session_resp.status_code != 201:
            return False, {
                "error": "Session creation failed",
                "details": session_resp.text,
            }

        session = session_resp.json()[0]

        # =================================================
        # 5. CREATE REFRESH TOKEN (session_tokens)
        # =================================================
        refresh_token, refresh_hash = _generate_refresh_token()
        refresh_expires_at = _expiry_after_days(REFRESH_TOKEN_TTL_DAYS)

        try:
            token_resp = requests.post(
                f"{self.POSTGREST_BASE}/session_tokens",  # ← SCHEMA-QUALIFIED
                headers=self._headers(),
                json={
                    "session_id": session["id"],
                    "token_hash": refresh_hash,  # ← Already hex string from helper
                    "created_at": now,
                    "expires_at": refresh_expires_at,
                },
                timeout=5,
            )
        except requests.RequestException:
            # Critical: Session exists but token failed
            # Consider revoking session here
            return False, {"error": "Token creation failed"}

        if token_resp.status_code != 201:
            # Critical: Session exists but token failed
            return False, {
                "error": "Token creation failed",
                "details": token_resp.text,
            }

        # =================================================
        # 6. ISSUE ACCESS TOKEN (JWT)
        # =================================================
        try:
            access_token = generate_user_access_token(
                user_id=user["id"],
                p_role=user["p_role"],
                session_id=session["id"],
                role="authenticated",
            )
        except Exception as e:
            return False, {"error": "Access token generation failed"}

        # =================================================
        # 7. RETURN RESPONSE
        # =================================================
        return True, {
            "access_token": access_token,
            "refresh_token": refresh_token,
            "expires_in": ACCESS_TOKEN_TTL_SECONDS,
            "user_id": user["id"],
            "role": user["p_role"],
        }