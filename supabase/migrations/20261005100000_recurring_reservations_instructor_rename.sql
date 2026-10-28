-- ============================================================
-- Rename the "professor" role to "class_instructor", and rename
-- recurring_reservations.professor_id to instructor_id to match.
--
-- Naming-only change, confirmed 10/4-10/5 during the schema review:
-- there's no full-time/part-time distinction in practice (see the
-- user_profiles merge migration — professor_profiles.employment_type
-- is retired, not carried over), just the role itself, so "class
-- instructor" better describes what the role actually means. The
-- enum rename is metadata-only (ALTER TYPE ... RENAME VALUE updates
-- every existing row's stored value automatically, no data rewrite
-- needed). professor_id -> instructor_id is a plain column rename;
-- its one RLS policy is dropped and recreated below so the policy
-- text itself stays accurate rather than relying on Postgres's
-- internal rename propagation.
-- ============================================================

alter type user_role rename value 'professor' to 'class_instructor';

alter table public.recurring_reservations
  rename column professor_id to instructor_id;

drop policy if exists recurring_reservations_own_or_staff on public.recurring_reservations;

-- recurring_reservations: a class instructor sees their own; Staff+ see and manage everything.
create policy recurring_reservations_own_or_staff on public.recurring_reservations
  for select using (
    instructor_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
