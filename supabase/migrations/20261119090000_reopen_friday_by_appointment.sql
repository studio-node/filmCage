-- ============================================================
-- Migration 34 -- reopen Friday as "by appointment" (data fix)
-- ============================================================
-- Same fix as supabase/scripts/2026-11-18_reopen_friday_by_appointment.sql,
-- moved into a migration so `supabase db push` actually applies it
-- (db push only runs supabase/migrations/, never supabase/scripts/).
--
-- Friday's location_hours row was Closed (or missing), so New
-- Reservation said the location was closed and offered no times.
-- Intended rule: Friday is open BY APPOINTMENT ONLY, 10:00-17:00, and
-- every Friday pickup/drop-off needs staff approval (already enforced
-- by reservations_approval_guard, isodow = 5).
--
-- Keeps any Friday times a closed row still has; inserts a missing
-- Friday row; leaves an already-open Friday alone. Idempotent.
-- ============================================================

insert into public.location_hours (location_id, day_of_week, is_open, appointment_only, open_time, close_time)
select l.id, 'friday', true, true, time '10:00', time '17:00'
from public.locations l
where l.is_active
on conflict (location_id, day_of_week) do update
  set is_open          = true,
      appointment_only = true,
      open_time        = coalesce(public.location_hours.open_time,  excluded.open_time),
      close_time       = coalesce(public.location_hours.close_time, excluded.close_time)
  where public.location_hours.is_open = false;
