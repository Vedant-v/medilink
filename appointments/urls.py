from django.urls import path
from appointments import views

urlpatterns = [
    # Appointment CRUD
    path('', views.create_appointment, name='create_appointment'),
    path('list/', views.list_appointments, name='list_appointments'),
    path('upcoming/', views.get_upcoming_appointments, name='upcoming_appointments'),
    path('<uuid:appointment_id>/', views.get_appointment, name='get_appointment'),
    
    # Appointment actions
    path('<uuid:appointment_id>/cancel/', views.cancel_appointment, name='cancel_appointment'),
    path('<uuid:appointment_id>/status/', views.update_appointment_status, name='update_appointment_status'),
    
    # Availability
    path('check-availability/', views.check_availability, name='check_availability'),
    path('doctors/<uuid:doctor_id>/availability/', views.get_doctor_availability_slots, name='doctor_availability'),
]