-- ============================================================
-- Reservation Queue / My Reservations rebuild, confirmed across many
-- rounds the week of 10/19. This migration is the database half of
-- that feature -- new policies and trigger logic only. The two Vue
-- views are rewritten separately to use what this adds.
--
-- What's covered here, each matching a specific confirmed rule:
--
--  1. reservation_items gets its first staff+ WRITE policies (insert/
--     update/delete). Today staff+ can already SELECT any item row
--     (reservation_items_via_reservation) but there was never a write
--     policy for them -- only the student-owns-it ones. Staff/admin
--     may now add or remove items on any reservation whose status is
--     pending, approved, denied, or waitlisted -- never active,
--     cancelled, or completed, matching "This will exclude again
--     cancelled, completed, or active reservations."
--
--  2. reservations_approval_guard() is restructured (create or
--     replace, same function, nothing else touches it):
--
--     a. NEW: active/completed/cancelled are now fully locked for
--        EVERY actor, staff and admin included -- "You should not be
--        able to edit or change or cancel or delete any items that
--        are active, cancelled, or completed." Today's RLS
--        (reservations_update_own_editable_or_staff, migration 14)
--        already gives staff+ unconditional UPDATE access to any row
--        with no status restriction at all, so this can only be
--        enforced here, in the trigger -- RLS alone can't express it
--        (the lesson from every prior pass on this table: RLS gives
--        reachability, the trigger decides what's actually allowed to
--        change).
--
--     b. NEW: a plain `staff` actor can never approve or deny their
--        own personal reservation -- raises outright. Supervisor and
--        admin CAN self-approve/deny ("supervisor can self approve
--        since they are only assigned supervisor role when acting
--        admin is unavailable"). This is the real enforcement; the
--        Reservation Queue UI additionally keeps a staff member's own
--        pending reservation out of their own Pending Approval list
--        for cleanliness, but this guard is what actually can't be
--        bypassed by calling the update directly.
--
--     c. NEW: denying now requires a non-empty denial_reason at the
--        database level, not just the client-side check already in
--        ReservationQueueView -- "with a forced reason for deny",
--        confirmed this applies to a supervisor/admin self-deny too.
--        Placed before the untouchable_statuses early-return, since
--        'denied' is itself in that array and would otherwise skip
--        validation entirely.
--
--     d. CHANGED bypass shape. Today: item-count>20 and the two
--        Friday checks are unconditional for literally everyone;
--        lead-time and loan-window are skipped whenever
--        holder_role <> 'student' OR the actor is staff+ (so a staff
--        member's own personal reservation was already fully exempt
--        from lead-time/loan-window, just by virtue of their own role
--        being the holder_role). New shape, confirmed point by point:
--          - v_bypass := actor is staff+ AND editing someone else's
--            reservation (new.student_id is distinct from auth.uid()).
--            This is the one bypass flag staff+ now gets, and ONLY
--            when acting on someone else's row -- "A student has the
--            ability to edit their reservation, but it always needs
--            to go through all the checks... that is only on the
--            student role" turned out, after the my-reservations
--            round, to mean literally everyone's OWN edits get full
--            checks, staff/supervisor/admin included; the staff+
--            bypass is strictly about acting on someone else's.
--          - item-count>20 and both Friday checks: now skipped when
--            v_bypass, otherwise unconditional for everyone exactly
--            as today (Friday was never meant to be exempted: "Friday
--            pickup still always forces approval... It's a staffing
--            constraint, not a trust judgment" -- that reasoning only
--            ever covered the *lead-time/loan-window* checks, not
--            Friday or item-count, until this round's staff-bypass
--            request, which is why Friday/item-count now join the
--            bypass set for v_bypass specifically, but still only for
--            v_bypass).
--          - lead-time and loan-window: skipped when
--            v_bypass OR holder_role = 'class_instructor'. The old
--            generic "any non-student holder is exempt" is gone --
--            dropped specifically because it used to also exempt a
--            staff/supervisor/admin holder's OWN reservation, which
--            the new rule says must face full checks. The
--            class_instructor leg is preserved byte-for-byte on
--            purpose: "Lets leave it alone today, and I'll clarify
--            that behavior after I meet with the client today" --
--            instructors still get exactly today's exemption, nothing
--            added, nothing removed, and they are NOT added to the
--            Friday/item-count bypass (explicitly "still fully subject
--            to Friday/item-count, unchanged").
--        The hard inventory check (assert_reservation_items_available,
--        migration 20) is untouched by any of this -- never bypassed
--        for anyone, exactly as confirmed: "it should not bypass if
--        the item is not available due to inventory not available in
--        the new time slot."
--
--  3. NEW, found while validating this migration locally (not part of
--     the original design discussion, but required by it): the
--     existing self-edit RLS on both reservations and
--     reservation_items hard-excludes 'approved' entirely, with no
--     carve-out for approved_by IS NULL. That directly breaks the
--     confirmed My Reservations rule -- "A reservation that was auto-
--     approved (never flagged) remains normally self-editable" --
--     today a student literally cannot touch their own auto-approved
--     reservation at all, items or dates, via RLS. Four existing
--     policies get an `or (status = 'approved' and approved_by is
--     null)` carve-out added to their self-ownership condition:
--     reservations_update_own_editable_or_staff, and
--     reservation_items_update_own/_insert_own/_delete_own. No change
--     to how a MANUALLY approved reservation behaves -- approved_by is
--     not null still excludes it from every one of these, exactly as
--     today, which is what makes the lock-after-manual-approval rule
--     actually enforceable at the database level rather than just in
--     the UI.
--
--  4. A new notification fires to the student whenever staff/admin
--     changes something on THEIR reservation -- pickup/dropoff
--     details, or the item list -- mirroring the existing
--     reservation_crew_notify_invite pattern (AFTER trigger,
--     SECURITY DEFINER, skip when the actor is the row's own owner).
--     A new notification_type value (reservation_updated_by_staff) is
--     added since none of the existing ones fit "staff changed your
--     reservation" specifically. The item-list trigger only fires for
--     an UPDATE or DELETE on reservation_items unconditionally, and
--     for an INSERT only once the parent reservation is more than 30
--     seconds old -- otherwise staff building a brand-new reservation
--     on someone else's behalf from NewReservationView (a real,
--     already-shipped flow: isStaffPlus + targetUser) would fire one
--     notification per line item on simple creation, which was never
--     what this rule was asking for ("whenever staff or admin makes a
--     change" means an edit to something that already existed).
--
-- Deliberately NOT in this migration, both on hold pending Suzanne's
-- client conversation:
--  - Whether only admin (not staff) should be able to touch an
--    *active* reservation at all -- moot for now anyway, since
--    nothing before the future Pickup/Return phase ever sets a
--    reservation to 'active', and the new lock in 2a already blocks
--    editing one regardless of role once something does.
--  - Any change to the class_instructor lead-time/loan-window
--    exemption's own behavior -- preserved exactly as it stands
--    today, per "leave it alone today."
-- ============================================================

-- --- 1. staff+ write access to reservation_items ------------------------
-- Scoped to someone ELSE's reservation (r.student_id is distinct from
-- auth.uid()), same as the v_bypass identity check added to
-- reservations_approval_guard() below -- without that, a staff member
-- could use this policy on their OWN reservation to end-run the
-- approved_by self-edit lock (point 3 above), since this policy
-- doesn't care about approved_by at all. Their own pending/waitlisted/
-- auto-approved items are already reachable through the ordinary
-- self-ownership policies; their own denied or manually-approved
-- items are correctly left locked, same as editing the reservation
-- row itself.
create policy reservation_items_staff_write on public.reservation_items
  for all
  using (
    public.current_user_role() in ('staff','supervisor','admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  )
  with check (
    public.current_user_role() in ('staff','supervisor','admin')
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.status in ('pending', 'approved', 'denied', 'waitlisted')
        and r.student_id is distinct from auth.uid()
    )
  );

-- --- 2. new notification_type value --------------------------------------
alter type notification_type add value if not exists 'reservation_updated_by_staff';

-- --- 3. the restructured approval guard ----------------------------------
create or replace function public.reservations_approval_guard()
returns trigger language plpgsql as $$
declare
  item_count int;
  loan_days int;
  requires_approval boolean := false;
  holder_role user_role;
  actor_is_staff boolean;
  v_bypass boolean;
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
  v_bypass := actor_is_staff and new.student_id is distinct from auth.uid();

  -- *** NEW: active/completed/cancelled are locked for everyone, no
  -- exceptions -- see 2a above. Checked before anything else, capstone
  -- or not, so nothing downstream (including staff's otherwise-
  -- unconditional RLS access) can touch a row in one of these statuses
  -- again.
  if old.status = any(array['active','completed','cancelled']::reservation_status[]) then
    raise exception 'This reservation is % and can no longer be changed.', old.status;
  end if;

  -- *** NEW: once a reservation that needed real review has been
  -- manually approved (approved_by is not null), its own holder can no
  -- longer edit it at all, through either screen -- "once approval is
  -- given, no one will have the ability to edit in any way through
  -- the my reservation screen," and staff can't end-run that by using
  -- the Queue's edit feature on their own row either, since there is
  -- no DB-level way to tell those two screens apart -- only identity
  -- (self vs. someone else) is visible here. An auto-approved
  -- reservation (approved_by is null) is NOT affected -- "a reservation
  -- that was auto-approved... remains normally self-editable," which
  -- is exactly why this checks approved_by and not just status =
  -- 'approved'. Cancelling is explicitly carved out -- a reservation's
  -- own holder can still cancel it even once manually approved
  -- (reservations_self_cancel / migration 10/6's own rule, unchanged),
  -- just not edit it.
  if new.student_id = auth.uid()
     and old.status = 'approved' and old.approved_by is not null
     and new.status is distinct from 'cancelled'
  then
    raise exception 'This reservation was manually approved -- ask another staff member, a supervisor, or an admin to make further changes.';
  end if;

  -- *** NEW: a plain staff actor can never approve or deny their own
  -- reservation -- see 2b above. Supervisor/admin are unaffected.
  if new.status is distinct from old.status and new.status in ('approved', 'denied') then
    if public.current_user_role() = 'staff' and new.student_id = auth.uid() then
      raise exception 'You cannot approve or deny your own reservation -- ask another staff member, a supervisor, or an admin.';
    end if;
  end if;

  -- *** NEW: denial requires a reason, for anyone, including a
  -- supervisor/admin self-deny -- see 2c above. Must run before the
  -- untouchable_statuses / capstone_terminal_statuses early returns
  -- below, since 'denied' is itself one of those statuses.
  if new.status = 'denied' and new.status is distinct from old.status then
    if new.denial_reason is null or btrim(new.denial_reason) = '' then
      raise exception 'A reason is required to deny a reservation.';
    end if;
  end if;

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

    select coalesce(sum(quantity), 0) into item_count
      from public.reservation_items where reservation_id = new.id;

    if item_count > 20 and not v_bypass then
      requires_approval := true;
    end if;

    if extract(isodow from new.pickup_date) = 5 and not v_bypass then
      requires_approval := true;
    end if;
    if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 and not v_bypass then
      requires_approval := true;
    end if;

    select role into holder_role from public.users where id = new.student_id;
    if not (v_bypass or holder_role = 'class_instructor') then
      if new.pickup_date < current_date + 3 then
        requires_approval := true;
      end if;
      if new.dropoff_date is not null then
        loan_days := new.dropoff_date - new.pickup_date;
        if loan_days > 3 then
          requires_approval := true;
        end if;
      end if;
    end if;

    -- hard inventory check -- never bypassed, for anyone, same point as
    -- the policy checks just above.
    perform public.assert_reservation_items_available(
      new.id,
      new.pickup_date + coalesce(new.pickup_time, '00:00'::time),
      coalesce(new.dropoff_date, new.pickup_date) + coalesce(new.dropoff_time, new.pickup_time, '00:00'::time)
    );

    new.scheduled := true;
    if requires_approval then
      new.status := 'pending';
    else
      new.status := 'approved';
    end if;
    return new;
  end if;

  -- ---- non-capstone branch ----
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

  if not (v_bypass or holder_role = 'class_instructor') then
    if new.pickup_date is not null and new.pickup_date < current_date + 3 then
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

  -- hard inventory check -- never bypassed, for anyone, same point as
  -- the policy checks just above.
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

-- --- 4. staff+ editing the reservation's own date/time columns on ------
-- someone else's reservation notifies that student. AFTER so it only
-- fires once the row has actually committed to its new values.
create or replace function public.reservations_staff_edit_notify()
returns trigger security definer language plpgsql set search_path = public as $$
begin
  if public.current_user_role() not in ('staff','supervisor','admin') then
    return new;
  end if;

  if new.student_id is null or new.student_id = auth.uid() then
    return new; -- self-edit, not "staff changed someone else's reservation"
  end if;

  if new.pickup_date is distinct from old.pickup_date
     or new.pickup_time is distinct from old.pickup_time
     or new.dropoff_date is distinct from old.dropoff_date
     or new.dropoff_time is distinct from old.dropoff_time
  then
    insert into public.notifications (user_id, type, title, body, related_reservation_id)
    values (
      new.student_id, 'reservation_updated_by_staff', 'Your reservation was updated',
      'A staff member changed the pickup or drop-off details on "' || coalesce(new.reservation_name, 'your reservation') || '".',
      new.id
    );
  end if;

  return new;
end;
$$;

create trigger reservations_staff_edit_notify
  after update on public.reservations
  for each row execute function public.reservations_staff_edit_notify();

-- --- 5. staff+ adding/removing items on someone else's reservation ------
-- notifies that student too. See the header comment for why INSERT is
-- age-gated (30s) and UPDATE/DELETE are not: INSERT also happens, once
-- per line item, when staff builds a brand-new reservation for someone
-- else from scratch via NewReservationView -- that is reservation
-- *creation*, not an edit to something that already existed, and was
-- never what this notification is for.
create or replace function public.reservation_items_staff_edit_notify()
returns trigger security definer language plpgsql set search_path = public as $$
declare
  v_reservation_id uuid := coalesce(new.reservation_id, old.reservation_id);
  v_student_id uuid;
  v_name text;
  v_created_at timestamptz;
begin
  if public.current_user_role() not in ('staff','supervisor','admin') then
    return coalesce(new, old);
  end if;

  select student_id, reservation_name, created_at
    into v_student_id, v_name, v_created_at
    from public.reservations where id = v_reservation_id;

  if v_student_id is null or v_student_id = auth.uid() then
    return coalesce(new, old); -- self-edit
  end if;

  if tg_op = 'INSERT' and v_created_at > now() - interval '30 seconds' then
    return new; -- part of staff's own initial creation of this reservation, not an edit
  end if;

  insert into public.notifications (user_id, type, title, body, related_reservation_id)
  values (
    v_student_id, 'reservation_updated_by_staff', 'Your reservation was updated',
    'A staff member changed the equipment list on "' || coalesce(v_name, 'your reservation') || '".',
    v_reservation_id
  );

  return coalesce(new, old);
end;
$$;

create trigger reservation_items_staff_edit_notify
  after insert or update or delete on public.reservation_items
  for each row execute function public.reservation_items_staff_edit_notify();

-- --- 6. active/completed/cancelled are locked against delete too --------
-- reservations_delete_staff (migration from 10/6) is currently
-- unconditional for staff/supervisor/admin -- widen is not needed
-- (staff already has delete; that gap was a UI-only restriction fixed
-- in ReservationQueueView.vue, not here), but it needs the same
-- status lock as everything else in this migration.
alter policy reservations_delete_staff on public.reservations
  using (
    public.current_user_role() in ('staff', 'supervisor', 'admin')
    and status not in ('active', 'completed', 'cancelled')
  );

-- --- 7. self-edit RLS now lets an auto-approved reservation stay -------
-- self-editable (approved_by is null), while a manually-approved one
-- (approved_by is not null) stays locked for self-edit exactly as
-- today -- see point 3 in the header comment. Four existing policies,
-- each widened the same way; nothing else about them changes.
alter policy reservations_update_own_editable_or_staff on public.reservations
  using (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (not is_capstone)
      and (
        status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
        or (status = 'approved' and approved_by is null)
      )
    )
  )
  with check (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (not is_capstone)
    )
  );

alter policy reservation_items_insert_own on public.reservation_items
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

alter policy reservation_items_update_own on public.reservation_items
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

alter policy reservation_items_delete_own on public.reservation_items
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
