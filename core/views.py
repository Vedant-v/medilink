from django.http import JsonResponse
from django.db import connections


def health_check(request):
    try:
        connections["default"].cursor()
        return JsonResponse({"status": "ok"})
    except Exception:
        return JsonResponse({"status": "db_error"}, status=503)
