-- ============================================================
-- Pickup (checkout) workflow -- the first of two build passes
-- (return/check-in is its own later pass; see
-- claude/Pickup & Return - Rules & Workflow.md in the project for
-- the full negotiated rule set this implements).
--
-- Two genuinely different workflows, keyed off is_group_reservation:
--
--   REGULAR reservation: one person, one sitting. Every item on the
--   reservation must be either claimed (checked off) or cancelled
--   before the checkout can complete -- nothing is left unresolved,
--   nothing silently expires. A cancelled item is available to other
--   reservations immediately (cancel_unpicked_item below). Because
--   there's exactly one person, submit_pickup() auto-claims whatever
--   reservation_items lines are still standing at submit time --
--   there's no per-serial choice to make, and no reason to make a
--   solo student pick a specific serial off a list of otherwise
--   identical units.
--
--   CREW (group) reservation: multiple people, multiple independent
--   visits, free choice of *specific* units (not limited to the
--   original reservation_assignments split -- that's shown to the
--   frontend as a pre-checked suggestion, not enforced here). Each
--   crew member's visit is its own checkout_sessions row, whether
--   they set their own pickup_time_override or fell back to the
--   producer's shared time. Nothing forces full resolution in one
--   sitting -- a crew reservation can have several separate pickup
--   visits spread across the loan window, and anything unclaimed
--   just stays available for someone *else on the same reservation*
--   to grab later (never auto-released to other reservations; staff
--   can manually release early, not built this pass).
--
-- Every checkout is a two-sided sign-off: the person submits their
-- half (what they're taking + their own initials, acknowledging
-- legal responsibility -- enforced on the frontend, and p_initials
-- is required here too so this can never be skipped by calling the
-- RPC directly), then staff separately confirms their half (their
-- own initials, no legal language -- just confirming the items were
-- actually handed over). The reservation flips to 'active' the
-- moment the *first* checkout session on it gets BOTH confirmations
-- -- it doesn't wait for every expected person.
--
-- Staff adjusting a unit's condition at pickup time (Suzanne asked
-- for this explicitly, same ability as at return) needs no new
-- schema or RPC at all -- item_units_write_staff_up (initial schema)
-- already grants staff+ write access to item_units, and
-- item_units_condition_guard (9/30) already enforces the
-- note-required-on-downgrade / staff-can-only-move-down /
-- admin-can-move-up rules and auto-files a condition_reviews flag.
-- The frontend just calls a plain update on item_units; nothing here
-- needs to change for that to work.
-- ============================================================

-- ---- 1. checkout_sessions: one row per visit, not per reservation --------
-- Every person's checkout (or, later, return) is its own event, even
-- when several people fall back to one shared time slot.

alter table public.checkout_sessions
  drop constraint checkout_sessions_reservation_id_phase_key;

alter table public.checkout_sessions
  add constraint checkout_sessions_reservation_id_phase_person_key
    unique (reservation_id, phase, person_user_id);

alter table public.checkout_sessions
  add column staff_signature text;

-- ---- 2. reservation_units: record who claimed what, and when ------------
-- A row now only ever gets created at the moment of an actual claim
-- (unit assignment happens at the counter, never pre-populated at
-- approval time -- see the rules doc).

alter table public.reservation_units
  add column checked_out_by     uuid references public.users(id),
  add column checkout_session_id uuid references public.checkout_sessions(id) on delete cascade,
  add column checked_out_at     timestamptz;

-- A physical unit can never be claimed on two reservations at once.
--
-- Deliberately NOT reusing item_unit_current_reservation() (9/30) here
-- -- that function only counts a unit as "held" once its reservation
-- is status = 'active', because it exists to answer a different
-- question (which ACTIVE reservation should a condition-review or a
-- lifecycle-status change be attributed to). A unit becomes spoken
-- for the moment ANY reservation_units row is written for it, i.e.
-- the instant the person submits their half of pickup -- well before
-- staff confirms and the reservation flips active. Gating this guard
-- on item_unit_current_reservation() would leave a real window where
-- two different reservations could both walk away thinking they had
-- the same physical unit, simply because neither pickup had been
-- staff-confirmed yet. A reservation_units row only ever goes away at
-- return (a later pass), so "any row exists for this unit" is exactly
-- "not yet returned, so not available to claim elsewhere" today.
create or replace function public.reservation_units_claim_guard()
returns trigger language plpgsql as $$
begin
  if exists (
    select 1 from public.reservation_units
    where unit_id = new.unit_id and reservation_id <> new.reservation_id
  ) then
    raise exception 'This unit is already checked out on another reservation.';
  end if;
  return new;
end;
$$;
create trigger reservation_units_claim_guard
  before insert on public.reservation_units
  for each row execute function public.reservation_units_claim_guard();

-- ---- 3. submit_pickup(): the person's half of checkout -------------------
-- p_unit_ids is REQUIRED for a crew reservation (explicit, free-choice
-- per-serial claim) and IGNORED for a regular one (auto-claims every
-- surviving reservation_items line in full -- there's only one person,
-- so there's no serial-level choice to make; anything the student
-- didn't want had to be cancelled first via cancel_unpicked_item).
create or replace function public.submit_pickup(
  p_reservation_id uuid,
  p_unit_ids uuid[],
  p_initials text
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
  v_override time;
  v_scheduled_at timestamptz;
  v_session_id uuid;
  v_line record;
  v_claimed_count int;
  v_already_claimed int;
  v_unit record;
  v_unit_id uuid;
begin
  if v_actor is null then
    raise exception 'Not signed in.';
  end if;
  if p_initials is null or btrim(p_initials) = '' then
    raise exception 'Initials are required to complete checkout.';
  end if;

  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    raise exception 'Reservation not found.';
  end if;

  if v_res.status not in ('approved', 'active') then
    raise exception 'This reservation is not ready for pickup.';
  end if;

  if v_res.pickup_date is null or v_res.pickup_time is null then
    raise exception 'This reservation does not have a scheduled pickup time yet.';
  end if;

  -- Who's allowed to submit, and against which scheduled time.
  if not v_res.is_group_reservation then
    if v_actor <> v_res.student_id then
      raise exception 'Only the reservation''s own student can check out a regular reservation.';
    end if;
    v_scheduled_at := (v_res.pickup_date::timestamp + v_res.pickup_time);
  else
    if not exists (
      select 1 from public.reservation_crew where reservation_id = p_reservation_id and user_id = v_actor
    ) then
      raise exception 'You are not listed as crew on this reservation.';
    end if;
    v_override := null;
    if v_res.allow_individual_pickup_times then
      select pickup_time_override into v_override
        from public.reservation_crew
        where reservation_id = p_reservation_id and user_id = v_actor;
    end if;
    v_scheduled_at := (v_res.pickup_date::timestamp + coalesce(v_override, v_res.pickup_time));
  end if;

  if now() < v_scheduled_at - interval '30 minutes' then
    raise exception 'Pickup opens 30 minutes before the scheduled time.';
  end if;

  if exists (
    select 1 from public.checkout_sessions
    where reservation_id = p_reservation_id and phase = 'pickup' and person_user_id = v_actor
  ) then
    raise exception 'You''ve already completed pickup for this reservation.';
  end if;

  if not v_res.is_group_reservation then
    -- Regular reservation: auto-claim every surviving line in full.
    -- Nothing to resolve here except making sure enough real,
    -- in-service, unclaimed inventory still exists for each line --
    -- if a unit went out_for_repair/retired/lost since approval, this
    -- is where that shortfall actually surfaces.
    if not exists (select 1 from public.reservation_items where reservation_id = p_reservation_id) then
      raise exception 'There is nothing left on this reservation to pick up -- everything was cancelled.';
    end if;

    insert into public.checkout_sessions (reservation_id, phase, person_user_id, person_signature, person_confirmed_at)
    values (p_reservation_id, 'pickup', v_actor, p_initials, now())
    returning id into v_session_id;

    for v_line in
      select item_model_id, quantity from public.reservation_items where reservation_id = p_reservation_id
    loop
      v_claimed_count := 0;
      for v_unit in
        select iu.id from public.item_units iu
        where iu.item_model_id = v_line.item_model_id
          and iu.status = 'active'
          and not exists (select 1 from public.reservation_units ru where ru.unit_id = iu.id)
        limit v_line.quantity
      loop
        insert into public.reservation_units (reservation_id, item_model_id, unit_id, checked_out_by, checkout_session_id, checked_out_at)
        values (p_reservation_id, v_line.item_model_id, v_unit.id, v_actor, v_session_id, now());
        v_claimed_count := v_claimed_count + 1;
      end loop;
      if v_claimed_count < v_line.quantity then
        raise exception 'Not enough in-service units of one of your items are currently available (needed %, found %) -- ask staff to check inventory status before trying again.', v_line.quantity, v_claimed_count;
      end if;
    end loop;

  else
    -- Crew reservation: explicit, free-choice unit selection.
    if p_unit_ids is null or array_length(p_unit_ids, 1) is null then
      raise exception 'Pick at least one item to check out.';
    end if;

    insert into public.checkout_sessions (reservation_id, phase, person_user_id, person_signature, person_confirmed_at)
    values (p_reservation_id, 'pickup', v_actor, p_initials, now())
    returning id into v_session_id;

    foreach v_unit_id in array p_unit_ids loop
      select iu.* into v_unit from public.item_units iu where iu.id = v_unit_id;
      if not found then
        raise exception 'Unit not found.';
      end if;
      if v_unit.status <> 'active' then
        raise exception 'One of the selected units is not currently in service.';
      end if;
      if not exists (
        select 1 from public.reservation_items
        where reservation_id = p_reservation_id and item_model_id = v_unit.item_model_id
      ) then
        raise exception 'One of the selected units isn''t one of the items on this reservation.';
      end if;

      -- This exact unit may already be claimed on THIS reservation by
      -- an earlier crew visit even though the reservation itself is
      -- still 'approved' (staff hasn't confirmed anyone yet) --
      -- item_unit_current_reservation() alone won't catch this, since
      -- it only counts a unit as "held" once the reservation is
      -- 'active'. Check the raw reservation_units rows directly so
      -- this fails with a clear message instead of a raw pkey
      -- violation.
      if exists (
        select 1 from public.reservation_units
        where reservation_id = p_reservation_id and unit_id = v_unit_id
      ) then
        raise exception 'That specific unit has already been claimed by someone else on this reservation -- pick a different one.';
      end if;

      select quantity into v_claimed_count from public.reservation_items
        where reservation_id = p_reservation_id and item_model_id = v_unit.item_model_id;
      select count(*) into v_already_claimed from public.reservation_units
        where reservation_id = p_reservation_id and item_model_id = v_unit.item_model_id;
      if v_already_claimed >= v_claimed_count then
        raise exception 'All of this item''s quantity on this reservation has already been claimed.';
      end if;

      insert into public.reservation_units (reservation_id, item_model_id, unit_id, checked_out_by, checkout_session_id, checked_out_at)
      values (p_reservation_id, v_unit.item_model_id, v_unit_id, v_actor, v_session_id, now());
    end loop;
  end if;

  return v_session_id;
end;
$$;

-- ---- 4. cancel_unpicked_item(): regular reservations only -----------------
-- Either the reservation's own student or staff+ can do this. Deletes
-- the line outright -- reservation_items_delete_cleans_assignments
-- (migration 23) already cleans up any stray reservation_assignments
-- row for it, though a regular reservation never has those anyway.
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
end;
$$;

-- ---- 5. staff_confirm_pickup(): staff's half of checkout ------------------
create or replace function public.staff_confirm_pickup(
  p_session_id uuid,
  p_staff_initials text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_session record;
  v_already_active boolean;
begin
  if public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Only staff can confirm a checkout.';
  end if;
  if p_staff_initials is null or btrim(p_staff_initials) = '' then
    raise exception 'Staff initials are required to confirm checkout.';
  end if;

  select * into v_session from public.checkout_sessions where id = p_session_id;
  if not found then
    raise exception 'Checkout session not found.';
  end if;
  if v_session.phase <> 'pickup' then
    raise exception 'This isn''t a pickup session.';
  end if;
  if v_session.person_confirmed_at is null then
    raise exception 'The person hasn''t confirmed their half of this checkout yet.';
  end if;
  if v_session.staff_confirmed_at is not null then
    raise exception 'This checkout has already been confirmed by staff.';
  end if;

  select exists (
    select 1 from public.checkout_sessions
    where reservation_id = v_session.reservation_id and phase = 'pickup' and staff_confirmed_at is not null
  ) into v_already_active;

  update public.checkout_sessions
    set staff_user_id = auth.uid(), staff_signature = p_staff_initials, staff_confirmed_at = now()
    where id = p_session_id;

  if not v_already_active then
    update public.reservations set status = 'active'
      where id = v_session.reservation_id and status <> 'active';
  end if;
end;
$$;
