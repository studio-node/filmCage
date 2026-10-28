-- ============================================================
-- Capstone policy change, confirmed 10/21: the client now wants a
-- capstone student to pick a tentative pickup/drop-off date (and the
-- pre-pickup meeting date) together, at creation time -- "handle the
-- items as if they were a regular reservation with all of the regular
-- reservation approved [rules], except the ones that trigger an
-- approval." Concretely, confirmed point by point:
--
--  1. Capstone now runs through the EXACT SAME approval math as any
--     other reservation -- item-count>20, both Friday checks, the
--     hard inventory check, the v_bypass staff-on-someone-else
--     exemption, the class_instructor lead-time/loan-window exemption
--     -- with exactly one difference: capstone's lead-time threshold
--     is 7 days instead of 3 ("leadtime needs to be 7 days, not 3").
--     Loan window stays 3 days for everyone -- only lead time was
--     called out as different. reservations_approval_guard()'s two
--     parallel branches (capstone / non-capstone) are collapsed into
--     one, parameterized by v_lead_time_days.
--
--  2. The old awaiting_appointment -> awaiting_schedule two-step
--     (meeting first, real pickup/drop-off date only after) is gone
--     for new capstone reservations. INSERT now sets 'pending'
--     unconditionally, same as a regular reservation -- the app
--     collects pickup/drop-off dates AND the appointment date in the
--     same submission, then issues the same deliberate follow-up
--     UPDATE (touching pickup_date as a no-op) that a regular
--     reservation already uses to re-fire the real business-rule
--     evaluation once reservation_items exist.
--
--  3. The pre-pickup meeting survives, but purely as an informational
--     flag -- capstone_appointment_date / appointment_completed keep
--     their columns and their staff-only write rule, but neither one
--     gates status or approval in any way any more. Confirmed: "keep
--     it, but purely informational." Staff can mark it complete
--     whenever, independent of the reservation's status.
--
--  4. Once approved, a capstone reservation's pickup/drop-off window
--     is immediately final, exactly like a regular reservation --
--     confirmed "yes, it's final immediately," no separate "set the
--     real schedule after the meeting" step. Later changes are just
--     ordinary self-edits, subject to the same approved_by lock as
--     everyone else.
--
-- Two things fall out of unifying the branches, not asked for
-- directly but required to make #1-#4 actually true:
--
--  a. reservations_update_own_editable_or_staff (the main self-edit
--     RLS policy on reservations) has excluded every capstone row
--     from student self-edit, via `and (not is_capstone)`, since
--     migration 20261007130000. That exclusion must come off, or a
--     capstone student can never reach their own row through the
--     main policy at all -- confirmed capstone is meant to be
--     editable exactly like a regular reservation now (subject to the
--     same approved-by-staff lock), not specially walled off.
--
--  b. reservations_capstone_self_schedule (same migration) was the
--     RLS policy that used to let a capstone student reach their own
--     row ONLY during the old awaiting_appointment/awaiting_schedule
--     window -- its WITH CHECK is simply `student_id = auth.uid() and
--     is_capstone`, with no status restriction at all. Once (a)'s
--     exclusion comes off, this policy becomes redundant AND a live
--     security hole: multiple permissive RLS policies on the same
--     table combine via OR, independently for USING and WITH CHECK
--     (the repeatedly-bitten-by lesson in this schema's history) --
--     leaving this one in place would let a capstone student satisfy
--     USING through the main policy's status-gated condition and
--     WITH CHECK through this policy's unconditional one, smuggling a
--     write past the main policy's own lock. It must be dropped
--     outright, not just left inert.
--
-- Also folded in, both required for #2/#3 to hold together cleanly
-- rather than leaving dead branches that could misfire on an old row:
--
--  c. Every existing reservation still sitting in 'awaiting_appointment'
--     or 'awaiting_schedule' (created before this migration, under the
--     old two-step) is moved straight to 'pending' below, with the
--     approval trigger disabled for that one statement -- running it
--     through the trigger's normal logic would wrongly auto-approve a
--     row that has no pickup_date yet (the new unified branch no
--     longer treats "no pickup_date" as its own holding state the way
--     the old capstone branch did). Landing on 'pending' puts these
--     rows in front of staff in the Reservation Queue, now fully
--     editable there (point (a) above) so staff can set a real
--     pickup/drop-off date, which re-fires the real evaluation
--     correctly once a date exists.
--
--  d. reservations_student_cancel_guard()'s awaiting_appointment/
--     awaiting_schedule handling is now dead code once (c) has run --
--     no reservation will reach either status again -- so it's
--     removed rather than left as a trap for some future status this
--     schema might reuse those values for. Cancelling a capstone
--     reservation now follows the exact same locked_statuses path a
--     regular reservation already uses.
--
--  e. reservation_capstone_notify_meeting_done()'s notification text
--     told the student they could "now set (or confirm)" a pickup/
--     drop-off date once the meeting was marked done -- no longer
--     true, since the date is set at creation and the meeting doesn't
--     unlock anything any more. Reworded to a plain confirmation.
--
-- Frontend half of this change (NewReservationView.vue collecting both
-- dates together with a 7-day capstone lead-time hint;
-- ReservationQueueView.vue/MyReservationsView.vue/ReservationDetailView.vue
-- dropping the old scheduling mini-forms for a status-independent
-- informational line, and a visually distinct capstone Approve button)
-- ships alongside this migration, not here.
-- ============================================================

-- --- 0. backfill: move every reservation still parked in one of the --
-- retired two-step statuses straight to 'pending', bypassing the
-- approval trigger for this one statement -- see (c) above for why
-- letting the new trigger logic touch these (with pickup_date still
-- null for most of them) would be wrong.
alter table public.reservations disable trigger reservations_approval_guard;

update public.reservations
set status = 'pending'
where status in ('awaiting_appointment', 'awaiting_schedule');

alter table public.reservations enable trigger reservations_approval_guard;

-- --- 1. reservations_approval_guard(): capstone and non-capstone -------
-- branches collapsed into one, parameterized by v_lead_time_days. See
-- the migration header, points 1-2.
create or replace function public.reservations_approval_guard()
returns trigger language plpgsql as $$
declare
  item_count int;
  loan_days int;
  requires_approval boolean := false;
  holder_role user_role;
  actor_is_staff boolean;
  v_bypass boolean;
  v_lead_time_days int;
  untouchable_statuses reservation_status[] := array[
    'denied', 'active', 'completed', 'cancelled',
    'waitlisted', 'waitlist_offered'
  ]::reservation_status[];
begin
  if tg_op = 'INSERT' then
    new.status := 'pending';
    return new;
  end if;

  actor_is_staff := public.current_user_role() in ('staff','supervisor','admin');
  v_bypass := actor_is_staff and new.student_id is distinct from auth.uid();

  -- active/completed/cancelled are locked for everyone, no exceptions
  -- -- unchanged from 20261019120000, applies identically to capstone
  -- now that there's only one branch.
  if old.status = any(array['active','completed','cancelled']::reservation_status[]) then
    raise exception 'This reservation is % and can no longer be changed.', old.status;
  end if;

  -- once a reservation that needed real review has been manually
  -- approved (approved_by is not null), its own holder can no longer
  -- edit it at all -- unchanged, and now covers capstone too (point 4
  -- in the header: a capstone reservation's window is immediately
  -- final on approval, exactly like this rule already made a regular
  -- reservation's).
  if new.student_id = auth.uid()
     and old.status = 'approved' and old.approved_by is not null
     and new.status is distinct from 'cancelled'
  then
    raise exception 'This reservation was manually approved -- ask another staff member, a supervisor, or an admin to make further changes.';
  end if;

  -- a plain `staff` actor can never approve or deny their own --
  -- unchanged.
  if new.status is distinct from old.status and new.status in ('approved', 'denied') then
    if public.current_user_role() = 'staff' and new.student_id = auth.uid() then
      raise exception 'You cannot approve or deny your own reservation -- ask another staff member, a supervisor, or an admin.';
    end if;
  end if;

  -- denial requires a reason -- unchanged, still runs before the
  -- untouchable_statuses early return since 'denied' is itself in it.
  if new.status = 'denied' and new.status is distinct from old.status then
    if new.denial_reason is null or btrim(new.denial_reason) = '' then
      raise exception 'A reason is required to deny a reservation.';
    end if;
  end if;

  select coalesce(sum(quantity), 0) into item_count
    from public.reservation_items where reservation_id = new.id;

  if item_count > 20 and not v_bypass then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 and not v_bypass then
    requires_approval := true;
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 and not v_bypass then
    requires_approval := true;
  end if;

  select role into holder_role from public.users where id = new.student_id;

  -- *** NEW: the one real difference between capstone and a regular
  -- reservation -- see point 1 in the header. Loan window stays 3
  -- days for both; only lead time changes.
  v_lead_time_days := case when new.is_capstone then 7 else 3 end;

  if not (v_bypass or holder_role = 'class_instructor') then
    if new.pickup_date is not null and new.pickup_date < current_date + v_lead_time_days then
      requires_approval := true;
    end if;

    if new.pickup_date is not null and new.dropoff_date is not null then
      loan_days := new.dropoff_date - new.pickup_date;
      if loan_days > 3 then
        requires_approval := true;
      end if;
    end if;
  end if;

  if new.status = any(untouchable_statuses) then
    return new; -- not this trigger's status to manage -- also the
                -- escape hatch that lets an explicit write of
                -- 'waitlisted'/'denied'/'cancelled'/etc. through
                -- without ever reaching the inventory check below.
  end if;

  -- hard inventory check -- never bypassed, for anyone, capstone or
  -- not, same as every prior pass on this function.
  if new.pickup_date is not null then
    perform public.assert_reservation_items_available(
      new.id,
      new.pickup_date + coalesce(new.pickup_time, '00:00'::time),
      coalesce(new.dropoff_date, new.pickup_date) + coalesce(new.dropoff_time, new.pickup_time, '00:00'::time)
    );
  end if;

  if requires_approval then
    new.status := 'pending';
  else
    new.status := 'approved';
  end if;

  return new;
end;
$$;

-- --- 2. drop the now-redundant-and-unsafe capstone self-schedule -------
-- policy -- see (b) in the header for why this can't just be left
-- inert once point 3 below removes the main self-edit policy's
-- capstone exclusion.
drop policy if exists reservations_capstone_self_schedule on public.reservations;

-- --- 3. widen the main self-edit policy so a capstone row is ----------
-- reachable to its own student the same way a regular row already is
-- -- see (a) in the header. reservations_approval_guard (above) is
-- still what actually decides what's allowed to change, identically
-- for both reservation types -- this just restores row reachability.
alter policy reservations_update_own_editable_or_staff on public.reservations
  using (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (
        status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
        or (status = 'approved' and approved_by is null)
      )
    )
  )
  with check (
    public.current_user_role() in ('staff','supervisor','admin')
    or student_id = auth.uid()
  );

-- --- 4. reservations_student_cancel_guard(): drop the retired -----------
-- awaiting_appointment/awaiting_schedule handling -- see (d) in the
-- header. Capstone cancellation now follows the exact same path a
-- regular reservation already uses.
create or replace function public.reservations_student_cancel_guard()
returns trigger language plpgsql as $$
declare
  actor_is_staff boolean;
  locked_statuses reservation_status[] := array[
    'approved', 'waitlisted', 'waitlist_offered'
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
      -- change in the same statement -- reset every other column back
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

-- --- 5. reservation_capstone_notify_meeting_done(): reword the ---------
-- notification -- see (e) in the header. Marking the meeting complete
-- no longer unlocks anything for the student to do.
create or replace function public.reservation_capstone_notify_meeting_done()
returns trigger security definer language plpgsql as $$
begin
  if new.is_capstone and new.appointment_completed and not old.appointment_completed then
    insert into public.notifications (user_id, type, title, body, related_reservation_id)
    values (
      new.student_id,
      'pre_meeting_completed',
      'Capstone meeting marked complete',
      format(
        'Your pre-pickup meeting for "%s" has been marked complete.',
        coalesce(new.reservation_name, 'your capstone reservation')
      ),
      new.id
    );
  end if;
  return new;
end;
$$;
