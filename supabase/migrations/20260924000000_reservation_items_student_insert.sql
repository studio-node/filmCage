-- ============================================================
-- Let a student add line items to their OWN still-editable
-- reservation.
--
-- Gap found while wiring up the real "Add to reservation" / "Join
-- waitlist" actions in Browse Equipment: reservations_insert_own_or_staff
-- already lets a student create the parent public.reservations row
-- (created_by = auth.uid()), but public.reservation_items only ever got
-- a SELECT policy (reservation_items_via_reservation) — the initial
-- migration's own comment flags this section as abbreviated ("flag if
-- you want them spelled out individually before this ships"). Without
-- an INSERT policy here, RLS default-denies every student write, so a
-- student could create an empty reservation but never say what
-- equipment it's for.
--
-- Mirrors the "editable" window already used by
-- reservations_update_own_editable_or_staff: a student may add items
-- to their own reservation as long as it isn't a capstone (capstone
-- line items go through the staff-run pre-pickup meeting instead) and
-- hasn't moved past pending/waitlisted/awaiting_* into a
-- staff-controlled status.
-- ============================================================
create policy reservation_items_insert_own on public.reservation_items
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

-- Same window for removing/adjusting a line item the student added
-- themselves, e.g. changing quantity before staff has acted on it.
create policy reservation_items_update_own on public.reservation_items
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

create policy reservation_items_delete_own on public.reservation_items
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
