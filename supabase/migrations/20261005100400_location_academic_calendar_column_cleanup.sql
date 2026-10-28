-- ============================================================
-- More audit-column cleanup confirmed 10/1-10/4, same "accountable
-- transaction vs. configuration data" principle as the semesters
-- migration just before this one:
--  - locations.created_by: dropped — covered by the Staff+
--    credential check (RLS) instead of tracking who.
--  - location_closures: created_by AND created_at dropped — the
--    closure's own `date` column already records which day is
--    blocked; no "who/when was this entered" trail is needed on
--    top of that.
--  - location_hours: created_at dropped (it never had created_by
--    to begin with) — same "no one needs to know when this row was
--    entered" reasoning; its own day_of_week/open_time/close_time
--    already say everything that matters.
--  - course_tier_mappings.created_by: dropped, same reasoning as
--    locations (Admin-only RLS covers it).
--
-- Also: academic_calendar.is_blocked dropped — every row in this
-- table represents a blocked date by definition, so the row's own
-- existence already carries the information; the flag was always
-- true in practice and never added anything.
-- ============================================================

alter table public.locations
  drop column created_by;

alter table public.location_closures
  drop column created_by,
  drop column created_at;

alter table public.location_hours
  drop column created_at;

alter table public.course_tier_mappings
  drop column created_by;

alter table public.academic_calendar
  drop column is_blocked;
