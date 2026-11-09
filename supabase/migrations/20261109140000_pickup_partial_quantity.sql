-- ============================================================
-- Partial-quantity pickup for regular reservations (Suzanne's
-- follow-up after her first real Pickup pass, 11/10):
--
--   "we have the same problem on the pickup screen where I need to
--   be able to choose that im not picking up a specific quantity.
--   right now it is all or nothing."
--
-- submit_pickup() gains an optional p_quantities jsonb parameter,
-- used ONLY on the regular (non-crew) path. Crew reservations
-- already support this at the per-unit level via p_unit_ids --
-- nothing changes for them.
--
-- p_quantities is a map of item_model_id (as text -- jsonb object
-- keys are always strings, so the frontend sends
-- String(itemModelId)) -> the quantity being claimed RIGHT NOW,
-- e.g. {"<uuid>": 2}. A line not mentioned in the map defaults to
-- 0 -- "not mentioned = not selected" -- matching the new frontend,
-- which always sends every line's current stepper value explicitly.
-- p_quantities = null (the parameter's default) preserves the
-- exact original "claim everything on the reservation" behavior,
-- so any existing caller that doesn't know about this parameter --
-- there shouldn't be one left after this pass's frontend change,
-- but belt and suspenders -- keeps working exactly as before.
--
-- Requested quantities are validated against [0, line.quantity]
-- and HARD REJECTED if out of range -- never silently clamped,
-- per the same "hard rejection, not requires_approval" pattern
-- used everywhere else in this schema for physical impossibilities.
-- At least one unit across the whole reservation must be requested,
-- or the call is rejected before anything is written (same guard
-- shape, and the same message, as the crew path already uses).
--
-- Whatever isn't claimed today is DROPPED from the reservation --
-- same end effect as the old all-or-nothing cancel_unpicked_item,
-- just at partial granularity now: a line whose requested amount is
-- less than its current quantity gets reservation_items.quantity
-- reduced to match; a line requested at 0 is deleted outright. There
-- is no second-pickup-session feature yet, so there is nowhere else
-- for the leftover quantity to go. cancel_unpicked_item() itself is
-- left in the schema, still reachable, just no longer called by the
-- regular-reservation pickup screen (its UI now folds that choice
-- into the same quantity stepper).
--
-- No call to auto_cancel_if_empty() is needed here: the "pick at
-- least one item" guard below mathematically prevents
-- reservation_items from ever being driven to zero rows as a result
-- of this function, so the stuck-empty-reservation problem that
-- function solves elsewhere can't arise from this path.
-- ============================================================

-- create or replace can't change a function's parameter list in place
-- -- adding p_quantities (even with a default) would otherwise leave
-- the old 3-arg signature sitting alongside the new 4-arg one as a
-- second overload, and any 3-arg call becomes ambiguous between them
-- ("function ... is not unique", caught by this migration's own
-- validation run). Drop the old signature explicitly first.
drop function if exists public.submit_pickup(uuid, uuid[], text);

create or replace function public.submit_pickup(
  p_reservation_id uuid,
  p_unit_ids uuid[],
  p_initials text,
  p_quantities jsonb default null
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
  v_requested int;
  v_total_requested int;
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
    -- Regular reservation: claim exactly what was requested per line
    -- (or everything, if p_quantities wasn't given at all).
    if not exists (select 1 from public.reservation_items where reservation_id = p_reservation_id) then
      raise exception 'There is nothing left on this reservation to pick up -- everything was cancelled.';
    end if;

    -- Validate every requested quantity BEFORE writing anything --
    -- same "fail clean, touch nothing" shape as the crew path's own
    -- upfront guard below.
    if p_quantities is not null then
      v_total_requested := 0;
      for v_line in
        select item_model_id, quantity from public.reservation_items where reservation_id = p_reservation_id
      loop
        v_requested := coalesce((p_quantities ->> v_line.item_model_id::text)::int, 0);
        if v_requested < 0 or v_requested > v_line.quantity then
          raise exception 'Requested pickup quantity for one of your items is out of range (0-%), got %.', v_line.quantity, v_requested;
        end if;
        v_total_requested := v_total_requested + v_requested;
      end loop;
      if v_total_requested = 0 then
        raise exception 'Pick at least one item to check out.';
      end if;
    end if;

    insert into public.checkout_sessions (reservation_id, phase, person_user_id, person_signature, person_confirmed_at)
    values (p_reservation_id, 'pickup', v_actor, p_initials, now())
    returning id into v_session_id;

    for v_line in
      select item_model_id, quantity from public.reservation_items where reservation_id = p_reservation_id
    loop
      if p_quantities is not null then
        v_requested := coalesce((p_quantities ->> v_line.item_model_id::text)::int, 0);
      else
        v_requested := v_line.quantity;
      end if;

      v_claimed_count := 0;
      if v_requested > 0 then
        for v_unit in
          select iu.id from public.item_units iu
          where iu.item_model_id = v_line.item_model_id
            and iu.status = 'active'
            and not exists (select 1 from public.reservation_units ru where ru.unit_id = iu.id)
          limit v_requested
        loop
          insert into public.reservation_units (reservation_id, item_model_id, unit_id, checked_out_by, checkout_session_id, checked_out_at)
          values (p_reservation_id, v_line.item_model_id, v_unit.id, v_actor, v_session_id, now());
          v_claimed_count := v_claimed_count + 1;
        end loop;
        if v_claimed_count < v_requested then
          raise exception 'Not enough in-service units of one of your items are currently available (needed %, found %) -- ask staff to check inventory status before trying again.', v_requested, v_claimed_count;
        end if;
      end if;

      -- Whatever wasn't claimed today is dropped from the
      -- reservation -- there's no second-pickup-session feature yet
      -- for it to wait around for.
      if v_requested = 0 then
        delete from public.reservation_items
          where reservation_id = p_reservation_id and item_model_id = v_line.item_model_id;
      elsif v_requested < v_line.quantity then
        update public.reservation_items
          set quantity = v_requested
          where reservation_id = p_reservation_id and item_model_id = v_line.item_model_id;
      end if;
    end loop;

  else
    -- Crew reservation: explicit, free-choice unit selection.
    -- Unchanged by this pass.
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
