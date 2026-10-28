-- ============================================================
-- Capstone appointment scheduling, requested 10/7.
--
-- Suzanne: capstone reservations should hold a tentative pickup date
-- that doesn't actually take effect until an admin signs off on the
-- capstone project at a pre-pickup meeting. Once that meeting is
-- marked done, EITHER the admin or the student can set (or confirm)
-- the real date, and from there it goes through the exact same
-- approval math as any other reservation -- auto-approved if nothing
-- is flagged, or into the normal Reservation Queue pending review if
-- something is (over 20 items, a Friday pickup/dropoff, under the
-- 3-day lead time, or past the 3-day loan window).
--
-- The schema already had everything this needs, sitting unused since
-- the very first migration: appointment_completed and scheduled
-- (both boolean, default false), and the awaiting_appointment /
-- awaiting_schedule enum values (with existing frontend display
-- labels already in ReservationQueueView.vue / MyReservationsView.vue).
-- reservations_approval_guard() (migration 13) has always short-
-- circuited every capstone UPDATE with "if new.is_capstone then
-- return new", so none of it ever actually moved. This migration is
-- the wiring, not new columns.
--
-- Lifecycle, entirely owned by reservations_approval_guard():
--   INSERT (capstone)       -> awaiting_appointment (a tentative
--                              pickup/dropoff date may already be on
--                              the row at this point -- see below --
--                              it just doesn't do anything yet)
--   appointment_completed   -> awaiting_schedule, once flipped true by
--   flips true, no date yet    staff (only staff may flip it -- see
--                              the column-pinning below)
--   a pickup_date exists AND
--   appointment_completed   -> the same item-count/Friday/lead-time/
--   is true                    loan-window math as every non-capstone
--                              reservation, landing on pending or
--                              approved
--
-- Because that recompute happens on *every* qualifying update, a
-- tentative date entered at creation (before the meeting) is simply
-- sitting on the row, inert, until the SAME update that marks the
-- meeting done -- at which point, if a date is already there, it's
-- evaluated immediately in that one statement. That's exactly "save
-- the date but don't let it go through until after the meeting,"
-- with zero extra columns or branches beyond what's described above.
--
-- Column-level security for the new self-service window (student
-- directly editing their own capstone row, something that was simply
-- impossible before this migration -- reservations_update_own_editable_or_staff,
-- migration 14, excludes every capstone row from student self-edit
-- outright):
--
-- A new, narrow RLS policy (reservations_capstone_self_schedule,
-- below) makes a capstone row reachable to its own student only while
-- status is awaiting_appointment or awaiting_schedule -- but RLS only
-- makes the ROW reachable, same lesson as users_self_update_guard,
-- reservations_student_cancel_guard, and reservation_crew_self_override_guard
-- elsewhere in this schema. The actual column-level rule --
-- "a student may only ever be proposing a pickup/dropoff date here,
-- never appointment_completed or anything administrative" -- is
-- enforced inside reservations_approval_guard() itself (it fires
-- first, alphabetically, before reservations_student_cancel_guard),
-- which pins every other column back to its prior value for a
-- non-staff actor, regardless of which policy let the statement
-- through.
--
-- That "regardless of which policy" qualifier matters concretely
-- here, not just in the abstract: Postgres combines multiple
-- permissive policies' USING/WITH CHECK clauses with OR, independently
-- of each other (the exact class of bug caught and documented in
-- migration 15). reservations_self_cancel's own USING is broader than
-- the new policy's and doesn't exclude capstone rows, so a student
-- could reach a capstone row through THAT policy's USING while
-- satisfying WITH CHECK through this migration's own, looser policy.
-- The trigger closes that regardless of entry path: once old.status
-- is no longer in the self-schedule window (because it's already
-- pending/approved), a non-staff, non-cancel edit gets every column
-- -- including the schedule ones -- reset back to its prior value,
-- full stop.
--
-- reservations_student_cancel_guard (migration 15) needed one small,
-- surgical addition rather than having awaiting_appointment/
-- awaiting_schedule removed from its locked_statuses array (the first
-- design considered, before thinking through the cancel path: a
-- student cancelling FROM one of those two statuses still needs that
-- trigger's full column-reset, same as cancelling from 'approved'
-- does -- removing them would have reopened exactly the smuggling
-- hole described above for a cancel-plus-edit sent in one statement).
-- So they stay locked, and the trigger instead gets a single new
-- carve-out: a non-cancel update that reservations_approval_guard
-- (firing first) has already recognized and fully pinned as a
-- legitimate capstone self-schedule move is let through rather than
-- rejected with "this reservation is already awaiting_appointment".
--
-- One more thing caught during local validation, before any of this
-- was ever pushed, and worth explaining because it would have quietly
-- defeated both the new status machine AND the column-pinning above:
-- reservations_approval_guard has, since migration 13, been attached
-- as "BEFORE INSERT OR UPDATE OF pickup_date, pickup_time, dropoff_date,
-- dropoff_time" -- a column-scoped trigger that only fires when one of
-- those four columns is actually in the UPDATE's SET list. That was
-- fine for its original, narrower job (recomputing approval status
-- when a schedule changes), but it means staff flipping
-- appointment_completed alone -- with no date in the same statement --
-- would never fire this trigger at all, so the row would never move
-- from awaiting_appointment to awaiting_schedule. Worse for security:
-- a student reaching their own capstone row through the new
-- self-schedule policy could update ANY other column (admin_notes,
-- reservation_name, ...) and, as long as they didn't also touch one of
-- those four date columns in the same statement, this trigger -- and
-- therefore every bit of the column-pinning described above -- simply
-- would not run, leaving RLS alone as the only defense. Confirmed by
-- testing exactly that: a student-only update of admin_notes went
-- through completely unpinned. Fixed by widening the trigger to fire
-- on every UPDATE, same as reservations_student_cancel_guard and
-- reservations_set_updated_at already do -- re-verified this doesn't
-- change non-capstone behavior, since every staff-owned terminal/queue
-- status there was already guarded by the untouchable_statuses check
-- regardless of which columns changed; the only new effect is a
-- harmless, idempotent re-evaluation of pending/approved when some
-- unrelated column is edited.
-- ============================================================

create or replace function public.reservations_approval_guard()
returns trigger language plpgsql as $$
declare
  item_count int;
  loan_days int;
  requires_approval boolean := false;
  holder_role user_role;
  actor_is_staff boolean;
  untouchable_statuses reservation_status[] := array[
    'denied', 'active', 'completed', 'cancelled',
    'waitlisted', 'waitlist_offered',
    'awaiting_appointment', 'awaiting_schedule'
  ]::reservation_status[];
  capstone_terminal_statuses reservation_status[] := array[
    'denied', 'active', 'completed', 'waitlisted', 'waitlist_offered'
  ]::reservation_status[];
begin
  if tg_op = 'INSERT' then
    if new.is_capstone then
      new.status := 'awaiting_appointment';
    else
      new.status := 'pending';
    end if;
    return new;
  end if;

  actor_is_staff := public.current_user_role() in ('staff','supervisor','admin');

  if new.is_capstone then
    if new.status = 'cancelled' then
      return new; -- reservations_student_cancel_guard (fires next) owns the column reset for this
    end if;

    if new.status = any(capstone_terminal_statuses) then
      return new; -- staff-owned terminal/queue state (denied, or later active/completed
                  -- from the Pickup/Return flow) -- not this trigger's business once there
    end if;

    if not actor_is_staff and old.student_id = auth.uid() then
      if old.status in ('awaiting_appointment', 'awaiting_schedule') then
        -- The one legitimate self-service move in this window: propose
        -- a pickup/drop-off date. Only staff may flip appointment_completed
        -- or touch anything administrative -- pin all of it back to its
        -- prior value no matter what the client sent in the same statement.
        new.reservation_name := old.reservation_name;
        new.location_id := old.location_id;
        new.is_capstone := old.is_capstone;
        new.student_id := old.student_id;
        new.is_group_reservation := old.is_group_reservation;
        new.allow_individual_pickup_times := old.allow_individual_pickup_times;
        new.is_personal_use := old.is_personal_use;
        new.denial_reason := old.denial_reason;
        new.admin_notes := old.admin_notes;
        new.approved_by := old.approved_by;
        new.approved_at := old.approved_at;
        new.appointment_completed := old.appointment_completed;
        new.capstone_appointment_date := old.capstone_appointment_date;
      else
        -- Already past the self-schedule window (pending/approved) --
        -- a non-cancel edit has no business reaching this row at all,
        -- no matter which policy let the UPDATE through. Reset
        -- everything, same discipline reservations_student_cancel_guard
        -- uses once locked.
        new.reservation_name := old.reservation_name;
        new.location_id := old.location_id;
        new.is_capstone := old.is_capstone;
        new.student_id := old.student_id;
        new.is_group_reservation := old.is_group_reservation;
        new.allow_individual_pickup_times := old.allow_individual_pickup_times;
        new.is_personal_use := old.is_personal_use;
        new.denial_reason := old.denial_reason;
        new.admin_notes := old.admin_notes;
        new.approved_by := old.approved_by;
        new.approved_at := old.approved_at;
        new.appointment_completed := old.appointment_completed;
        new.capstone_appointment_date := old.capstone_appointment_date;
        new.pickup_date := old.pickup_date;
        new.pickup_time := old.pickup_time;
        new.dropoff_date := old.dropoff_date;
        new.dropoff_time := old.dropoff_time;
        new.scheduled := old.scheduled;
        new.status := old.status;
        return new;
      end if;
    end if;

    if not new.appointment_completed then
      new.status := 'awaiting_appointment';
      return new;
    end if;

    if new.pickup_date is null then
      new.status := 'awaiting_schedule';
      return new;
    end if;

    -- The meeting is done and a real pickup date exists -- the exact
    -- same approval math as every non-capstone reservation, below.
    select coalesce(sum(quantity), 0) into item_count
      from public.reservation_items where reservation_id = new.id;

    if item_count > 20 then
      requires_approval := true;
    end if;

    if extract(isodow from new.pickup_date) = 5 then
      requires_approval := true; -- Friday pickup -- always requires approval, no exceptions
    end if;
    if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
      requires_approval := true; -- Friday drop-off -- always requires approval, no exceptions
    end if;

    select role into holder_role from public.users where id = new.student_id;
    if holder_role = 'student' and not actor_is_staff then
      if new.pickup_date < current_date + 3 then
        requires_approval := true; -- under the 3-day minimum lead time
      end if;
      if new.dropoff_date is not null then
        loan_days := new.dropoff_date - new.pickup_date;
        if loan_days > 3 then
          requires_approval := true; -- past the default 3-day loan window
        end if;
      end if;
    end if;

    new.scheduled := true;
    if requires_approval then
      new.status := 'pending';
    else
      new.status := 'approved';
    end if;
    return new;
  end if;

  -- ---- non-capstone branch: unchanged from migration 13 ----
  select coalesce(sum(quantity), 0) into item_count
    from public.reservation_items where reservation_id = new.id;

  if item_count > 20 then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 then
    requires_approval := true; -- Friday pickup -- always requires approval, no exceptions
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
    requires_approval := true; -- Friday drop-off -- always requires approval, no exceptions
  end if;

  select role into holder_role from public.users where id = new.student_id;

  if holder_role = 'student' and not actor_is_staff then
    if new.pickup_date is not null and new.pickup_date < current_date + 3 then
      requires_approval := true; -- under the 3-day minimum lead time
    end if;

    if new.pickup_date is not null and new.dropoff_date is not null then
      loan_days := new.dropoff_date - new.pickup_date;
      if loan_days > 3 then
        requires_approval := true; -- past the default 3-day loan window
      end if;
    end if;
  end if;

  if new.status = any(untouchable_statuses) then
    return new; -- not this trigger's status to manage
  end if;

  if requires_approval then
    new.status := 'pending';
  else
    new.status := 'approved'; -- the missing branch -- see migration 13's header
  end if;

  return new;
end;
$$;

-- Widened from migration 13's column-scoped version ("UPDATE OF
-- pickup_date, pickup_time, dropoff_date, dropoff_time") to fire on
-- every UPDATE -- see the migration header for why: appointment_completed
-- (and, in principle, any other column a student might touch on their
-- own capstone row) has to reach this function too, both so the
-- status machine above actually advances and so the column-pinning
-- security actually runs regardless of which column changed.
create or replace trigger reservations_approval_guard
  before insert or update on public.reservations
  for each row execute function public.reservations_approval_guard();

-- Let a capstone reservation's own student reach it -- impossible
-- before this migration, since reservations_update_own_editable_or_staff
-- (migration 14) excludes every capstone row from student self-edit.
-- Confined to the window where self-scheduling is actually meaningful;
-- reservations_approval_guard (above) owns the real column-level
-- enforcement regardless of which policy lets the statement through
-- (see the migration header for why that qualifier matters).
create policy reservations_capstone_self_schedule on public.reservations
  for update
  using (
    student_id = auth.uid()
    and is_capstone
    and status in ('awaiting_appointment', 'awaiting_schedule')
  )
  with check (
    student_id = auth.uid()
    and is_capstone
  );

-- One small, surgical addition rather than removing awaiting_appointment/
-- awaiting_schedule from locked_statuses -- see the migration header for
-- why a student's CANCEL from one of those two statuses still needs this
-- trigger's full column-reset, same as cancelling from 'approved' does.
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
    elsif old.is_capstone and old.status in ('awaiting_appointment', 'awaiting_schedule') then
      -- A capstone row's own student-self-schedule move (setting a
      -- pickup/dropoff date, or staff having just marked the meeting
      -- done) -- reservations_approval_guard, firing first, has
      -- already fully computed and column-pinned this; it's not this
      -- trigger's concern.
      return new;
    else
      raise exception
        'This reservation is already % — only staff can change it further; you can still cancel it.',
        old.status;
    end if;
  end if;

  return new;
end;
$$;

-- Let the student know they can now set a date, once staff marks the
-- pre-pickup meeting done. pre_meeting_completed has sat unused in
-- notification_type since the very first migration, same pattern as
-- crew_invitation (migration 18).
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
        'Your capstone meeting for "%s" has been marked complete. You can now set (or confirm) your pickup/drop-off date in My Reservations.',
        coalesce(new.reservation_name, 'your capstone reservation')
      ),
      new.id
    );
  end if;
  return new;
end;
$$;
create trigger reservation_capstone_notify_meeting_done
  after update on public.reservations
  for each row execute function public.reservation_capstone_notify_meeting_done();
