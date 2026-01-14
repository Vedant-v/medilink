from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
import requests
from typing import Optional, Dict, Tuple

from authentication.services.jwt_tokens import (
    generate_service_access_token,
    generate_user_access_token,
)


class LoginService:
    POSTGREST_URL = "http://postgrest:3000/rpc/get_user_for_login"
    POSTGREST_TIMEOUT = 5  # seconds

    def __init__(self, data: Dict):
        self.password: Optional[str] = data.get("password")
        self.username: Optional[str] = data.get("username")
        self.email: Optional[str] = data.get("email")
        self.phone_number: Optional[str] = data.get("phone_number")

        self.errors: Dict[str, str] = {}
        self.ph = PasswordHasher()
        self.service_jwt = generate_service_access_token()

    # -----------------------------
    # Identifier resolution
    # -----------------------------
    def _resolve_identifier(self) -> Optional[str]:
        return self.username or self.email or self.phone_number

    # -----------------------------
    # Validation
    # -----------------------------
    def validate(self) -> bool:
        identifier = self._resolve_identifier()

        if not identifier:
            self.errors["identifier"] = (
                "username, email, or phone_number is required"
            )

        if not self.password:
            self.errors["password"] = "password is required"

        return not self.errors

    # -----------------------------
    # Fetch user from PostgREST
    # -----------------------------
    def fetch_user(self, identifier: str) -> Optional[Dict]:
        try:
            resp = requests.post(
                self.POSTGREST_URL,
                headers={
                    "Authorization": f"Bearer {self.service_jwt}",
                    "Content-Type": "application/json",
                },
                json={"p_identifier": identifier},
                timeout=self.POSTGREST_TIMEOUT,
            )
        except requests.RequestException:
            return None

        if resp.status_code != 200:
            return None

        data = resp.json()
        return data[0] if data else None

    # -----------------------------
    # Password verification
    # -----------------------------
    def verify_password(self, hashed_password: str) -> bool:
        if not self.password:
            return False
        try:
            self.ph.verify(hashed_password, self.password)
            return True
        except VerifyMismatchError:
            return False

    # -----------------------------
    # Authenticate
    # -----------------------------
    def authenticate(self) -> Tuple[bool, Dict]:
        if not self.validate():
            return False, self.errors

        identifier = self._resolve_identifier()
        if not identifier:
            return False, {"error": "Invalid identifier"}

        user = self.fetch_user(identifier)

        # Uniform failure path
        if not user or not self.verify_password(user["password_hash"]):
            return False, {"error": "Invalid credentials"}

        token = generate_user_access_token(
            user_id=user["id"],
            role=user["p_role"],
        )

        return True, {
            "user_id": user["id"],
            "role": user["p_role"],
            "token": token,
        }
