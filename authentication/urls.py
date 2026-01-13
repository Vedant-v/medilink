from django.urls import path
from authentication.views import register_view

urlpatterns = [
    path("register/", register_view, name="register"),
]
