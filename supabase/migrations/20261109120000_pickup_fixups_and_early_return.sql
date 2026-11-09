-- ============================================================
-- Three fixes reported after the first real end-to-end pickup pass,
-- all independent of each other:
--
-- 1. EMPTY-RESERVATION COLLAPSE. Suzanne's repro: she cancelled every
--    item off a reservation from the Pickup checkout screen itself
--    (cancel_unpicked_item, one line at a time) and was left with a
--    reservation that has zero reservation_items, still sitting in
--    'approved'/'pending' -- and no way to get rid of it as the
--    student, because My Reservations' cancel button is bucket-gated
--    to Upcoming only (confirmed 10/19), and once the pickup date has
--    passed (which it had, since she'd gone to pick it up), the row
--    reads as "Past" with no actions offered at all, even though
--    nothing about it is actually locked at the database layer.
--    Fix: a reservation with nothing left on it has nothing to track
--    and nothing holding inventory, so it should just collapse --
--    auto-cancel itself the moment its last item goes, rather than
--    rely on the student finding a way to cancel it by hand.
--    public.auto_cancel_if_empty() is the shared check, called from
--    cancel_unpicked_item() (the Pickup screen's path) and from the
--    frontend after the Reservation Detail page's own item editor
--    settles (see apps/web -- that one's a multi-request client-side
--    flow, so it can only safely check "are we at zero now" once
--    every delete/update/insert in the save has finished, not after
--    each individual row change, or swapping one item for another
--    would trip a false collapse mid-save).
--
-- 2. PAST-DATE GUARD. Nothing anywhere -- frontend or database --
--    ever checked that a pickup date wasn't already in the past.
--    Same category of problem as the double-booking bug (migration
--    20): a hard rejection, not a requires_approval flag, since
--    there's no such thing as approving a reservation for a date
--    that's already gone. Added right alongside the existing hard
--    inventory check inside reservations_approval_guard(), after the
--    same untouchable_statuses escape -- so, like the inventory
--    check, it only ever runs when the trigger is about to make a
--    real pending/approved decision (the initial post-insert re-fire,
--    or a later live edit), and is skipped the same way for a cancel,
--    denial, or waitlist write. The frontend date pickers also get a
--    `:min` of today, so this is normally never reached at all --
--    the trigger is the backstop for a direct API call or a stale
--    client, same division of labor as every other hard rule here.
--
-- 3. EARLY RETURN. Return/check-in itself is still its own later
--    build pass (full two-sided sign-off, per-unit condition entry,
--    same shape as Pickup) -- but Suzanne asked for a stopgap now:
--    on an *active* reservation, its own student or staff+ should be
--    able to mark the whole thing returned early, with a confirm
--    step, rather than waiting on that full feature to exist before
--    anyone can close out a reservation that's done early. This is
--    deliberately whole-reservation, not per-unit/per-person --
--    return_reservation_early() just flips status to 'completed',
--    which is already everything item_units_with_status needs to
--    stop treating those units as checked out (it keys off
--    status = 'active' via item_unit_current_reservation(), not off
--    reservation_units rows existing -- see the 9/30 migration), so
--    the units free up immediately with no other schema change.
--    reservations_approval_guard() already treats active/completed/
--    cancelled as fully locked for everyone with no exceptions at
--    all -- that lock gets exactly one carve-out added, active ->
--    completed, and nothing else about it changes.
-- ============================================================

-- ---- 1. auto_cancel_if_empty(): collapse a reservation with --------
-- nothing left on it. Same authorization shape as cancel_unpicked_item
-- (owner or staff+) -- this never runs unprompted, only ever called
-- right after a legitimate item removal by someone already allowed to
-- make that removal, but it checks for itself anyway rather than
-- trusting the caller, same as every other RPC in this schema.
create or replace function public.auto_cancel_if_empty(p_reservation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
  v_remaining int;
begin
  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    return; -- nothing to do, not this function's problem to complain about
  end if;

  if v_actor <> v_res.student_id and public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Not authorized.';
  end if;

  -- Only pre-pickup, not-yet-locked statuses ever legitimately reach
  -- zero items through cancel_unpicked_item or the Detail page's item
  -- editor -- both already refuse to touch active/completed/cancelled
  -- rows -- but check explicitly rather than assume.
  if v_res.status not in ('pending', 'approved', 'denied', 'waitlisted') then
    return;
  end if;

  select count(*) into v_remaining from public.reservation_items where reservation_id = p_reservation_id;
  if v_remaining > 0 then
    return;
  end if;

  update public.reservations set status = 'cancelled' where id = p_reservation_id;
end;
$$;

-- ---- 2. cancel_unpicked_item(): collapse the reservation the ------
-- moment its last line goes, right in the same function that's
-- already the one legitimate way to remove a line at the pickup
-- counter -- no separate frontend call needed for this path.
create or replace function public.cancel_unpicked_item(
  p_reservation_id uuid,
  p_item_model_id uuid
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
begin
  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    raise exception 'Reservation not found.';
  end if;

  if v_res.is_group_reservation then
    raise exception 'Items on a crew reservation aren''t cancelled this way -- unclaimed items just stay available for someone else on the reservation.';
  end if;

  if v_actor <> v_res.student_id and public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Not authorized.';
  end if;

  if v_res.status not in ('pending', 'approved', 'denied', 'waitlisted') then
    raise exception 'This reservation is locked and can no longer be changed.';
  end if;

  delete from public.reservation_items
    where reservation_id = p_reservation_id and item_model_id = p_item_model_id;

  if not found then
    raise exception 'That item is not on this reservation.';
  end if;

  perform public.auto_cancel_if_empty(p_reservation_id);
end;
$$;

-- ---- 3. reservations_approval_guard(): past-date hard rejection ---
-- plus the one carve-out early return needs. Full body copied from
-- 20261021120000's version with exactly these two changes -- nothing
-- else here is different.
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

  -- active/completed/cancelled are locked for everyone -- with
  -- exactly one carve-out, new this pass: active -> completed is how
  -- an early return (or, eventually, a real Return/check-in) closes
  -- a reservation out. Nothing else about this lock changes --
  -- completed and cancelled still can never be left once reached,
  -- and active can never go anywhere except completed.
  if old.status = any(array['active','completed','cancelled']::reservation_status[]) then
    if not (old.status = 'active' and new.status = 'completed') then
      raise exception 'This reservation is % and can no longer be changed.', old.status;
    end if;
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
                -- 'waitlisted'/'denied'/'cancelled'/'completed'/etc.
                -- through without ever reaching the past-date or
                -- inventory checks below. This is exactly why a
                -- cancel of an already-overdue reservation, or
                -- return_reservation_early()'s active -> completed
                -- write, never trips the new past-date check: a
                -- reservation whose date has already gone by is
                -- allowed to be closed out, just never re-approved.
  end if;

  -- NEW: a pickup date that's already in the past is a hard
  -- rejection, not a requires_approval flag -- there's no such thing
  -- as approving a reservation for a date that's already happened.
  -- Placed here, after the untouchable_statuses escape, for exactly
  -- the same reason the inventory check below is placed here: this
  -- only needs to run at the moments the trigger is actually about to
  -- decide pending vs. approved (the initial post-insert re-fire, or
  -- a later live edit) -- never on a cancel/deny/waitlist write; see
  -- the migration header for the full reasoning.
  if new.pickup_date is not null and new.pickup_date < current_date then
    raise exception 'Pickup date can''t be in the past.';
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

-- ---- 4. return_reservation_early(): the Pickup/Return stopgap -----
-- action -- not the real Return/check-in feature (still its own later
-- pass, full two-sided sign-off and per-unit condition entry, same
-- shape as Pickup), just a way to close an active reservation out
-- before its scheduled drop-off if there's a reason to. Whole-
-- reservation, not per-unit/per-person -- a crew reservation with
-- several people's separate pickup sessions on it still gets
-- returned as one unit, same as there's only one 'active' status on
-- the row to flip. Restricted to the reservation's own holder
-- (student_id) or staff+, same ownership shape as cancel -- not open
-- to a crew member who isn't the producer, since this closes out
-- everyone's gear on the reservation at once, not just their own.
create or replace function public.return_reservation_early(p_reservation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
begin
  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    raise exception 'Reservation not found.';
  end if;

  if v_res.status <> 'active' then
    raise exception 'Only an active reservation can be returned early.';
  end if;

  if v_actor <> v_res.student_id and public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Not authorized.';
  end if;

  update public.reservations set status = 'completed' where id = p_reservation_id;
end;
$$;
