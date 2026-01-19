from django.urls import path
from authentication.views import (
    register_view,
    login_view,
)

urlpatterns = [
    # Registration & auth
    path("register/", register_view, name="auth-register"),
    path("login/", login_view, name="auth-login"),
]
