import jwt
from django.http import JsonResponse
from functools import wraps

from authentication.services.jwt_tokens import JWT_SECRET, JWT_ALGORITHM


def jwt_required(view_func):
    @wraps(view_func)
    def _wrapped(request, *args, **kwargs):
        auth_header = request.headers.get("Authorization")

        if not auth_header or not auth_header.startswith("Bearer "):
            return JsonResponse({"error": "Authentication required"}, status=401)

        token = auth_header.split(" ", 1)[1]

        try:
            payload = jwt.decode(
                token,
                JWT_SECRET,
                algorithms=[JWT_ALGORITHM],
                audience="medilink",
            )
        except jwt.ExpiredSignatureError:
            return JsonResponse({"error": "Token expired"}, status=401)
        except jwt.InvalidTokenError:
            return JsonResponse({"error": "Invalid token"}, status=401)

        # Attach to request (THIS IS IMPORTANT)
        request.user_id = payload.get("sub")
        request.user_role = payload.get("role")
        request.session_id = payload.get("sid")
        request.jwt_token = token  # raw token for PostgREST

        if not request.user_id or not request.user_role:
            return JsonResponse({"error": "Invalid token payload"}, status=401)

        return view_func(request, *args, **kwargs)

    return _wrapped
