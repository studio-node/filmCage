-- ============================================================
-- Missing RLS policies on the rest of the tables the initial schema
-- migration flagged and deferred:
--   "Remaining tables (location_hours, location_closures, kit_items,
--    reservation_units, condition_reviews, checkout_sessions,
--    reservation_crew, reservation_assignments, student_notes) follow
--    the same two patterns above ... and are omitted here for length
--    — flag if you want them spelled out individually before this
--    ships."
--
-- condition_reviews was fixed separately (20260924020000) once it
-- actually broke something (Edit Items' condition-downgrade save).
-- These eight are the rest of that same list. Right now none of them
-- are exercised by anything built yet (My Reservations, Calendar,
-- Pickup/Return, crew assignment, and student notes/strikes are all
-- still "not yet built" per Build Status), so nothing is broken today
-- — but three of them (reservation_crew, reservation_assignments,
-- student_notes) never even had row level security enabled at all,
-- which is worse than locked: with RLS off, any authenticated user
-- currently has whatever access Supabase's default grants allow, with
-- nothing restricting it. Fixing all eight now, before any of them
-- carry real data or get hit by a real feature, rather than waiting
-- to discover each one the same way condition_reviews was found.
--
-- Same two patterns as the rest of the schema: general/reference data
-- is readable by everyone signed in; anything tied to a specific
-- reservation or student is readable by that student (or the staff
-- member directly on it) or Staff+; writes are Staff+ only, following
-- the schema comment's stated intent, since none of these have a
-- student-facing write path yet.
-- ============================================================

alter table public.reservation_crew enable row level security;
alter table public.reservation_assignments enable row level security;
alter table public.student_notes enable row level security;

-- location_hours / location_closures / kit_items: reference data,
-- same as locations/item_models/kits themselves — everyone signed in
-- can read it; only Staff+ can change it.
create policy location_hours_read_all on public.location_hours
  for select using (auth.role() = 'authenticated');
create policy location_hours_write_staff_up on public.location_hours
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

create policy location_closures_read_all on public.location_closures
  for select using (auth.role() = 'authenticated');
create policy location_closures_write_staff_up on public.location_closures
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

create policy kit_items_read_all on public.kit_items
  for select using (auth.role() = 'authenticated');
create policy kit_items_write_staff_up on public.kit_items
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- reservation_units: which physical unit is assigned to which
-- reservation. Readable by the reservation's own student or Staff+;
-- write stays Staff+ only — specific-unit assignment is deliberately
-- a staff/pickup-time step (see Build Status), not student-facing.
create policy reservation_units_read_own_or_staff on public.reservation_units
  for select using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_units.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_units_write_staff_up on public.reservation_units
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- checkout_sessions: a pickup/return signature step. Readable by
-- either party on it or Staff+; write is Staff+ only for now — once
-- Pickup/Return is actually built, the student confirming their own
-- signature will need its own narrower WITH CHECK (person_user_id =
-- auth.uid(), touching only person_signature/person_confirmed_at)
-- rather than opening the whole row to student writes.
create policy checkout_sessions_read_own_or_staff on public.checkout_sessions
  for select using (
    person_user_id = auth.uid()
    or staff_user_id = auth.uid()
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy checkout_sessions_write_staff_up on public.checkout_sessions
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- reservation_crew: who's on a reservation's crew. Readable by that
-- crew member, the reservation's own student, or Staff+; write is
-- Staff+ only for now — a student self-managing their own crew list
-- would need its own policy once that flow is built.
create policy reservation_crew_read_own_or_staff on public.reservation_crew
  for select using (
    user_id = auth.uid()
    or exists (
      select 1 from public.reservations r
      where r.id = reservation_crew.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_crew_write_staff_up on public.reservation_crew
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- reservation_assignments: which crew member is responsible for which
-- item model on a reservation. Same shape as reservation_crew.
create policy reservation_assignments_read_own_or_staff on public.reservation_assignments
  for select using (
    assigned_to_user_id = auth.uid()
    or exists (
      select 1 from public.reservations r
      where r.id = reservation_assignments.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_assignments_write_staff_up on public.reservation_assignments
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- student_notes: staff notes and strikes on a student's record.
-- Readable by that student (about themselves) or Staff+; write is
-- Staff+ only — students are never the author.
create policy student_notes_read_own_or_staff on public.student_notes
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy student_notes_write_staff_up on public.student_notes
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));
