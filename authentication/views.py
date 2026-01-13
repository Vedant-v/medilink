from django.http import JsonResponse
import json

from authentication.services.Registretion import Registretion


MAX_BODY_SIZE = 10 * 1024  # 10 KB, more than enough for registration


def register_view(request):
    if request.method != "POST":
        return JsonResponse(
            {"error": "Only POST method is allowed"},
            status=405,
        )

    if request.content_type != "application/json":
        return JsonResponse(
            {"error": "Content-Type must be application/json"},
            status=415,
        )

    if request.META.get("CONTENT_LENGTH") and int(request.META["CONTENT_LENGTH"]) > MAX_BODY_SIZE:
        return JsonResponse(
            {"error": "Request body too large"},
            status=413,
        )

    try:
        data = json.loads(request.body)
    except json.JSONDecodeError:
        return JsonResponse(
            {"error": "Invalid JSON"},
            status=400,
        )

    registration_service = Registretion(data)

    return registration_service.register()
