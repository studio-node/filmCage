-- ============================================================
-- Real bug, found by Suzanne live-testing the new Reservations tab
-- (10/5): reservations_approval_guard() has only ever had a branch
-- that moves a reservation INTO 'pending' when something requires
-- approval. It never had a branch that moves one OUT of pending into
-- 'approved' when nothing does — true all the way back to the
-- original base migration, not something either review migration (9
-- or 11) introduced. Since reservations.status defaults to 'pending'
-- and nothing in the app sets it explicitly on insert, every single
-- reservation — including a completely by-the-book one, 1 item, 2
-- weeks out, well inside the loan window — landed on that default and
-- just sat there forever. The artifact mock this was built from
-- always had this as an explicit two-way branch
-- (`r.status = requiresApproval ? "pending" : "approved"`); that
-- branch just never made it into the real trigger.
--
-- Fix: make the pending/approved move explicitly two-way. Both
-- directions are guarded by the same exclusion list, widened to
-- include every status this trigger has no business touching —
-- waitlisted/waitlist_offered (owned by the waitlist functions) and
-- the two capstone-only statuses (unreachable here in practice, since
-- is_capstone returns early above, but excluded anyway so this trigger
-- can only ever move a reservation between pending and approved, full
-- stop). Capstone reservations are untouched by this fix — they still
-- always go to 'pending' on insert via the early return above, and
-- this migration doesn't change that.
--
-- This does NOT start auto-assigning physical units
-- (reservation_units) to a newly-approved reservation — that's a
-- separate, already-known, intentionally-deferred piece of the
-- Pickup/Return build, not part of this fix.
--
-- Caught during local validation of this same migration, before it was
-- ever pushed: the first draft only forced 'pending' on INSERT for
-- capstone rows, same as before. For a non-capstone row, reservation_items
-- never exist yet at INSERT time (the app inserts them in a follow-up
-- statement), so item_count read as 0 and a perfectly in-policy
-- reservation would jump straight to 'approved' on INSERT — before any
-- items were attached. That then blocked the very next reservation_items
-- insert, since the student-insert policy on that table (migration 12)
-- only allows adding items while the reservation is still pending. Fixed
-- by making every INSERT, capstone or not, land on 'pending' unconditionally
-- and letting the app's existing re-fire UPDATE (after items are inserted)
-- make the real call.
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
begin
  -- On INSERT, reservation_items can't exist yet (they're inserted in a
  -- follow-up statement right after this row is created), so item_count
  -- below would always read as 0 and this function would wrongly decide
  -- "nothing requires approval" before any items are actually attached.
  -- Worse, setting status := 'approved' at that point blocks the very next
  -- insert into reservation_items, since the student-insert RLS policy on
  -- that table (migration 12) only allows adding items while the
  -- reservation is still pending. So every INSERT unconditionally lands on
  -- 'pending' — capstone or not — and the real approve/pending decision is
  -- deferred to the follow-up UPDATE the app already issues once items
  -- exist (NewReservationView.vue re-fires this trigger by touching
  -- pickup_date right after inserting reservation_items).
  if tg_op = 'INSERT' then
    new.status := 'pending';
    return new;
  end if;

  if new.is_capstone then
    return new; -- capstone status is owned by the appointment-scheduling flow, not this trigger
  end if;

  select coalesce(sum(quantity), 0) into item_count
    from public.reservation_items where reservation_id = new.id;

  if item_count > 20 then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 then
    requires_approval := true; -- Friday pickup — always requires approval, no exceptions
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
    requires_approval := true; -- Friday drop-off — always requires approval, no exceptions
  end if;

  select role into holder_role from public.users where id = new.student_id;
  actor_is_staff := public.current_user_role() in ('staff','supervisor','admin');

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
    new.status := 'approved'; -- the missing branch — see migration header
  end if;

  return new;
end;
$$;
