-- =====================================================
-- APPOINTMENTS SCHEMA
-- Migration: 003_appointments.sql
-- Description: Appointment scheduling system
-- =====================================================

BEGIN;

-- =====================================================
-- CREATE SCHEMA
-- =====================================================

CREATE SCHEMA IF NOT EXISTS appointments;

-- =====================================================
-- ENUMS
-- =====================================================

CREATE TYPE appointments.appointment_status AS ENUM (
    'scheduled',     -- Initial state
    'confirmed',     -- Patient/Doctor confirmed
    'in_progress',   -- Appointment is happening
    'completed',     -- Finished successfully
    'cancelled',     -- Cancelled by patient or doctor
    'no_show'        -- Patient didn't show up
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

CREATE TABLE appointments.appointments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Relationships
    patient_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    doctor_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,

    -- Scheduling
    scheduled_start TIMESTAMPTZ NOT NULL,
    scheduled_end TIMESTAMPTZ NOT NULL,

    -- Status
    status appointments.APPOINTMENT_STATUS NOT NULL DEFAULT 'scheduled',

    -- Details
    reason TEXT NOT NULL,
    notes TEXT,

    -- Cancellation tracking
    cancelled_at TIMESTAMPTZ,
    cancelled_by UUID REFERENCES auth.users (id),
    cancellation_reason appointments.CANCELLATION_REASON,
    cancellation_notes TEXT,

    -- Completion tracking
    completed_at TIMESTAMPTZ,

    -- Audit fields
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,

    -- Business constraints
    CONSTRAINT valid_time_range
    CHECK (scheduled_end > scheduled_start),

    CONSTRAINT valid_duration
    CHECK (scheduled_end - scheduled_start <= INTERVAL '4 hours'),

    CONSTRAINT cancelled_fields_consistency
    CHECK (
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

    CONSTRAINT completed_fields_consistency
    CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR (status != 'completed' AND completed_at IS NULL)
    ),

    CONSTRAINT patient_not_doctor
    CHECK (patient_id != doctor_id),

    CONSTRAINT future_appointments
    CHECK (scheduled_start >= created_at - INTERVAL '1 hour')
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

-- Date range queries (optimized for calendar views)
CREATE INDEX idx_appointments_scheduled_start
ON appointments.appointments (scheduled_start)
WHERE deleted_at IS NULL;

CREATE INDEX idx_appointments_scheduled_end
ON appointments.appointments (scheduled_end)
WHERE deleted_at IS NULL;

-- Conflict detection (doctor availability checks)
CREATE INDEX idx_appointments_doctor_timerange
ON appointments.appointments (doctor_id, scheduled_start, scheduled_end)
WHERE deleted_at IS NULL
AND status NOT IN ('cancelled', 'no_show');

-- Patient availability (prevent double-booking patients)
CREATE INDEX idx_appointments_patient_timerange
ON appointments.appointments (patient_id, scheduled_start, scheduled_end)
WHERE deleted_at IS NULL
AND status NOT IN ('cancelled', 'no_show');

-- Composite index for filtered queries
CREATE INDEX idx_appointments_user_status_date
ON appointments.appointments (patient_id, doctor_id, status, scheduled_start)
WHERE deleted_at IS NULL;

-- Audit queries
CREATE INDEX idx_appointments_created_at
ON appointments.appointments (created_at DESC);

-- =====================================================
-- ROW LEVEL SECURITY (RLS)
-- =====================================================

ALTER TABLE appointments.appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments.appointments FORCE ROW LEVEL SECURITY;

-- Service role (medilink_ops): Full access for backend operations
CREATE POLICY service_full_access ON appointments.appointments
FOR ALL
TO medilink_ops
USING (TRUE)
WITH CHECK (TRUE);

-- Patients: Can view their own appointments
CREATE POLICY patient_view_own ON appointments.appointments
FOR SELECT
TO medilink_ops
USING (
    patient_id = (current_setting('request.jwt.claims', TRUE)::JSON ->> 'sub')::UUID
    AND deleted_at IS NULL
);

-- Doctors: Can view appointments where they are the assigned doctor
CREATE POLICY doctor_view_own ON appointments.appointments
FOR SELECT
TO medilink_ops
USING (
    doctor_id = (current_setting('request.jwt.claims', TRUE)::JSON ->> 'sub')::UUID
    AND deleted_at IS NULL
);

-- Users cannot directly INSERT/UPDATE/DELETE
-- All mutations must go through RPC functions to enforce business logic

-- =====================================================
-- TRIGGERS
-- =====================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION appointments.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_appointments_updated_at
BEFORE UPDATE ON appointments.appointments
FOR EACH ROW
EXECUTE FUNCTION appointments.update_updated_at();

-- =====================================================
-- RPC FUNCTIONS (Business Logic)
-- =====================================================

-- -----------------------------------------------------
-- Check if doctor is available for a time slot
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.is_doctor_available(
    p_doctor_id UUID,
    p_start TIMESTAMPTZ,
    p_end TIMESTAMPTZ,
    p_exclude_appointment_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1
        FROM appointments.appointments
        WHERE doctor_id = p_doctor_id
          AND deleted_at IS NULL
          AND status NOT IN ('cancelled', 'no_show')
          AND (id IS DISTINCT FROM p_exclude_appointment_id)
          AND (
              -- Time overlap check
              (p_start, p_end) OVERLAPS (scheduled_start, scheduled_end)
          )
    );
END;
$$;

-- -----------------------------------------------------
-- Check if patient is available (prevent double-booking)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.is_patient_available(
    p_patient_id UUID,
    p_start TIMESTAMPTZ,
    p_end TIMESTAMPTZ,
    p_exclude_appointment_id UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1
        FROM appointments.appointments
        WHERE patient_id = p_patient_id
          AND deleted_at IS NULL
          AND status NOT IN ('cancelled', 'no_show')
          AND (id IS DISTINCT FROM p_exclude_appointment_id)
          AND (
              (p_start, p_end) OVERLAPS (scheduled_start, scheduled_end)
          )
    );
END;
$$;

-- -----------------------------------------------------
-- Create appointment (with comprehensive validation)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.create_appointment(
    p_patient_id UUID,
    p_doctor_id UUID,
    p_scheduled_start TIMESTAMPTZ,
    p_scheduled_end TIMESTAMPTZ,
    p_reason TEXT,
    p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_appointment_id UUID;
    v_patient_role TEXT;
    v_doctor_role TEXT;
    v_patient_deleted TIMESTAMPTZ;
    v_doctor_deleted TIMESTAMPTZ;
BEGIN
    -- ---------------------------------------------
    -- 1. VALIDATE PATIENT
    -- ---------------------------------------------
    SELECT p_role, deleted_at 
    INTO v_patient_role, v_patient_deleted
    FROM auth.users
    WHERE id = p_patient_id;
    
    IF v_patient_role IS NULL THEN
        RAISE EXCEPTION 'Patient not found';
    END IF;
    
    IF v_patient_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'Patient account is deleted';
    END IF;
    
    IF v_patient_role != 'patient' THEN
        RAISE EXCEPTION 'User is not a patient (role: %)', v_patient_role;
    END IF;
    
    -- ---------------------------------------------
    -- 2. VALIDATE DOCTOR
    -- ---------------------------------------------
    SELECT p_role, deleted_at 
    INTO v_doctor_role, v_doctor_deleted
    FROM auth.users
    WHERE id = p_doctor_id;
    
    IF v_doctor_role IS NULL THEN
        RAISE EXCEPTION 'Doctor not found';
    END IF;
    
    IF v_doctor_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'Doctor account is deleted';
    END IF;
    
    IF v_doctor_role != 'doctor' THEN
        RAISE EXCEPTION 'User is not a doctor (role: %)', v_doctor_role;
    END IF;
    
    -- ---------------------------------------------
    -- 3. VALIDATE TIME RANGE
    -- ---------------------------------------------
    IF p_scheduled_end <= p_scheduled_start THEN
        RAISE EXCEPTION 'End time must be after start time';
    END IF;
    
    IF p_scheduled_end - p_scheduled_start > INTERVAL '4 hours' THEN
        RAISE EXCEPTION 'Appointment cannot exceed 4 hours';
    END IF;
    
    IF p_scheduled_end - p_scheduled_start < INTERVAL '15 minutes' THEN
        RAISE EXCEPTION 'Appointment must be at least 15 minutes';
    END IF;
    
    IF p_scheduled_start < NOW() THEN
        RAISE EXCEPTION 'Cannot schedule appointments in the past';
    END IF;
    
    -- Don't allow appointments more than 1 year in advance
    IF p_scheduled_start > NOW() + INTERVAL '1 year' THEN
        RAISE EXCEPTION 'Cannot schedule appointments more than 1 year in advance';
    END IF;
    
    -- ---------------------------------------------
    -- 4. VALIDATE REASON
    -- ---------------------------------------------
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'Appointment reason is required';
    END IF;
    
    IF LENGTH(p_reason) > 500 THEN
        RAISE EXCEPTION 'Reason cannot exceed 500 characters';
    END IF;
    
    -- ---------------------------------------------
    -- 5. CHECK DOCTOR AVAILABILITY
    -- ---------------------------------------------
    IF NOT appointments.is_doctor_available(
        p_doctor_id, 
        p_scheduled_start, 
        p_scheduled_end
    ) THEN
        RAISE EXCEPTION 'Doctor is not available at the requested time';
    END IF;
    
    -- ---------------------------------------------
    -- 6. CHECK PATIENT AVAILABILITY
    -- ---------------------------------------------
    IF NOT appointments.is_patient_available(
        p_patient_id,
        p_scheduled_start,
        p_scheduled_end
    ) THEN
        RAISE EXCEPTION 'Patient already has an appointment at this time';
    END IF;
    
    -- ---------------------------------------------
    -- 7. CREATE APPOINTMENT
    -- ---------------------------------------------
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
        TRIM(p_reason),
        TRIM(p_notes),
        'scheduled'
    )
    RETURNING id INTO v_appointment_id;
    
    RETURN v_appointment_id;
END;
$$;

-- -----------------------------------------------------
-- Cancel appointment
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.cancel_appointment(
    p_appointment_id UUID,
    p_cancelled_by UUID,
    p_cancellation_reason appointments.CANCELLATION_REASON,
    p_cancellation_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_current_status appointments.appointment_status;
    v_patient_id UUID;
    v_doctor_id UUID;
BEGIN
    -- Get appointment details
    SELECT status, patient_id, doctor_id
    INTO v_current_status, v_patient_id, v_doctor_id
    FROM appointments.appointments
    WHERE id = p_appointment_id
      AND deleted_at IS NULL;
    
    -- Validate appointment exists
    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;
    
    -- Validate cancellation authority
    IF p_cancelled_by != v_patient_id AND p_cancelled_by != v_doctor_id THEN
        RAISE EXCEPTION 'Only the patient or doctor can cancel this appointment';
    END IF;
    
    -- Validate current status
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
        cancellation_notes = TRIM(p_cancellation_notes)
    WHERE id = p_appointment_id;
    
    RETURN TRUE;
END;
$$;

-- -----------------------------------------------------
-- Update appointment status
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.update_appointment_status(
    p_appointment_id UUID,
    p_status appointments.APPOINTMENT_STATUS,
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_current_status appointments.appointment_status;
    v_doctor_id UUID;
    v_patient_id UUID;
BEGIN
    -- Get current appointment
    SELECT status, doctor_id, patient_id
    INTO v_current_status, v_doctor_id, v_patient_id
    FROM appointments.appointments
    WHERE id = p_appointment_id
      AND deleted_at IS NULL;
    
    IF v_current_status IS NULL THEN
        RAISE EXCEPTION 'Appointment not found';
    END IF;
    
    -- Authorization checks
    IF p_status IN ('in_progress', 'completed', 'no_show') THEN
        -- Only doctor can mark these statuses
        IF p_user_id != v_doctor_id THEN
            RAISE EXCEPTION 'Only the assigned doctor can update to this status';
        END IF;
    ELSIF p_status = 'confirmed' THEN
        -- Both patient and doctor can confirm
        IF p_user_id != v_doctor_id AND p_user_id != v_patient_id THEN
            RAISE EXCEPTION 'Only the patient or doctor can confirm the appointment';
        END IF;
    ELSIF p_status = 'cancelled' THEN
        RAISE EXCEPTION 'Use cancel_appointment function for cancellations';
    END IF;
    
    -- Validate state transitions
    IF v_current_status = 'cancelled' THEN
        RAISE EXCEPTION 'Cannot update cancelled appointment';
    END IF;
    
    IF v_current_status = 'completed' THEN
        RAISE EXCEPTION 'Cannot change status of completed appointment';
    END IF;
    
    IF v_current_status = 'no_show' AND p_status != 'no_show' THEN
        RAISE EXCEPTION 'Cannot change status of no-show appointment';
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
$$;

-- -----------------------------------------------------
-- Get appointments by date range
-- -----------------------------------------------------
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
    cancelled_at TIMESTAMPTZ,
    cancelled_by UUID,
    cancellation_reason appointments.CANCELLATION_REASON,
    cancellation_notes TEXT,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
            a.cancelled_at,
            a.cancelled_by,
            a.cancellation_reason,
            a.cancellation_notes,
            a.completed_at,
            a.created_at,
            a.updated_at
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
            a.cancelled_at,
            a.cancelled_by,
            a.cancellation_reason,
            a.cancellation_notes,
            a.completed_at,
            a.created_at,
            a.updated_at
        FROM appointments.appointments a
        WHERE a.doctor_id = p_user_id
          AND a.deleted_at IS NULL
          AND a.scheduled_start >= p_start_date
          AND a.scheduled_start <= p_end_date
        ORDER BY a.scheduled_start;
        
    ELSE
        RAISE EXCEPTION 'Invalid user role: %', p_user_role;
    END IF;
END;
$$;

-- -----------------------------------------------------
-- Get doctor availability slots
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.get_doctor_availability(
    p_doctor_id UUID,
    p_date DATE,
    p_slot_duration_minutes INT DEFAULT 30
)
RETURNS TABLE (
    slot_start TIMESTAMPTZ,
    slot_end TIMESTAMPTZ,
    is_available BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_day_start TIMESTAMPTZ;
    v_day_end TIMESTAMPTZ;
    v_current_slot TIMESTAMPTZ;
    v_slot_end TIMESTAMPTZ;
BEGIN
    -- Validate doctor exists
    IF NOT EXISTS (
        SELECT 1 FROM auth.users 
        WHERE id = p_doctor_id 
          AND p_role = 'doctor' 
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Doctor not found';
    END IF;
    
    -- Define working hours (9 AM to 5 PM)
    v_day_start := p_date::TIMESTAMPTZ + TIME '09:00:00';
    v_day_end := p_date::TIMESTAMPTZ + TIME '17:00:00';
    
    v_current_slot := v_day_start;
    
    WHILE v_current_slot < v_day_end LOOP
        v_slot_end := v_current_slot + (p_slot_duration_minutes || ' minutes')::INTERVAL;
        
        -- Don't go past end of day
        IF v_slot_end > v_day_end THEN
            EXIT;
        END IF;
        
        RETURN QUERY
        SELECT 
            v_current_slot,
            v_slot_end,
            appointments.is_doctor_available(
                p_doctor_id,
                v_current_slot,
                v_slot_end
            );
        
        v_current_slot := v_slot_end;
    END LOOP;
END;
$$;

-- -----------------------------------------------------
-- Get upcoming appointments (next 7 days)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION appointments.get_upcoming_appointments(
    p_user_id UUID,
    p_user_role TEXT,
    p_days_ahead INT DEFAULT 7
)
RETURNS TABLE (
    id UUID,
    patient_id UUID,
    doctor_id UUID,
    scheduled_start TIMESTAMPTZ,
    scheduled_end TIMESTAMPTZ,
    status appointments.APPOINTMENT_STATUS,
    reason TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM appointments.get_appointments_by_date_range(
        p_user_id,
        p_user_role,
        NOW(),
        NOW() + (p_days_ahead || ' days')::INTERVAL
    );
END;
$$;

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

-- Grant execute on all RPC functions to authenticated users
GRANT EXECUTE ON FUNCTION appointments.is_doctor_available TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.is_patient_available TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.create_appointment TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.cancel_appointment TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.update_appointment_status TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.get_appointments_by_date_range TO medilink_ops,
medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.get_doctor_availability TO medilink_ops, medilink_ops;
GRANT EXECUTE ON FUNCTION appointments.get_upcoming_appointments TO medilink_ops, medilink_ops;

-- Grant usage on schema
GRANT USAGE ON SCHEMA appointments TO medilink_ops, medilink_ops;

-- Grant select on appointments table (RLS will filter)
GRANT SELECT ON appointments.appointments TO medilink_ops, medilink_ops;

-- Grant all on appointments table to service role
GRANT ALL ON appointments.appointments TO medilink_ops;

COMMIT;
