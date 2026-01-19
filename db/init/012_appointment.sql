BEGIN;
-- =====================================================
-- APPOINTMENTS SCHEMA
-- =====================================================

CREATE SCHEMA IF NOT EXISTS appointments;

-- =====================================================
-- ENUMS
-- =====================================================

CREATE TYPE appointments.appointment_status AS ENUM (
    'scheduled',
    'confirmed',
    'in_progress',
    'completed',
    'cancelled',
    'no_show'
);

CREATE TYPE appointments.cancellation_reason AS ENUM (
    'patient_request',
    'doctor_unavailable',
    'rescheduled',
    'emergency',
    'other'
);

-- =====================================================
-- TABLES
-- =====================================================

-- Appointments table
CREATE TABLE appointments.appointments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Relationships
    patient_id UUID NOT NULL REFERENCES auth.users (id),
    doctor_id UUID NOT NULL REFERENCES auth.users (id),

    -- Scheduling
    scheduled_start TIMESTAMPTZ NOT NULL,
    scheduled_end TIMESTAMPTZ NOT NULL,

    -- Status
    status appointments.APPOINTMENT_STATUS NOT NULL DEFAULT 'scheduled',

    -- Details
    reason TEXT NOT NULL,
    notes TEXT,

    -- Cancellation
    cancelled_at TIMESTAMPTZ,
    cancelled_by UUID REFERENCES auth.users (id),
    cancellation_reason appointments.CANCELLATION_REASON,
    cancellation_notes TEXT,

    -- Completion
    completed_at TIMESTAMPTZ,

    -- Audit
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    -- Constraints
    CONSTRAINT valid_time_range CHECK (scheduled_end > scheduled_start),
    CONSTRAINT valid_duration CHECK (scheduled_end - scheduled_start <= INTERVAL '4 hours'),
    CONSTRAINT cancelled_fields CHECK (
        (
            status = 'cancelled'
            AND cancelled_at IS NOT NULL
            AND cancelled_by IS NOT NULL
            AND cancellation_reason IS NOT NULL
        )
        OR (
            status != 'cancelled'
            AND cancelled_at IS NULL
            AND cancelled_by IS NULL
            AND cancellation_reason IS NULL
        )
    ),
    CONSTRAINT completed_fields CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR (status != 'completed' AND completed_at IS NULL)
    ),
    CONSTRAINT patient_not_doctor CHECK (patient_id != doctor_id)
);

-- =====================================================
-- INDEXES
-- =====================================================

-- Primary access patterns
CREATE INDEX idx_appointments_patient
ON appointments.appointments (patient_id, scheduled_start DESC)
WHERE deleted_at IS NULL;

CREATE INDEX idx_appointments_doctor
ON appointments.appointments (doctor_id, scheduled_start DESC)
WHERE deleted_at IS NULL;

CREATE INDEX idx_appointments_status
ON appointments.appointments (status, scheduled_start)
WHERE deleted_at IS NULL;

-- Date range queries
CREATE INDEX idx_appointments_scheduled_start
ON appointments.appointments (scheduled_start)
WHERE deleted_at IS NULL;

CREATE INDEX idx_appointments_scheduled_end
ON appointments.appointments (scheduled_end)
WHERE deleted_at IS NULL;

-- Conflict detection (doctor availability)
CREATE INDEX idx_appointments_doctor_timerange
ON appointments.appointments (doctor_id, scheduled_start, scheduled_end)
WHERE deleted_at IS NULL
AND status NOT IN ('cancelled', 'no_show');

-- Audit queries
CREATE INDEX idx_appointments_created_at
ON appointments.appointments (created_at DESC);

-- =====================================================
-- ROW LEVEL SECURITY (RLS)
-- =====================================================

ALTER TABLE appointments.appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments.appointments FORCE ROW LEVEL SECURITY;

-- Service role (medilink_ops): Full access
CREATE POLICY service_full_access ON appointments.appointments
FOR ALL
TO medilink_ops
USING (TRUE)
WITH CHECK (TRUE);

-- Patients: Can view their own appointments
CREATE POLICY patient_view_own
ON appointments.appointments
FOR SELECT
TO medilink_ops
USING (
    (current_setting('request.jwt.claims', TRUE)::JSON ->> 'role') = 'patient'
    AND patient_id = (current_setting('request.jwt.claims', TRUE)::JSON ->> 'sub')::UUID
    AND deleted_at IS NULL
);


-- Doctors: Can view appointments where they are the doctor
CREATE POLICY doctor_view_own
ON appointments.appointments
FOR SELECT
TO medilink_ops
USING (
    (current_setting('request.jwt.claims', TRUE)::JSON ->> 'role') = 'doctor'
    AND doctor_id = (current_setting('request.jwt.claims', TRUE)::JSON ->> 'sub')::UUID
    AND deleted_at IS NULL
);


-- No direct INSERT/UPDATE/DELETE for users (must use RPCs)
-- This ensures business logic is enforced

-- =====================================================
-- HELPER FUNCTIONS
-- =====================================================

-- Update updated_at timestamp
CREATE OR REPLACE FUNCTION appointments.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_appointments_updated_at
BEFORE UPDATE ON appointments.appointments
FOR EACH ROW
EXECUTE FUNCTION appointments.update_updated_at();

-- =====================================================
-- RPC FUNCTIONS (Business Logic)
-- =====================================================

-- Check if doctor is available for a time slot
CREATE OR REPLACE FUNCTION appointments.is_doctor_available(
    p_doctor_id UUID,
    p_start TIMESTAMPTZ,
    p_end TIMESTAMPTZ,
    p_exclude_appointment_id UUID DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1
        FROM appointments.appointments
        WHERE doctor_id = p_doctor_id
          AND deleted_at IS NULL
          AND status NOT IN ('cancelled', 'no_show')
          AND id != COALESCE(p_exclude_appointment_id, '00000000-0000-0000-0000-000000000000'::uuid)
          AND (
              -- New appointment overlaps existing
              (p_start, p_end) OVERLAPS (scheduled_start, scheduled_end)
          )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create appointment (with validation)
CREATE OR REPLACE FUNCTION appointments.create_appointment(
    p_patient_id UUID,
    p_doctor_id UUID,
    p_scheduled_start TIMESTAMPTZ,
    p_scheduled_end TIMESTAMPTZ,
    p_reason TEXT,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_appointment_id UUID;
    v_patient_role TEXT;
    v_doctor_role TEXT;
BEGIN
    -- Validate patient role
    SELECT p_role INTO v_patient_role
    FROM auth.users
    WHERE id = p_patient_id AND deleted_at IS NULL;
    
    IF v_patient_role IS NULL THEN
        RAISE EXCEPTION 'Patient not found';
    END IF;
    
    IF v_patient_role != 'patient' THEN
        RAISE EXCEPTION 'Invalid patient role';
    END IF;
    
    -- Validate doctor role
    SELECT p_role INTO v_doctor_role
    FROM auth.users
    WHERE id = p_doctor_id AND deleted_at IS NULL;
    
    IF v_doctor_role IS NULL THEN
        RAISE EXCEPTION 'Doctor not found';
    END IF;
    
    IF v_doctor_role != 'doctor' THEN
        RAISE EXCEPTION 'Invalid doctor role';
    END IF;
    
    -- Validate time range
    IF p_scheduled_end <= p_scheduled_start THEN
        RAISE EXCEPTION 'End time must be after start time';
    END IF;
    
    IF p_scheduled_end - p_scheduled_start > INTERVAL '4 hours' THEN
        RAISE EXCEPTION 'Appointment cannot exceed 4 hours';
    END IF;
    
    IF p_scheduled_start < NOW() THEN
        RAISE EXCEPTION 'Cannot schedule appointments in the past';
    END IF;
    
    -- Check doctor availability
    IF NOT appointments.is_doctor_available(p_doctor_id, p_scheduled_start, p_scheduled_end) THEN
        RAISE EXCEPTION 'Doctor is not available at the requested time';
    END IF;
    
    -- Create appointment
    INSERT INTO appointments.appointments (
        patient_id,
        doctor_id,
        scheduled_start,
        scheduled_end,
        reason,
        notes,
        status
    ) VALUES (
        p_patient_id,
        p_doctor_id,
        p_scheduled_start,
        p_scheduled_end,
        p_reason,
        p_notes,
        'scheduled'
    )
    RETURNING id INTO v_appointment_id;
    
    RETURN v_appointment_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cancel appointment
CREATE OR REPLACE FUNCTION appointments.cancel_appointment(
    p_appointment_id UUID,
    p_cancelled_by UUID,
    p_cancellation_reason appointments.CANCELLATION_REASON,
    p_cancellation_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_status appointments.appointment_status;
BEGIN
    -- Get current status
    SELECT status INTO v_current_status
    FROM appointments.appointments
    WHERE id = p_appointment_id
      AND deleted_at IS NULL;
    
    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;
    
    IF v_current_status IN ('completed', 'cancelled', 'no_show') THEN
        RAISE EXCEPTION 'Cannot cancel appointment in % status', v_current_status;
    END IF;
    
    -- Cancel appointment
    UPDATE appointments.appointments
    SET 
        status = 'cancelled',
        cancelled_at = NOW(),
        cancelled_by = p_cancelled_by,
        cancellation_reason = p_cancellation_reason,
        cancellation_notes = p_cancellation_notes
    WHERE id = p_appointment_id;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update appointment status
CREATE OR REPLACE FUNCTION appointments.update_appointment_status(
    p_appointment_id UUID,
    p_status appointments.APPOINTMENT_STATUS,
    p_user_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_status appointments.appointment_status;
    v_doctor_id UUID;
BEGIN
    -- Get current appointment
    SELECT status, doctor_id 
    INTO v_current_status, v_doctor_id
    FROM appointments.appointments
    WHERE id = p_appointment_id
      AND deleted_at IS NULL;
    
    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;
    
    -- Only doctor can update status (except cancellation)
    IF p_status != 'cancelled' AND p_user_id != v_doctor_id THEN
        RAISE EXCEPTION 'Only the assigned doctor can update appointment status';
    END IF;
    
    -- Validate state transitions
    IF v_current_status = 'cancelled' THEN
        RAISE EXCEPTION 'Cannot update cancelled appointment';
    END IF;
    
    IF v_current_status = 'completed' AND p_status != 'completed' THEN
        RAISE EXCEPTION 'Cannot change status of completed appointment';
    END IF;
    
    -- Update status
    IF p_status = 'completed' THEN
        UPDATE appointments.appointments
        SET 
            status = p_status,
            completed_at = NOW()
        WHERE id = p_appointment_id;
    ELSE
        UPDATE appointments.appointments
        SET status = p_status
        WHERE id = p_appointment_id;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get appointments for date range
CREATE OR REPLACE FUNCTION appointments.get_appointments_by_date_range(
    p_user_id UUID,
    p_user_role TEXT,
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE (
    id UUID,
    patient_id UUID,
    doctor_id UUID,
    scheduled_start TIMESTAMPTZ,
    scheduled_end TIMESTAMPTZ,
    status appointments.APPOINTMENT_STATUS,
    reason TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    IF p_user_role = 'patient' THEN
        RETURN QUERY
        SELECT 
            a.id,
            a.patient_id,
            a.doctor_id,
            a.scheduled_start,
            a.scheduled_end,
            a.status,
            a.reason,
            a.notes,
            a.created_at
        FROM appointments.appointments a
        WHERE a.patient_id = p_user_id
          AND a.deleted_at IS NULL
          AND a.scheduled_start >= p_start_date
          AND a.scheduled_start <= p_end_date
        ORDER BY a.scheduled_start;
    ELSIF p_user_role = 'doctor' THEN
        RETURN QUERY
        SELECT 
            a.id,
            a.patient_id,
            a.doctor_id,
            a.scheduled_start,
            a.scheduled_end,
            a.status,
            a.reason,
            a.notes,
            a.created_at
        FROM appointments.appointments a
        WHERE a.doctor_id = p_user_id
          AND a.deleted_at IS NULL
          AND a.scheduled_start >= p_start_date
          AND a.scheduled_start <= p_end_date
        ORDER BY a.scheduled_start;
    ELSE
        RAISE EXCEPTION 'Invalid user role';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get doctor availability slots
CREATE OR REPLACE FUNCTION appointments.get_doctor_availability(
    p_doctor_id UUID,
    p_date DATE,
    p_slot_duration_minutes INT DEFAULT 30
)
RETURNS TABLE (
    slot_start TIMESTAMPTZ,
    slot_end TIMESTAMPTZ,
    is_available BOOLEAN
) AS $$
DECLARE
    v_day_start TIMESTAMPTZ;
    v_day_end TIMESTAMPTZ;
    v_current_slot TIMESTAMPTZ;
BEGIN
    -- Define working hours (9 AM to 5 PM)
    v_day_start := p_date + TIME '09:00:00';
    v_day_end := p_date + TIME '17:00:00';
    
    v_current_slot := v_day_start;
    
    WHILE v_current_slot < v_day_end LOOP
        RETURN QUERY
        SELECT 
            v_current_slot,
            v_current_slot + (p_slot_duration_minutes || ' minutes')::INTERVAL,
            appointments.is_doctor_available(
                p_doctor_id,
                v_current_slot,
                v_current_slot + (p_slot_duration_minutes || ' minutes')::INTERVAL
            );
        
        v_current_slot := v_current_slot + (p_slot_duration_minutes || ' minutes')::INTERVAL;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION appointments.get_appointments_by_date_range(
    p_start_date TIMESTAMPTZ,
    p_end_date TIMESTAMPTZ
)
RETURNS TABLE (
    id UUID,
    patient_id UUID,
    doctor_id UUID,
    scheduled_start TIMESTAMPTZ,
    scheduled_end TIMESTAMPTZ,
    status appointments.APPOINTMENT_STATUS,
    reason TEXT,
    notes TEXT,
    created_at TIMESTAMPTZ
) AS $$
DECLARE
    v_user_id UUID := (current_setting('request.jwt.claims', true)::json ->> 'sub')::uuid;
    v_role TEXT := current_setting('request.jwt.claims', true)::json ->> 'role';
BEGIN
    IF v_role = 'patient' THEN
        RETURN QUERY
        SELECT a.id, a.patient_id, a.doctor_id,
               a.scheduled_start, a.scheduled_end,
               a.status, a.reason, a.notes, a.created_at
        FROM appointments.appointments a
        WHERE a.patient_id = v_user_id
          AND a.deleted_at IS NULL
          AND a.scheduled_start BETWEEN p_start_date AND p_end_date
        ORDER BY a.scheduled_start;

    ELSIF v_role = 'doctor' THEN
        RETURN QUERY
        SELECT a.id, a.patient_id, a.doctor_id,
               a.scheduled_start, a.scheduled_end,
               a.status, a.reason, a.notes, a.created_at
        FROM appointments.appointments a
        WHERE a.doctor_id = v_user_id
          AND a.deleted_at IS NULL
          AND a.scheduled_start BETWEEN p_start_date AND p_end_date
        ORDER BY a.scheduled_start;
    ELSE
        RAISE EXCEPTION 'Invalid role';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
