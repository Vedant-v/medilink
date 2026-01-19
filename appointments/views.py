from django.http import JsonResponse
from django.views.decorators.http import require_http_methods
from django.views.decorators.csrf import csrf_exempt
from datetime import datetime, timezone
import json

from authentication.decorators import jwt_required
from appointments.services.appointment_service import AppointmentService

# =====================================================
# HELPERS
# =====================================================

def _parse_datetime(dt_str: str):
    """Parse ISO datetime string"""
    if not dt_str:
        return None
    try:
        return datetime.fromisoformat(dt_str.replace('Z', '+00:00'))
    except (ValueError, AttributeError):
        return None

# =====================================================
# APPOINTMENT VIEWS
# =====================================================

@csrf_exempt
@require_http_methods(["POST"])
@jwt_required
def create_appointment(request):
    """
    Create a new appointment.
    
    POST /api/appointments/
    
    Request Body:
    {
        "doctor_id": "uuid",
        "scheduled_start": "2026-01-20T10:00:00Z",
        "scheduled_end": "2026-01-20T10:30:00Z",
        "reason": "Annual checkup",
        "notes": "Patient has back pain"  // optional
    }
    
    Response:
    {
        "appointment": {
            "id": "uuid",
            "patient_id": "uuid",
            "doctor_id": "uuid",
            "scheduled_start": "2026-01-20T10:00:00Z",
            "scheduled_end": "2026-01-20T10:30:00Z",
            "status": "scheduled",
            "reason": "Annual checkup",
            "notes": "Patient has back pain",
            "created_at": "2026-01-19T15:30:00Z",
            ...
        }
    }
    """
    
    try:
        data = json.loads(request.body)
    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON"}, status=400)
    
    # Validate required fields
    required_fields = ["doctor_id", "scheduled_start", "scheduled_end", "reason"]
    missing = [f for f in required_fields if not data.get(f)]
    if missing:
        return JsonResponse(
            {"error": f"Missing required fields: {', '.join(missing)}"},
            status=400
        )
    
    # Parse datetimes
    scheduled_start = _parse_datetime(data["scheduled_start"])
    scheduled_end = _parse_datetime(data["scheduled_end"])
    
    if not scheduled_start or not scheduled_end:
        return JsonResponse(
            {"error": "Invalid datetime format. Use ISO-8601 (e.g., 2026-01-20T10:00:00Z)"},
            status=400
        )
    
    # Create appointment
    service = AppointmentService()
    success, result = service.create_appointment(
        patient_id=request.user_id,
        doctor_id=data["doctor_id"],
        scheduled_start=scheduled_start,
        scheduled_end=scheduled_end,
        reason=data["reason"],
        notes=data.get("notes"),
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=201)


@csrf_exempt
@require_http_methods(["GET"])
@jwt_required
def list_appointments(request):
    """
    List appointments for the authenticated user.
    
    GET /api/appointments/?start_date=2026-01-20T00:00:00Z&end_date=2026-01-27T23:59:59Z&status=scheduled
    
    Query Parameters:
    - start_date: ISO datetime (optional)
    - end_date: ISO datetime (optional)
    - status: appointment status (optional)
    - limit: max results (optional, default 100)
    
    Response:
    {
        "appointments": [...],
        "count": 10
    }
    """
    # Parse query params
    start_date_str = request.GET.get("start_date")
    end_date_str = request.GET.get("end_date")
    status = request.GET.get("status")
    limit = int(request.GET.get("limit", 100))
    
    start_date = _parse_datetime(start_date_str) if start_date_str else None
    end_date = _parse_datetime(end_date_str) if end_date_str else None
    
    service = AppointmentService()
    success, result = service.list_appointments_for_user(
        user_id=request.user_id,
        user_role=request.user_role,
        start_date=start_date,
        end_date=end_date,
        status=status,
        limit=limit,
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["GET"])
@jwt_required
def get_upcoming_appointments(request):
    """
    Get upcoming appointments for the next N days.
    
    GET /api/appointments/upcoming/?days=7
    
    Query Parameters:
    - days: number of days ahead (optional, default 7)
    
    Response:
    {
        "appointments": [...],
        "count": 5
    }
    """
    days_ahead = int(request.GET.get("days", 7))
    
    service = AppointmentService()
    success, result = service.get_upcoming_appointments(
        user_id=request.user_id,
        user_role=request.user_role,
        days_ahead=days_ahead,
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["GET"])
@jwt_required
def get_appointment(request, appointment_id):
    """
    Get a specific appointment.
    
    GET /api/appointments/{appointment_id}/
    
    Response:
    {
        "appointment": {...}
    }
    """
    service = AppointmentService()
    success, result = service.get_appointment(appointment_id)
    
    if not success:
        return JsonResponse(result, status=404)
    
    appointment = result["appointment"]
    
    # Verify user has access (patient or doctor)
    if appointment["patient_id"] != request.user_id and appointment["doctor_id"] != request.user_id:
        return JsonResponse(
            {"error": "You don't have permission to view this appointment"},
            status=403
        )
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["POST"])
@jwt_required
def cancel_appointment(request, appointment_id):
    """
    Cancel an appointment.
    
    POST /api/appointments/{appointment_id}/cancel/
    
    Request Body:
    {
        "cancellation_reason": "patient_request",
        "cancellation_notes": "Feeling better"  // optional
    }
    
    Valid cancellation_reason values:
    - patient_request
    - doctor_unavailable
    - rescheduled
    - emergency
    - other
    
    Response:
    {
        "appointment": {...}  // Updated appointment with cancellation details
    }
    """
    try:
        data = json.loads(request.body)
    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON"}, status=400)
    
    cancellation_reason = data.get("cancellation_reason")
    if not cancellation_reason:
        return JsonResponse(
            {"error": "cancellation_reason is required"},
            status=400
        )
    
    service = AppointmentService()
    success, result = service.cancel_appointment(
        appointment_id=appointment_id,
        cancelled_by=request.user_id,
        cancellation_reason=cancellation_reason,
        cancellation_notes=data.get("cancellation_notes"),
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["POST"])
@jwt_required
def update_appointment_status(request, appointment_id):
    """
    Update appointment status.
    
    POST /api/appointments/{appointment_id}/status/
    
    Request Body:
    {
        "status": "confirmed"
    }
    
    Valid status values:
    - scheduled
    - confirmed
    - in_progress
    - completed
    - no_show
    
    (Use cancel endpoint for cancellations)
    
    Response:
    {
        "appointment": {...}  // Updated appointment
    }
    """
    try:
        data = json.loads(request.body)
    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON"}, status=400)
    
    status = data.get("status")
    if not status:
        return JsonResponse({"error": "status is required"}, status=400)
    
    service = AppointmentService()
    success, result = service.update_status(
        appointment_id=appointment_id,
        status=status,
        user_id=request.user_id,
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["POST"])
@jwt_required
def check_availability(request):
    """
    Check if a doctor is available for a time slot.
    
    POST /api/appointments/check-availability/
    
    Request Body:
    {
        "doctor_id": "uuid",
        "scheduled_start": "2026-01-20T10:00:00Z",
        "scheduled_end": "2026-01-20T10:30:00Z"
    }
    
    Response:
    {
        "is_available": true
    }
    """
    try:
        data = json.loads(request.body)
    except json.JSONDecodeError:
        return JsonResponse({"error": "Invalid JSON"}, status=400)
    
    required_fields = ["doctor_id", "scheduled_start", "scheduled_end"]
    missing = [f for f in required_fields if not data.get(f)]
    if missing:
        return JsonResponse(
            {"error": f"Missing required fields: {', '.join(missing)}"},
            status=400
        )
    
    scheduled_start = _parse_datetime(data["scheduled_start"])
    scheduled_end = _parse_datetime(data["scheduled_end"])
    
    if not scheduled_start or not scheduled_end:
        return JsonResponse(
            {"error": "Invalid datetime format"},
            status=400
        )
    
    service = AppointmentService()
    success, result = service.check_doctor_availability(
        doctor_id=data["doctor_id"],
        scheduled_start=scheduled_start,
        scheduled_end=scheduled_end,
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)


@csrf_exempt
@require_http_methods(["GET"])
@jwt_required
def get_doctor_availability_slots(request, doctor_id):
    """
    Get available time slots for a doctor on a specific date.
    
    GET /api/appointments/doctors/{doctor_id}/availability/?date=2026-01-20&duration=30
    
    Query Parameters:
    - date: YYYY-MM-DD format (required)
    - duration: slot duration in minutes (optional, default 30)
    
    Response:
    {
        "date": "2026-01-20",
        "available_slots": [
            {
                "slot_start": "2026-01-20T09:00:00Z",
                "slot_end": "2026-01-20T09:30:00Z",
                "is_available": true
            },
            ...
        ],
        "unavailable_slots": [...],
        "total_slots": 16,
        "available_count": 12
    }
    """
    date_str = request.GET.get("date")
    if not date_str:
        return JsonResponse({"error": "date parameter is required (YYYY-MM-DD)"}, status=400)
    
    # Validate date format
    try:
        datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        return JsonResponse({"error": "Invalid date format. Use YYYY-MM-DD"}, status=400)
    
    duration = int(request.GET.get("duration", 30))
    
    service = AppointmentService()
    success, result = service.get_doctor_availability_slots(
        doctor_id=doctor_id,
        date_str=date_str,
        slot_duration_minutes=duration,
    )
    
    if not success:
        return JsonResponse(result, status=400)
    
    return JsonResponse(result, status=200)