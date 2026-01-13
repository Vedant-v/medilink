import re
import os
import json
import requests
from argon2 import PasswordHasher
from django.http import JsonResponse

from authentication.services.jwt_tokens import (
    generate_service_access_token,
    generate_user_access_token,
)

# Argon2 should be a singleton
PH = PasswordHasher()

# Explicit role whitelist (CRITICAL)
ALLOWED_P_ROLES = {
    'patient',
    'doctor',
    'nurse',
    'receptionist',
    'lab_technician',
    'pharmacist',
    'radiologist',
    'therapist',
    'surgeon',
    'anesthesiologist',
    'paramedic',
    'dietitian',
    'medical_assistant',
    'healthcare_admin',
}


class Registretion:
    def __init__(self, data):
        self.data = data
        self.errors = {}

        self.username = data.get("username")
        self.email = data.get("email")
        self.password = data.get("password")

        self.first_name = data.get("first_name")
        self.middle_name = data.get("middle_name")
        self.last_name = data.get("last_name")

        self.phone_number = data.get("phone_number")
        self.primary_role = data.get("primary_role")  # maps to p_role

        self.postgrest_url = os.getenv("POSTGREST_URL", "http://postgrest:3000")
        self.service_jwt = generate_service_access_token()
        print("SERVICE JWT:", self.service_jwt, flush=True)

    # --------------------
    # Validation helpers
    # --------------------

    def is_valid_email(self):
        return bool(re.match(
            r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$",
            self.email or "",
        ))

    def password_strength(self):
        pw = self.password or ""

        if len(pw) < 8:
            return False
        if not re.search(r"[A-Z]", pw):
            return False
        if not re.search(r"[a-z]", pw):
            return False
        if not re.search(r"\d", pw):
            return False
        if not re.search(r"[^\w\s]", pw):
            return False

        blacklist = [
            self.username,
            self.first_name,
            self.middle_name,
            self.last_name,
            self.email.split("@")[0] if self.email else None,
            self.phone_number,
        ]

        return not any(
            item and item.lower() in pw.lower()
            for item in blacklist
        )

    # --------------------
    # Validation
    # --------------------

    def validate(self):
        if not self.username or len(self.username) < 4:
            self.errors["username"] = "Username must be at least 4 characters long."

        if not self.email or not self.is_valid_email():
            self.errors["email"] = "Invalid email format."

        if not self.password or not self.password_strength():
            self.errors["password"] = "Password is not strong enough."

        if not self.first_name or len(self.first_name) < 2:
            self.errors["first_name"] = "First name too short."

        if self.middle_name and len(self.middle_name) < 2:
            self.errors["middle_name"] = "Middle name too short."

        if not self.last_name or len(self.last_name) < 2:
            self.errors["last_name"] = "Last name too short."

        if self.phone_number and not re.match(r"^\+?[1-9]\d{1,14}$", self.phone_number):
            self.errors["phone_number"] = "Invalid phone number format."

        if not self.primary_role or self.primary_role not in ALLOWED_P_ROLES:
            self.errors["p_role"] = "Invalid or unauthorized role."

        return not self.errors

    # --------------------
    # DB insert
    # --------------------

    def pushing_to_db(self):
        if not self.validate():
            return {"ok": False, "errors": self.errors}

        password_hash = PH.hash(self.password)

        user_record = {
            "password_hash": password_hash,
            "username": self.username,
            "first_name": self.first_name,
            "middle_name": self.middle_name or "",
            "last_name": self.last_name,
            "email": self.email,
            "p_role": self.primary_role,
        }

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.service_jwt}",
            "Prefer": "return=representation",
        }

        response = requests.post(
            f"{self.postgrest_url}/users",
            headers=headers,
            json=user_record,
            timeout=5,
        )

        if response.status_code != 201:
            return {
                "ok": False,
                "status": response.status_code,
                "error": response.text,
            }

        return {"ok": True, "user": response.json()[0]}

    # --------------------
    # Public API
    # --------------------

    def register(self):
        result = self.pushing_to_db()

        if not result["ok"]:
            return JsonResponse(
                {
                    "error": "Registration failed",
                    "details": result.get("errors") or result.get("error"),
                },
                status=400,
            )

        user = result["user"]

        user_token = generate_user_access_token(
            user_id=user["id"],
            role=user["p_role"],
        )

        return JsonResponse(
            {
                "message": "Registration successful",
                "user_id": user["id"],
                "username": user["username"],
                "email": user["email"],
                "token": user_token,
            },
            status=201,
        )
