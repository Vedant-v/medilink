import jwt
from functools import wraps
from django.http import JsonResponse
from django.conf import settings

def jwt_required(view_func):
    """
    Decorator to require JWT authentication.
    Extracts user_id, user_role, and session_id from JWT.
    """
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        
        if not auth_header.startswith('Bearer '):
            return JsonResponse(
                {'error': 'Missing or invalid Authorization header'},
                status=401
            )
        
        token = auth_header.split(' ')[1]
        
        try:
            payload = jwt.decode(
                token,
                settings.JWT_SECRET_KEY,
                algorithms=['HS256'],
                audience=settings.JWT_AUDIENCE,
                issuer=settings.JWT_ISSUER,
            )
            
            # Attach user info to request
            request.user_id = payload['sub']
            request.user_role = payload['role']
            request.session_id = payload.get('sid')
            
        except jwt.ExpiredSignatureError:
            return JsonResponse({'error': 'Token expired'}, status=401)
        except jwt.InvalidTokenError:
            return JsonResponse({'error': 'Invalid token'}, status=401)
        
        return view_func(request, *args, **kwargs)
    
    return wrapper