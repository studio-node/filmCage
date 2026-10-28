-- ============================================================
-- reservation_crew / reservation_assignments currently only have a
-- Staff+ "for all" write policy — a student building their own group
-- (crew) reservation on the new front-end Reservations tab has no way
-- to add crew members or assign items to them at all, since RLS
-- blocks the insert outright. This adds a student-owns-it insert/
-- update/delete policy, mirroring reservation_items_insert_own /
-- _update_own / _delete_own exactly: same reservation, same student,
-- same "not capstone and still in an editable status" window. The
-- existing Staff+ "for all" policy is untouched and keeps working
-- (permissive policies on the same command OR together).
-- ============================================================

create policy reservation_crew_insert_own on public.reservation_crew
  for insert
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy reservation_crew_update_own on public.reservation_crew
  for update
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy reservation_crew_delete_own on public.reservation_crew
  for delete
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy reservation_assignments_insert_own on public.reservation_assignments
  for insert
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy reservation_assignments_update_own on public.reservation_assignments
  for update
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy reservation_assignments_delete_own on public.reservation_assignments
  for delete
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );
