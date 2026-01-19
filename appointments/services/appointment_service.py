import os
import requests
from typing import Dict, List, Tuple, Optional
from datetime import datetime, timezone, date

import appointments
from authentication.services.jwt_tokens import generate_service_access_token

# =====================================================
# CONSTANTS
# =====================================================

POSTGREST_BASE = os.getenv("POSTGREST_URL", "http://postgrest:3000")

# =====================================================
# HELPERS
# =====================================================

def _parse_timestamp(ts_str: str) -> Optional[datetime]:
    """Parse ISO timestamp from DB"""
    if not ts_str:
        return None
    try:
        return datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return None

def _format_timestamp(dt) -> Optional[str]:
    """Format datetime to ISO-8601 string"""
    if dt is None:
        return None
    if isinstance(dt, str):
        return dt
    if isinstance(dt, date) and not isinstance(dt, datetime):
        # Convert date to datetime at start of day
        dt = datetime.combine(dt, datetime.min.time()).replace(tzinfo=timezone.utc)
    return dt.isoformat()

# =====================================================
# APPOINTMENT SERVICE
# =====================================================

class AppointmentService:
    """
    Service for managing appointments via PostgREST.
    All operations use SERVICE JWT and RPC functions.
    """
    
    def __init__(self):
        self.service_jwt = generate_service_access_token()
    
    def _headers(self, schema: str = "appointments"):
        """Standard headers with service JWT"""
        return {
            "Authorization": f"Bearer {self.service_jwt}",
            "Content-Type": "application/json",
            "Content-Profile": schema,
            "Accept-Profile": schema,
        }
    
    # -------------------------------------------------
    # CREATE APPOINTMENT
    # -------------------------------------------------
    def create_appointment(
        self,
        patient_id: str,
        doctor_id: str,
        scheduled_start: datetime,
        scheduled_end: datetime,
        reason: str,
        notes: Optional[str] = None
    ) -> Tuple[bool, Dict]:
        try:
            # FIX 1: Use the simple RPC name. The 'Content-Profile' header 
            # handles the 'appointments' schema resolution.
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/create_appointment",
                headers=self._headers("appointments"),
                json={
                    "p_patient_id": patient_id,
                    "p_doctor_id": doctor_id,
                    "p_scheduled_start": _format_timestamp(scheduled_start),
                    "p_scheduled_end": _format_timestamp(scheduled_end),
                    "p_reason": reason,
                    "p_notes": notes,
                },
                timeout=10,
            )
            
            if resp.status_code != 200:
                return False, {"error": resp.json().get("message", "Creation failed")}

            appointment_id = resp.json()

            # FIX 2: Explicitly fetch the newly created object.
            # We must ensure get_appointment uses the SAME schema context.
            return self.get_appointment(appointment_id)

        except Exception as e:
            return False, {"error": str(e)}

    # -------------------------------------------------
    # GET APPOINTMENT
    # -------------------------------------------------
    def get_appointment(self, appointment_id: str) -> Tuple[bool, Dict]:
        try:
            # FIX 3: REMOVE "appointments." prefix from the URL.
            # PostgREST resolves the table via the Accept-Profile header.
            # Using "/appointments.appointments" with Accept-Profile: appointments
            # causes PostgREST to look for schema "appointments" -> table "appointments.appointments" (Fail)
            resp = requests.get(
                f"{POSTGREST_BASE}/appointments", 
                headers=self._headers("appointments"),
                params={
                    "id": f"eq.{appointment_id}",
                    "deleted_at": "is.null",
                },
                timeout=5,
            )

            # PostgREST returns a list []. Check if list is empty.
            data = resp.json()
            if not data or len(data) == 0:
                return False, {"error": "Appointment not found or RLS blocked access"}

            return True, {"appointment": data[0]}

        except Exception as e:
            return False, {"error": f"Fetch failed: {str(e)}"}
    # -------------------------------------------------
    # LIST APPOINTMENTS
    # -------------------------------------------------
    
    def list_appointments_for_user(
        self,
        user_id: str,
        user_role: str,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        status: Optional[str] = None,
        limit: int = 100
    ) -> Tuple[bool, Dict]:
        """
        List appointments for a user (patient or doctor).
        
        Args:
            user_id: UUID of user
            user_role: 'patient' or 'doctor'
            start_date: Filter by start date (optional)
            end_date: Filter by end date (optional)
            status: Filter by status (optional)
            limit: Maximum results (default 100)
            
        Returns:
            (success: bool, result: dict)
        """
        # Use RPC for date range queries (more efficient)
        if start_date and end_date:
            try:
                resp = requests.post(
                    f"{POSTGREST_BASE}/rpc/get_appointments_by_date_range",
                    headers=self._headers(),
                    json={
                        "p_user_id": user_id,
                        "p_user_role": user_role,
                        "p_start_date": _format_timestamp(start_date),
                        "p_end_date": _format_timestamp(end_date),
                    },
                    timeout=10,
                )
            except requests.RequestException:
                return False, {"error": "Service unavailable"}
            
            if resp.status_code != 200:
                return False, {"error": "Failed to fetch appointments"}
            
            appointments = resp.json()
            
            # Filter by status if provided
            if status:
                appointments = [a for a in appointments if a["status"] == status]
            
            return True, {
                "appointments": appointments,
                "count": len(appointments)
            }
        
        # Direct query without date range
        params = {
            "deleted_at": "is.null",
            "order": "scheduled_start.desc",
            "limit": str(limit),
        }
        
        if user_role == "patient":
            params["patient_id"] = f"eq.{user_id}"
        elif user_role == "doctor":
            params["doctor_id"] = f"eq.{user_id}"
        else:
            return False, {"error": "Invalid user role"}
        
        if status:
            params["status"] = f"eq.{status}"
        
        try:
            resp = requests.get(
                f"{POSTGREST_BASE}/appointments.appointments",
                headers=self._headers(),
                params=params,
                timeout=10,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}
        
        if resp.status_code != 200:
            return False, {"error": "Failed to fetch appointments"}
        appointments = resp.json()
    
        return True, {
            "appointments": appointments,
            "count": len(appointments)
        }

# -------------------------------------------------
# GET UPCOMING APPOINTMENTS
# -------------------------------------------------

    def get_upcoming_appointments(
        self,
        user_id: str,
        user_role: str,
        days_ahead: int = 7
    ) -> Tuple[bool, Dict]:
        """
        Get upcoming appointments for next N days.

        Args:
            user_id: UUID of user
            user_role: 'patient' or 'doctor'
            days_ahead: Number of days to look ahead (default 7)

        Returns:
            (success: bool, result: dict)
        """
        try:
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/get_upcoming_appointments",
                headers=self._headers(),
                json={
                    "p_user_id": user_id,
                    "p_user_role": user_role,
                    "p_days_ahead": days_ahead,
                },
                timeout=10,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}

        if resp.status_code != 200:
            return False, {"error": "Failed to fetch upcoming appointments"}

        appointments = resp.json()

        return True, {
            "appointments": appointments,
            "count": len(appointments)
        }

    # -------------------------------------------------
    # CANCEL APPOINTMENT
    # -------------------------------------------------

    def cancel_appointment(
        self,
        appointment_id: str,
        cancelled_by: str,
        cancellation_reason: str,
        cancellation_notes: Optional[str] = None
    ) -> Tuple[bool, Dict]:
        """
        Cancel an appointment.

        Args:
            appointment_id: UUID of appointment
            cancelled_by: UUID of user cancelling
            cancellation_reason: One of: patient_request, doctor_unavailable, 
                                rescheduled, emergency, other
            cancellation_notes: Optional notes

        Returns:
            (success: bool, result: dict)
        """
        valid_reasons = [
            'patient_request',
            'doctor_unavailable',
            'rescheduled',
            'emergency',
            'other'
        ]

        if cancellation_reason not in valid_reasons:
            return False, {
                "error": f"Invalid cancellation reason. Must be one of: {', '.join(valid_reasons)}"
            }

        try:
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/cancel_appointment",
                headers=self._headers(),
                json={
                    "p_appointment_id": appointment_id,
                    "p_cancelled_by": cancelled_by,
                    "p_cancellation_reason": cancellation_reason,
                    "p_cancellation_notes": cancellation_notes,
                },
                timeout=10,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}

        if resp.status_code != 200:
            try:
                error_data = resp.json()
                error_msg = error_data.get("message", "Cancellation failed")
                if "EXCEPTION" in error_msg:
                    error_msg = error_msg.split("EXCEPTION:")[-1].strip()
            except:
                error_msg = "Cancellation failed"

            return False, {"error": error_msg}

        # Fetch updated appointment
        return self.get_appointment(appointment_id)

    # -------------------------------------------------
    # UPDATE STATUS
    # -------------------------------------------------

    def update_status(
        self,
        appointment_id: str,
        status: str,
        user_id: str
    ) -> Tuple[bool, Dict]:
        """
        Update appointment status.

        Args:
            appointment_id: UUID of appointment
            status: One of: scheduled, confirmed, in_progress, completed, no_show
                   (cancelled must use cancel_appointment method)
            user_id: UUID of user updating status

        Returns:
            (success: bool, result: dict)
        """
        valid_statuses = [
            'scheduled',
            'confirmed',
            'in_progress',
            'completed',
            'no_show'
        ]

        if status not in valid_statuses:
            return False, {
                "error": f"Invalid status. Must be one of: {', '.join(valid_statuses)}"
            }

        try:
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/update_appointment_status",
                headers=self._headers(),
                json={
                    "p_appointment_id": appointment_id,
                    "p_status": status,
                    "p_user_id": user_id,
                },
                timeout=10,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}

        if resp.status_code != 200:
            try:
                error_data = resp.json()
                error_msg = error_data.get("message", "Status update failed")
                if "EXCEPTION" in error_msg:
                    error_msg = error_msg.split("EXCEPTION:")[-1].strip()
            except:
                error_msg = "Status update failed"

            return False, {"error": error_msg}

        # Fetch updated appointment
        return self.get_appointment(appointment_id)

    # -------------------------------------------------
    # CHECK AVAILABILITY
    # -------------------------------------------------

    def check_doctor_availability(
        self,
        doctor_id: str,
        scheduled_start: datetime,
        scheduled_end: datetime,
        exclude_appointment_id: Optional[str] = None
    ) -> Tuple[bool, Dict]:
        """
        Check if doctor is available for a time slot.

        Args:
            doctor_id: UUID of doctor
            scheduled_start: Start time
            scheduled_end: End time
            exclude_appointment_id: Appointment ID to exclude (for reschedule)

        Returns:
            (success: bool, result: dict)
            result contains: {"is_available": True/False}
        """
        try:
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/is_doctor_available",
                headers=self._headers(),
                json={
                    "p_doctor_id": doctor_id,
                    "p_start": _format_timestamp(scheduled_start),
                    "p_end": _format_timestamp(scheduled_end),
                    "p_exclude_appointment_id": exclude_appointment_id,
                },
                timeout=5,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}

        if resp.status_code != 200:
            return False, {"error": "Availability check failed"}

        is_available = resp.json()

        return True, {"is_available": is_available}

    # -------------------------------------------------
    # GET AVAILABILITY SLOTS
    # -------------------------------------------------

    def get_doctor_availability_slots(
        self,
        doctor_id: str,
        date_str: str,  # YYYY-MM-DD format
        slot_duration_minutes: int = 30
    ) -> Tuple[bool, Dict]:
        """
        Get available time slots for a doctor on a specific date.

        Args:
            doctor_id: UUID of doctor
            date_str: Date in YYYY-MM-DD format
            slot_duration_minutes: Duration of each slot (default 30)

        Returns:
            (success: bool, result: dict)
            result contains:
                - date: requested date
                - available_slots: list of available slots
                - unavailable_slots: list of booked slots
                - total_slots: total number of slots
                - available_count: number of available slots
        """
        try:
            resp = requests.post(
                f"{POSTGREST_BASE}/rpc/get_doctor_availability",
                headers=self._headers(),
                json={
                    "p_doctor_id": doctor_id,
                    "p_date": date_str,
                    "p_slot_duration_minutes": slot_duration_minutes,
                },
                timeout=10,
            )
        except requests.RequestException:
            return False, {"error": "Service unavailable"}

        if resp.status_code != 200:
            try:
                error_data = resp.json()
                error_msg = error_data.get("message", "Failed to fetch availability")
                if "EXCEPTION" in error_msg:
                    error_msg = error_msg.split("EXCEPTION:")[-1].strip()
            except:
                error_msg = "Failed to fetch availability"

            return False, {"error": error_msg}

        slots = resp.json()

        # Separate available and unavailable slots
        available_slots = [s for s in slots if s["is_available"]]
        unavailable_slots = [s for s in slots if not s["is_available"]]

        return True, {
            "date": date_str,
            "available_slots": available_slots,
            "unavailable_slots": unavailable_slots,
            "total_slots": len(slots),
            "available_count": len(available_slots),
        }