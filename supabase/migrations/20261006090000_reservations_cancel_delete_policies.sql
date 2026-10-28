-- ============================================================
-- Supports the new Reservation Queue (staff+ approve/deny screen) and
-- a real "remove a reservation" path for every role, requested 10/6.
--
-- Two different operations, kept genuinely separate rather than
-- calling both "delete":
--
-- 1. CANCEL (status := 'cancelled') — available to the student who
--    owns the reservation, even once it's already approved/waitlisted/
--    awaiting a capstone appointment (life happens — plans change
--    after approval too, not just before it). Staff/supervisor/admin
--    already have unconditional update access via the existing
--    reservations_update_own_editable_or_staff policy, so no new
--    staff-side cancel policy is needed; this is purely about
--    widening what a STUDENT can still do to their own row once it's
--    past 'pending'.
--
-- 2. DELETE (real SQL delete, row gone) — staff/supervisor/admin
--    only, never students. reservation_items/reservation_crew/
--    reservation_assignments/reservation_units/return_item_statuses/
--    waitlist_entries/checkout_sessions all cascade automatically.
--    fines, condition_reviews, and recurring_reservation_occurrences
--    deliberately do NOT cascade (real financial/condition/scheduling
--    history shouldn't silently vanish) — deleting a reservation with
--    any of those attached fails with a foreign-key error, and the
--    Reservation Queue UI checks for this up front and steers staff
--    toward Cancel instead of attempting a delete that will fail.
--    notifications.related_reservation_id is different: a
--    notification is a disposable UI message, not a record worth
--    blocking a delete over, so its FK is changed to ON DELETE SET
--    NULL instead of the default RESTRICT.
--
-- A real bug caught during local validation of this same migration,
-- before it was ever pushed, worth explaining in full because it's a
-- genuinely subtle RLS composition trap: the first draft added the
-- cancel ability as ONLY a second, permissive UPDATE policy
-- (reservations_self_cancel) with a USING clause that opens up
-- already-approved/waitlisted rows to the owning student, and a WITH
-- CHECK that only allows the resulting status to be 'cancelled'.
-- That looks airtight in isolation, but Postgres combines MULTIPLE
-- permissive policies on the same command with OR — independently
-- for USING and for WITH CHECK, not as matched pairs. So a student's
-- update could satisfy USING via reservations_self_cancel's looser
-- old-row check (old status = 'approved' is allowed through) while
-- satisfying WITH CHECK via the UNRELATED main policy,
-- reservations_update_own_editable_or_staff, whose WITH CHECK (from
-- migration 14) only checks ownership and not-capstone — nothing
-- about the resulting status. Mix those two together and a student
-- could edit an already-approved reservation's actual dates (not just
-- cancel it), as long as the approval trigger's recomputed status
-- happened to land on a value that policy considered fine. Caught
-- this by testing the exact case: a student editing dropoff_date on
-- their own approved reservation went through and silently flipped it
-- back to pending, instead of being rejected.
--
-- RLS alone can't express "the only thing that's allowed to differ
-- is the status column, and only toward 'cancelled'" — USING only
-- sees the old row, WITH CHECK only sees the new one, and there's no
-- cross-policy way to pin them together once more than one permissive
-- policy exists for the same command. So the actual invariant is
-- enforced by a trigger instead (reservations_student_cancel_guard,
-- below), which has old and new in scope together: once a non-staff
-- actor's own reservation has moved past 'pending' into one of the
-- locked states, the trigger either (a) accepts a transition to
-- 'cancelled' and resets every other column back to its prior value
-- — so a cancel can never smuggle in an edit, regardless of what else
-- the client sent in the same statement — or (b) raises a clear
-- error if anything else was attempted. reservations_self_cancel
-- keeps its job narrow accordingly: it only has to make the row
-- reachable at all (RLS visibility), not enforce the fine-grained
-- "nothing else may change" rule — that's the trigger's job, and it
-- runs regardless of which RLS policy let the statement through.
-- ============================================================

create policy reservations_self_cancel on public.reservations
  for update
  using (
    student_id = auth.uid()
    and status not in ('active', 'completed', 'denied', 'cancelled')
  )
  with check (
    student_id = auth.uid()
    and status = 'cancelled'
  );

create or replace function public.reservations_student_cancel_guard()
returns trigger language plpgsql as $$
declare
  actor_is_staff boolean;
  locked_statuses reservation_status[] := array[
    'approved', 'waitlisted', 'waitlist_offered',
    'awaiting_appointment', 'awaiting_schedule'
  ]::reservation_status[];
begin
  actor_is_staff := public.current_user_role() in ('staff', 'supervisor', 'admin');
  if actor_is_staff then
    return new; -- staff edit freely; not this trigger's concern
  end if;

  if old.student_id <> auth.uid() then
    return new; -- not this student's own row
  end if;

  if old.status = any(locked_statuses) then
    if new.status = 'cancelled' then
      -- Cancelling is allowed even once locked, but nothing else may
      -- change in the same statement — reset every other column back
      -- to its prior value no matter what the client sent.
      new.reservation_name := old.reservation_name;
      new.location_id := old.location_id;
      new.is_capstone := old.is_capstone;
      new.capstone_appointment_date := old.capstone_appointment_date;
      new.appointment_completed := old.appointment_completed;
      new.pickup_date := old.pickup_date;
      new.pickup_time := old.pickup_time;
      new.dropoff_date := old.dropoff_date;
      new.dropoff_time := old.dropoff_time;
      new.scheduled := old.scheduled;
      new.is_group_reservation := old.is_group_reservation;
      new.allow_individual_pickup_times := old.allow_individual_pickup_times;
      new.denial_reason := old.denial_reason;
      new.admin_notes := old.admin_notes;
      new.approved_by := old.approved_by;
      new.approved_at := old.approved_at;
      new.is_personal_use := old.is_personal_use;
    else
      raise exception
        'This reservation is already % — only staff can change it further; you can still cancel it.',
        old.status;
    end if;
  end if;

  return new;
end;
$$;

create trigger reservations_student_cancel_guard
  before update on public.reservations
  for each row execute function public.reservations_student_cancel_guard();

create policy reservations_delete_staff on public.reservations
  for delete
  using (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
  );

alter table public.notifications
  drop constraint notifications_related_reservation_id_fkey;
alter table public.notifications
  add constraint notifications_related_reservation_id_fkey
  foreign key (related_reservation_id) references public.reservations(id)
  on delete set null;
