-- ============================================================
-- Date-aware equipment availability + the race-condition backstop,
-- requested 10/14 after Suzanne caught a real double-booking: 8 of
-- the 15mm 4" rods reserved for Oct 19 on one reservation, then 5
-- more for the same day on a separate reservation -- 13 requested
-- against 10 total units, and nothing anywhere ever noticed.
--
-- Root cause, confirmed by reading the actual code before writing
-- anything here: every "availability" check that existed --
-- BrowseEquipmentView's availability() and NewReservationView's
-- revalidateStock() -- only ever asked "is a unit physically checked
-- out RIGHT NOW" (item_units_with_status, driven by
-- reservations.status = 'active'). Nothing anywhere ever summed
-- committed quantity across *overlapping future reservations* for
-- the same item model. The "No overlap/exclusion constraint" comment
-- on public.reservations (first migration) was about two
-- *reservations'* time ranges being allowed to coexist (a student can
-- have two pickups at the same hour at different locations) -- never
-- about the same physical inventory being promised twice, which was
-- always meant to be impossible and simply never was enforced.
--
-- Fix, worked out with Suzanne across several rounds before any of
-- this was written:
--  1. A real availability function, date/time-window aware, counting
--     only pending/approved/active reservations against the fleet --
--     waitlisted/waitlist_offered/denied/cancelled/completed never
--     hold inventory, and re-enter the regular flow the instant they
--     become a real reservation again.
--  2. reservations_approval_guard() now calls it for every item line
--     whenever it's about to make a live pending/approved decision --
--     the exact same point item_count/Friday/lead-time/loan-window
--     already get checked, on the exact same re-fire mechanism
--     NewReservationView.vue already relies on for item_count. This
--     is the real backstop, not just a frontend nicety: even if two
--     people submit within milliseconds of each other, only one
--     statement can win -- the loser's statement is rejected outright
--     with a clear error, never silently approved over capacity. A
--     hard inventory shortfall is NOT folded into "requires_approval"
--     like Friday/lead-time/loan-window are -- those are policy
--     preferences staff can wave through; there is no "approve
--     anyway" for 13 rods that don't physically exist, for staff or
--     students alike.
--  3. Exactly like every other business rule in this function, an
--     EXPLICIT write of one of the special statuses
--     (untouchable_statuses -- denied/cancelled/waitlisted/etc.)
--     bypasses this check entirely, same escape hatch already used
--     for cancel/waitlist today (new.status already being one of
--     those values is what lets the trigger step aside rather than
--     recompute). This is what lets add_to_waitlist() actually create
--     a reservation that -- by definition -- doesn't fit right now.
--  4. offer_next_waitlist_entry() used to blindly offer whoever was
--     first in the queue the instant *anything* freed up, with zero
--     awareness that different people in the same queue might want
--     entirely different date ranges or quantities -- harmless before
--     this migration since nothing was ever date-aware anyway, but
--     actively wrong now. It now checks whether the next-in-line's
--     own specific window actually fits in what's currently free
--     before offering it, and moves on to the next entry if not,
--     rather than jamming the whole queue behind one mismatched
--     request. confirm_waitlist_entry() now re-fires the real
--     approval math (including this new check) instead of hardcoding
--     'approved' -- in the rare case availability shifted again
--     during the 48-hour offer window, it correctly lands on pending
--     (or fails) rather than quietly over-promising a second time.
--  5. A new AFTER UPDATE trigger (reservations_release_to_waitlist)
--     checks the waitlist for every item line on a reservation the
--     moment it's denied, cancelled, or completed -- inventory that
--     frees up now actually reaches whoever's next in line instead of
--     sitting there until someone happens to look.
--
-- Deliberately NOT in this migration, by agreement -- it's its own
-- phase, layered on top of this, not needed to fix the bug itself:
-- letting a named crew member pick their own different pickup/
-- drop-off day with its own narrow per-person approval.
-- ============================================================

-- --- 0. a real pre-existing bug, found while validating this change ----
-- reservation_items_insert_own/_update_own/_delete_own (migration from
-- 9/24, long before capstone scheduling existed) all explicitly
-- exclude capstone rows ("and not r.is_capstone"). That's always been
-- wrong for the feature migration 19 just built -- a capstone
-- reservation's own student still picks their own equipment list the
-- normal way; only the pickup/drop-off DATE is deferred until after
-- the pre-pickup meeting. Every prior capstone validation pass tested
-- the reservations table's own status machine in isolation and never
-- actually inserted reservation_items as the owning student, so this
-- never got caught -- found here because this migration's own test
-- script tried to do exactly that. Since migration 19 hasn't been
-- pushed yet, fixing this now means capstone ships working on day
-- one instead of silently broken for every student who tries to
-- build one. Same editable-status window as the non-capstone case --
-- awaiting_appointment/awaiting_schedule/pending stay editable,
-- everything past that locks, no change to that part.
alter policy reservation_items_insert_own on public.reservation_items
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

alter policy reservation_items_update_own on public.reservation_items
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

alter policy reservation_items_delete_own on public.reservation_items
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

-- --- 1. the real availability function --------------------------------
-- SECURITY DEFINER is required, not just convenient: a student calling
-- this while building their own reservation has to get the TRUE
-- count, which depends on every OTHER student's reservations too --
-- rows their own RLS would never let them see directly. Same
-- reasoning as item_unit_current_reservation() elsewhere in this
-- schema.
create or replace function public.item_available_quantity(
  p_item_model_id uuid,
  p_window_start timestamp,
  p_window_end timestamp,
  p_exclude_reservation_id uuid default null
)
returns int
language sql
security definer
stable
set search_path = public
as $$
  select
    (
      select count(*)::int from public.item_units u
      where u.item_model_id = p_item_model_id
        and u.status = 'active'
        and u.condition in ('good', 'caution')
    )
    -
    (
      select coalesce(sum(ri.quantity), 0)::int
      from public.reservation_items ri
      join public.reservations r on r.id = ri.reservation_id
      where ri.item_model_id = p_item_model_id
        and (p_exclude_reservation_id is null or r.id <> p_exclude_reservation_id)
        and r.status in ('pending', 'approved', 'active')
        and r.pickup_date is not null
        -- strict interval overlap -- a dropoff at 10am and the next
        -- pickup at 10am the same day are back-to-back, not a
        -- conflict, so touching endpoints don't count as overlapping.
        and (r.pickup_date + coalesce(r.pickup_time, '00:00'::time)) < p_window_end
        and (
          coalesce(r.dropoff_date, r.pickup_date) + coalesce(r.dropoff_time, r.pickup_time, '00:00'::time)
        ) > p_window_start
    );
$$;

-- --- 2. the per-reservation check reservations_approval_guard calls ----
create or replace function public.assert_reservation_items_available(
  p_reservation_id uuid,
  p_window_start timestamp,
  p_window_end timestamp
)
returns void
language plpgsql
as $$
declare
  item record;
  v_available int;
  v_problems text := '';
begin
  for item in
    select ri.item_model_id, ri.quantity, m.name
    from public.reservation_items ri
    join public.item_models m on m.id = ri.item_model_id
    where ri.reservation_id = p_reservation_id
  loop
    v_available := public.item_available_quantity(
      item.item_model_id, p_window_start, p_window_end, p_reservation_id
    );
    if item.quantity > v_available then
      v_problems := v_problems
        || case when v_problems = '' then '' else '; ' end
        || format('%s: requested %s, only %s available for this window', item.name, item.quantity, v_available);
    end if;
  end loop;

  if v_problems <> '' then
    raise exception 'Not enough equipment available for the requested dates -- %', v_problems;
  end if;
end;
$$;

-- --- 3. wire the check into the existing approval trigger --------------
-- Everything else in this function is unchanged from migration 19 --
-- only the two new blocks (marked below) are added, each right before
-- the point this function already decides pending vs. approved.
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

    if item_count > 20 then
      requires_approval := true;
    end if;

    if extract(isodow from new.pickup_date) = 5 then
      requires_approval := true;
    end if;
    if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
      requires_approval := true;
    end if;

    select role into holder_role from public.users where id = new.student_id;
    if holder_role = 'student' and not actor_is_staff then
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

    -- *** NEW: hard inventory check, same point item_count/Friday/
    -- lead-time/loan-window were already evaluated above. Not folded
    -- into requires_approval -- there is no "approve anyway" for
    -- equipment that doesn't physically exist. Raises and aborts the
    -- whole statement if any line falls short.
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

  if item_count > 20 then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 then
    requires_approval := true;
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
    requires_approval := true;
  end if;

  select role into holder_role from public.users where id = new.student_id;

  if holder_role = 'student' and not actor_is_staff then
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

  -- *** NEW: same hard inventory check as the capstone branch above,
  -- reached only when this statement is actually about to make a
  -- live pending/approved decision.
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

-- --- 4. waitlist offers become window-aware -----------------------------
create or replace function public.offer_next_waitlist_entry(p_item_model_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_entry record;
  v_needed int;
  v_window_start timestamp;
  v_window_end timestamp;
  v_available int;
begin
  for v_entry in
    select we.id, we.reservation_id, we.student_id
    from public.waitlist_entries we
    where we.item_model_id = p_item_model_id and we.status = 'waiting'
    order by we.queue_position asc
  loop
    select r.pickup_date + coalesce(r.pickup_time, '00:00'::time),
           coalesce(r.dropoff_date, r.pickup_date) + coalesce(r.dropoff_time, r.pickup_time, '00:00'::time)
      into v_window_start, v_window_end
      from public.reservations r where r.id = v_entry.reservation_id;

    select coalesce(sum(quantity), 0) into v_needed
      from public.reservation_items
      where reservation_id = v_entry.reservation_id and item_model_id = p_item_model_id;

    v_available := public.item_available_quantity(
      p_item_model_id, v_window_start, v_window_end, v_entry.reservation_id
    );

    if v_available >= v_needed then
      update public.waitlist_entries
        set status = 'offered', offered_at = now(), offer_expires_at = now() + interval '48 hours'
        where id = v_entry.id;

      update public.reservations set status = 'waitlist_offered' where id = v_entry.reservation_id;

      insert into public.notifications (user_id, type, title, body, related_reservation_id)
      values (
        v_entry.student_id, 'waitlist_available', 'Equipment now available',
        'An item you were waitlisted for is available. Confirm within 48 hours or it will be offered to the next student in line.',
        v_entry.reservation_id
      );
      return; -- only one active offer per vacancy at a time
    end if;
    -- doesn't fit this person's window yet -- move to the next entry
    -- in queue order rather than blocking everyone behind a request
    -- that doesn't fit right now.
  end loop;
end;
$$;

-- confirm_waitlist_entry now re-fires the real approval math (which
-- now includes the inventory check above) instead of hardcoding
-- 'approved' -- explicitly writing 'pending' is what lets
-- reservations_approval_guard actually recompute it for real, same
-- escape-hatch mechanics as everywhere else in that trigger.
--
-- Caught during local validation: that update alone isn't enough.
-- reservations_student_cancel_guard (migration 15) treats
-- 'waitlist_offered' as a locked status for its own, non-staff owner,
-- and until now the ONLY legitimate way a student could move
-- themselves out of a locked status was cancelling -- confirming a
-- waitlist offer is a second one it never knew about, so it rejected
-- this update outright ("already waitlist_offered — only staff can
-- change it further") even though the student is doing exactly what
-- they're supposed to. Fixed with an explicit, transaction-local
-- signal (set_config, same technique Postgres recommends for exactly
-- this -- a trusted server-side function telling a trigger "this one
-- statement is mine, let it through") that only this function can
-- set -- clients only ever reach it through this RPC, never through
-- raw SQL, so it can't be forged from the outside.
create or replace function public.confirm_waitlist_entry(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_reservation_id uuid;
  v_item_model_id uuid;
begin
  update public.waitlist_entries
    set status = 'confirmed', responded_at = now()
    where id = p_entry_id and status = 'offered'
    returning reservation_id, item_model_id into v_reservation_id, v_item_model_id;

  if v_reservation_id is null then
    raise exception 'This waitlist offer is no longer available to confirm.';
  end if;

  perform set_config('app.waitlist_confirming', 'true', true);

  update public.reservations
    set status = 'pending',
        admin_notes = coalesce(admin_notes || E'\n', '') || 'Confirmed from waitlist.'
    where id = v_reservation_id;

  -- A confirmed entry doesn't always use up everything that just
  -- freed (someone could take less than the full vacancy) -- check
  -- the rest of the queue for this item again right away rather than
  -- leaving a request that now fits stranded until the next
  -- unrelated cancel/deny/complete happens to nudge it.
  perform public.offer_next_waitlist_entry(v_item_model_id);
end;
$$;

-- The other half of the confirm_waitlist_entry fix above -- see that
-- function's comment for the full story. Everything else here is
-- unchanged from migration 15/19.
create or replace function public.reservations_student_cancel_guard()
returns trigger language plpgsql as $$
declare
  actor_is_staff boolean;
  locked_statuses reservation_status[] := array[
    'approved', 'waitlisted', 'waitlist_offered',
    'awaiting_appointment', 'awaiting_schedule'
  ]::reservation_status[];
begin
  if current_setting('app.waitlist_confirming', true) = 'true' then
    return new; -- confirm_waitlist_entry's own update -- the legitimate
                -- second way (besides cancel) a student moves themselves
                -- out of a locked status; see that function's comment.
  end if;

  actor_is_staff := public.current_user_role() in ('staff', 'supervisor', 'admin');
  if actor_is_staff then
    return new; -- staff edit freely; not this trigger's concern
  end if;

  if old.student_id <> auth.uid() then
    return new; -- not this student's own row
  end if;

  if old.status = any(locked_statuses) then
    if new.status = 'cancelled' then
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

-- --- 5. freeing inventory now actually reaches the waitlist -------------
-- decline_waitlist_entry() and expire_stale_waitlist_offers() already
-- call offer_next_waitlist_entry() explicitly when THEY free
-- something. This covers the other way inventory frees up: the
-- original holder gets denied, cancels, or (once Pickup/Return
-- exists) completes their loan.
create or replace function public.reservations_release_to_waitlist()
returns trigger security definer language plpgsql as $$
declare
  freed_statuses reservation_status[] := array['denied', 'cancelled', 'completed']::reservation_status[];
  held_statuses reservation_status[] := array['pending', 'approved', 'active']::reservation_status[];
  m record;
begin
  if new.status = any(freed_statuses) and old.status = any(held_statuses) then
    for m in select distinct item_model_id from public.reservation_items where reservation_id = new.id loop
      perform public.offer_next_waitlist_entry(m.item_model_id);
    end loop;
  end if;
  return new;
end;
$$;

create trigger reservations_release_to_waitlist
  after update on public.reservations
  for each row execute function public.reservations_release_to_waitlist();
