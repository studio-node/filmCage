-- ============================================================
-- Group reservations: a producer couldn't actually edit their own
-- crew list or equipment assignments after creation at all.
--
-- Suzanne's report (10/28): editing a group reservation under normal
-- circumstances (doesn't need approval, or approval hasn't been given
-- yet) only shows the ability to add equipment -- no way to edit crew
-- or assign/deassign equipment to people. Confirmed by reading the
-- actual policies, not guessed: this is TWO real, pre-existing gaps,
-- both dating back to migration 12 (reservation_crew_student_insert,
-- 10/5) and never touched since, even as the equivalent
-- reservation_items/reservations policies were fixed twice over
-- (migration 20 dropped the capstone exclusion; migration 21 added
-- the auto-approved-stays-editable carve-out):
--
--   1. reservation_crew_insert_own / _update_own / _delete_own and
--      reservation_assignments_insert_own / _update_own / _delete_own
--      all still hard-exclude `is_capstone` (migration 22 already
--      unified capstone onto the exact same approval path -- this
--      exclusion is now just stale and inconsistent, not special-case
--      correct), and all still hard-exclude `status = 'approved'`
--      with no carve-out for the auto-approved case at all (migration
--      21's `approved_by is null` fix only ever touched
--      reservations/reservation_items, never these two tables). That
--      second gap is the one actually matching Suzanne's report: the
--      *common* case -- a group reservation that auto-approved
--      because nothing tripped the business rules -- landed on
--      `approved` with `approved_by is null`, and these policies read
--      that exactly the same as a manually-approved, genuinely-locked
--      row. A still-`pending` reservation (approval not yet given)
--      was never actually blocked by RLS -- that half of Suzanne's
--      report is purely a frontend gap, fixed in the same pass by
--      actually building the UI (no migration needed for that half).
--
--   2. reservation_crew_write_staff_up / reservation_assignments_write_staff_up
--      (migration from 9/24, predates the self-edit-lock concept
--      entirely) grant staff+ unconditional write access with no
--      status restriction and no self-exclusion at all -- the exact
--      gap reservation_items_staff_write (migration 21) already
--      closed for items, just never carried over to these two tables.
--      Left as-is, a staff member could use their own staff-role
--      access to edit crew/assignments on their OWN manually-approved
--      reservation (bypassing the lock), or on ANY reservation's crew/
--      assignments even once it's active/completed/cancelled, when
--      editing has stopped meaning anything. Fixed with the exact
--      same shape as reservation_items_staff_write: an explicit
--      status allow-list (pending/approved/denied/waitlisted) plus
--      `r.student_id is distinct from auth.uid()`.
-- ============================================================

-- ---- 1. self-own policies: drop the stale capstone exclusion, add the
-- ---- auto-approved carve-out -- mirrors reservation_items_*_own exactly

alter policy reservation_crew_insert_own on public.reservation_crew
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

alter policy reservation_crew_update_own on public.reservation_crew
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

alter policy reservation_crew_delete_own on public.reservation_crew
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

alter policy reservation_assignments_insert_own on public.reservation_assignments
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

alter policy reservation_assignments_update_own on public.reservation_assignments
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

alter policy reservation_assignments_delete_own on public.reservation_assignments
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and (
          r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
          or (r.status = 'approved' and r.approved_by is null)
        )
    )
  );

-- ---- 2. staff+ write policies: status allow-list + self-exclusion,
-- ---- mirrors reservation_items_staff_write exactly

alter policy reservation_crew_write_staff_up on public.reservation_crew
  using (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  )
  with check (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  );

alter policy reservation_assignments_write_staff_up on public.reservation_assignments
  using (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  )
  with check (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  );
