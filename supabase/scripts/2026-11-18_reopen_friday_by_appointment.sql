-- ============================================================
-- Reopen Friday as "by appointment" at every active location
-- ============================================================
-- Run in the Supabase SQL Editor. Safe to run more than once.
--
-- Why: New Reservation showed "This location is closed that day" and
-- an empty time list for Friday, because Friday's row in
-- location_hours was set to closed (or missing). The intended rule
-- (seed data and client policy): Friday is OPEN BY APPOINTMENT ONLY,
-- 10:00 AM - 5:00 PM, and every Friday pickup or drop-off needs staff
-- approval. The approval part is already enforced by
-- reservations_approval_guard() (isodow = 5 -> pending); it just
-- needs Friday to have hours so there are times to pick.
--
-- Keeps Friday's own stored open/close times if a closed row still
-- has them; otherwise uses 10:00-17:00.
-- ============================================================

-- 1. Preview: Friday as it is now, per location
select l.name, h.is_open, h.appointment_only, h.open_time, h.close_time
from public.locations l
left join public.location_hours h
  on h.location_id = l.id and h.day_of_week = 'friday'
where l.is_active
order by l.name;

-- 2. Fix
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

-- 3. Check: every active location should now show Friday open, by appointment
select l.name, h.is_open, h.appointment_only, h.open_time, h.close_time
from public.locations l
join public.location_hours h
  on h.location_id = l.id and h.day_of_week = 'friday'
where l.is_active
order by l.name;
