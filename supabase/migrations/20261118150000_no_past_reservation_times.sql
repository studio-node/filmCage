-- ============================================================
-- Migration 33 -- no reservations in the past (time of day too), on
-- the Cage's local clock
-- ============================================================
-- Suzanne, 11/18: "make sure no one can make any reservations in the
-- past", grey out past times today, and after the last slot of the day
-- only offer the next day. Staff+ may still enter a pickup earlier
-- today (a walk-up that already happened), never a past date.
--
-- 1. public.cage_local_now(): the current wall-clock time in
--    America/Denver. The database clock is UTC, so the server's
--    "today" was already tomorrow every evening from 5pm (6pm in
--    summer) -- today's date failed the past-date check and the 3-day
--    lead time was off by one in the evenings.
-- 2. reservations_approval_guard(): full body copied from migration 31
--    (20261111150000). Changes, and nothing else:
--      * new past-date/past-time check at the top, run on INSERT or when
--        pickup_date/pickup_time actually change (see the inline comment);
--        a past time today is allowed for staff+ only.
--      * the server date replaced by the local date everywhere (lead
--        time, the existing re-evaluation past-date check).
-- ============================================================

create or replace function public.cage_local_now()
returns timestamp
language sql
stable
as $$
  select (now() at time zone 'America/Denver')
$$;

grant execute on function public.cage_local_now() to authenticated;

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
  -- The Cage's own wall clock (migration 33). The database runs in
  -- UTC, so the server's date rolls over to "tomorrow" at 5pm Mountain
  -- (6pm in summer). Everything below uses the local date/time.
  v_now timestamp := public.cage_local_now();
  v_today date := v_now::date;
  untouchable_statuses reservation_status[] := array[
    'denied', 'active', 'completed', 'cancelled',
    'waitlisted', 'waitlist_offered'
  ]::reservation_status[];
begin
  actor_is_staff := public.current_user_role() in ('staff','supervisor','admin');

  -- Migration 33: no reservation in the past, checked at the moment a
  -- pickup date/time is actually SET (the insert, or a later edit that
  -- changes it) -- never on an unrelated later write, so a reservation
  -- whose pickup time has simply gone by today can still be approved,
  -- noted, picked up, cancelled, etc.
  --   * a pickup DATE before today: rejected for everyone.
  --   * TODAY at a time that's already passed: rejected for students
  --     and instructors; staff+ may do it, so a walk-up that already
  --     happened (say half an hour ago) can be entered after the fact.
  if new.pickup_date is not null
     and (tg_op = 'INSERT'
          or new.pickup_date is distinct from old.pickup_date
          or new.pickup_time is distinct from old.pickup_time)
  then
    if new.pickup_date < v_today then
      raise exception 'Pickup date can''t be in the past.';
    end if;
    if new.pickup_date = v_today and new.pickup_time is not null
       and new.pickup_time < v_now::time and not actor_is_staff
    then
      raise exception 'That pickup time has already passed today -- pick a later time or another day.';
    end if;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    return new;
  end if;

  v_bypass := actor_is_staff and new.student_id is distinct from auth.uid();

  -- active/completed/cancelled are locked for everyone. The one way
  -- out of 'active' is 'completed', and (migration 31) ONLY through
  -- staff_confirm_return() once every checked-out unit has been
  -- checked back in by staff -- that RPC sets the session-local
  -- app.return_completing flag right before its own status write.
  -- A plain UPDATE to 'completed' (staff included, since staff RLS on
  -- this table is unconditional) is rejected: every reservation has to
  -- be checked in by a staff member before it can be marked complete.
  if old.status = any(array['active','completed','cancelled']::reservation_status[]) then
    if not (old.status = 'active' and new.status = 'completed') then
      raise exception 'This reservation is % and can no longer be changed.', old.status;
    end if;
    if coalesce(current_setting('app.return_completing', true), '') <> 'true' then
      raise exception 'A reservation can only be completed by checking its equipment back in -- use the Return check-in.';
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
    if new.pickup_date is not null and new.pickup_date < v_today + v_lead_time_days then
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
                -- staff_confirm_return()'s active -> completed
                -- write, never trips the past-date check: a
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
  if new.pickup_date is not null and new.pickup_date < v_today then
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
