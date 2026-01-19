from django.urls import path, include

urlpatterns = [
    path("auth/", include("authentication.urls")),
    path("", include("core.urls")),
    path('api/appointments/', include('appointments.urls')),
]