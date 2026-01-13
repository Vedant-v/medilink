BEGIN;

CREATE TYPE auth.primary_role AS ENUM (
    'patient',
    'doctor',
    'nurse',
    'receptionist',
    'lab_technician',
    'pharmacist',
    'radiologist',
    'therapist',
    'surgeon',
    'anesthesiologist',
    'paramedic',
    'dietitian',
    'medical_assistant',
    'healthcare_admin'
);

COMMIT;
