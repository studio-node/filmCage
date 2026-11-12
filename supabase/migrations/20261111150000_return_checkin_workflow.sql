-- ============================================================
-- Return / check-in workflow (migration 31) -- the second half of
-- Pickup & Return. See claude/Pickup & Return - Rules & Workflow.md
-- in the project for the negotiated rule set this implements.
--
-- Why now: the early-return stopgap (migration 28,
-- return_reservation_early) flipped an active reservation straight to
-- 'completed' with no staff involvement at all, and staff could also
-- write 'completed' directly. Suzanne's rule: every reservation has to
-- be checked back in by a staff member before it can be marked
-- complete. "Returning early" is now just returning before the
-- drop-off date -- same check-in flow as an on-time or late return.
--
-- Two-sided sign-off, same shape as pickup:
--
--   1. submit_return() -- the PERSON's half. Only the person who
--      checked a unit out can return it (crew rule from the rules
--      doc; a regular reservation only has one person anyway). A
--      regular reservation returns everything that person holds in
--      one go; a crew member picks which of THEIR OWN held units
--      they're handing back this visit (several visits are fine).
--      Initials required. The units get tagged with the return
--      session but stay checked out until staff confirms.
--
--   2. staff_confirm_return() -- STAFF's half. For every unit in the
--      session staff records a condition (good/caution/damaged/
--      missing; a note is required for anything but Good). A changed
--      condition goes through the existing item_units_condition_guard
--      (staff can only move it down; a downgrade auto-files a
--      condition_reviews flag against this reservation). Each unit
--      gets a return_item_statuses history row and its
--      reservation_units row is deleted -- which is exactly what frees
--      it everywhere else (the claim guard, available_units_for_
--      reservation, item_unit_current_reservation all key off a
--      reservation_units row existing). If the reservation is past its
--      drop-off date, staff can create the late-return fine right
--      there (amount stays computed by fines_with_amount, same as
--      always). Once no checked-out unit is left on the reservation,
--      it flips to 'completed'.
--
-- 'completed' is now reachable ONLY through staff_confirm_return():
-- it sets a session-local flag (app.return_completing) that
-- reservations_approval_guard() checks, same unforgeable pattern as
-- app.waitlist_confirming (migration 20). return_reservation_early()
-- is dropped.
-- ============================================================

-- ---- 1. checkout_sessions: one PICKUP per person, any number of RETURNS --
-- A crew member can return their gear across several visits, so the
-- (reservation, phase, person) uniqueness from migration 25 now only
-- applies to the pickup phase.
alter table public.checkout_sessions
  drop constraint checkout_sessions_reservation_id_phase_person_key;

create unique index checkout_sessions_one_pickup_per_person
  on public.checkout_sessions (reservation_id, person_user_id)
  where phase = 'pickup';

-- ---- 2. reservation_units: which return session a unit is in -----------
-- Set by submit_return(); the row itself is deleted once staff confirms.
alter table public.reservation_units
  add column return_session_id uuid references public.checkout_sessions(id) on delete set null;

-- ---- 3. return_item_statuses: the permanent return history --------------
-- Existed unused since the first migration. Gets a surrogate key (the
-- same unit can legitimately be checked out and returned twice on one
-- crew reservation) plus who had it and who checked it in, since the
-- reservation_units row that knew this is deleted at return.
alter table public.return_item_statuses
  drop constraint return_item_statuses_pkey;

alter table public.return_item_statuses
  add column id                  uuid not null default gen_random_uuid(),
  add column checked_out_by      uuid references public.users(id),
  add column checkout_session_id uuid references public.checkout_sessions(id) on delete set null,
  add column return_session_id   uuid references public.checkout_sessions(id) on delete set null,
  add column recorded_by         uuid references public.users(id);

alter table public.return_item_statuses
  add primary key (id);

-- It never had RLS turned on. Reads: the reservation's own student, the
-- person who had the unit, crew on that reservation, or staff+. No
-- client write policy at all -- rows are only ever written by
-- staff_confirm_return() (security definer).
alter table public.return_item_statuses enable row level security;

create policy return_item_statuses_read on public.return_item_statuses
  for select using (
    checked_out_by = auth.uid()
    or public.current_user_role() in ('staff','supervisor','admin')
    or exists (
      select 1 from public.reservations r
      where r.id = return_item_statuses.reservation_id and r.student_id = auth.uid()
    )
    or exists (
      select 1 from public.reservation_crew rc
      where rc.reservation_id = return_item_statuses.reservation_id and rc.user_id = auth.uid()
    )
  );

-- ---- 4. submit_return(): the person's half of check-in -------------------
-- p_unit_ids is REQUIRED for a crew reservation (which of your own held
-- units you're handing back this visit) and IGNORED for a regular one
-- (returns everything you hold -- check-in can't leave anything
-- unresolved; staff marks anything not physically handed back as
-- Missing at confirmation).
create or replace function public.submit_return(
  p_reservation_id uuid,
  p_unit_ids uuid[],
  p_initials text
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
  v_held uuid[];
  v_units uuid[];
  v_session_id uuid;
begin
  if v_actor is null then
    raise exception 'Not signed in.';
  end if;
  if p_initials is null or btrim(p_initials) = '' then
    raise exception 'Initials are required to return equipment.';
  end if;

  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    raise exception 'Reservation not found.';
  end if;
  if v_res.status <> 'active' then
    raise exception 'Only a checked-out (active) reservation can be returned.';
  end if;

  -- units this person holds: claimed by them, pickup staff-confirmed,
  -- not already in a pending return.
  select coalesce(array_agg(ru.unit_id), '{}') into v_held
  from public.reservation_units ru
  join public.checkout_sessions cs on cs.id = ru.checkout_session_id
  where ru.reservation_id = p_reservation_id
    and ru.checked_out_by = v_actor
    and ru.return_session_id is null
    and cs.staff_confirmed_at is not null;

  if exists (
    select 1 from public.checkout_sessions
    where reservation_id = p_reservation_id and phase = 'return'
      and person_user_id = v_actor and staff_confirmed_at is null
  ) then
    raise exception 'You already have a return waiting for staff to check it in.';
  end if;

  if cardinality(v_held) = 0 then
    raise exception 'You don''t have any equipment checked out on this reservation to return.';
  end if;

  if v_res.is_group_reservation then
    if p_unit_ids is null or cardinality(p_unit_ids) = 0 then
      raise exception 'Pick at least one item to return.';
    end if;
    if exists (select 1 from unnest(p_unit_ids) u where u <> all (v_held)) then
      raise exception 'You can only return equipment you checked out yourself.';
    end if;
    select array_agg(distinct u) into v_units from unnest(p_unit_ids) u;
  else
    v_units := v_held;
  end if;

  insert into public.checkout_sessions (reservation_id, phase, person_user_id, person_signature, person_confirmed_at)
  values (p_reservation_id, 'return', v_actor, btrim(p_initials), now())
  returning id into v_session_id;

  update public.reservation_units
    set return_session_id = v_session_id
    where reservation_id = p_reservation_id and unit_id = any (v_units);

  return v_session_id;
end;
$$;

-- ---- 5. staff_confirm_return(): staff's half of check-in -----------------
-- p_unit_results: {"<unit uuid>": {"condition": "good", "note": "..."}, ...}
-- -- one entry per unit in the session, required.
-- p_create_late_fine: only acted on when the reservation is actually
-- past its drop-off date; never creates a second open late fine for
-- the same person on the same reservation.
create or replace function public.staff_confirm_return(
  p_session_id uuid,
  p_staff_initials text,
  p_unit_results jsonb,
  p_create_late_fine boolean default false
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_session record;
  v_res record;
  v_ru record;
  v_entry jsonb;
  v_cond unit_condition;
  v_note text;
  v_current unit_condition;
  v_count int := 0;
  v_fine_created boolean := false;
  v_completed boolean := false;
begin
  if public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Only staff can check equipment back in.';
  end if;
  if p_staff_initials is null or btrim(p_staff_initials) = '' then
    raise exception 'Staff initials are required to confirm a return.';
  end if;

  select * into v_session from public.checkout_sessions where id = p_session_id for update;
  if not found then
    raise exception 'Return session not found.';
  end if;
  if v_session.phase <> 'return' then
    raise exception 'This isn''t a return session.';
  end if;
  if v_session.person_confirmed_at is null then
    raise exception 'The person hasn''t submitted their half of this return yet.';
  end if;
  if v_session.staff_confirmed_at is not null then
    raise exception 'This return has already been checked in.';
  end if;

  select * into v_res from public.reservations where id = v_session.reservation_id;
  if v_res.status <> 'active' then
    raise exception 'This reservation isn''t active.';
  end if;

  -- validate every unit's result before writing anything
  for v_ru in
    select ru.* from public.reservation_units ru where ru.return_session_id = p_session_id
  loop
    v_entry := p_unit_results -> (v_ru.unit_id::text);
    if v_entry is null or coalesce(v_entry ->> 'condition', '') = '' then
      raise exception 'Record a condition for every item being returned.';
    end if;
    begin
      v_cond := (v_entry ->> 'condition')::unit_condition;
    exception when invalid_text_representation then
      raise exception 'Unknown condition "%".', v_entry ->> 'condition';
    end;
    v_note := nullif(btrim(coalesce(v_entry ->> 'note', '')), '');
    if v_cond <> 'good' and v_note is null then
      raise exception 'A note is required for anything returned in a condition other than Good.';
    end if;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'There''s nothing in this return to check in.';
  end if;

  -- record staff's half first: the personal-use guard (migration 9)
  -- rejects it here if the same person is on both sides.
  update public.checkout_sessions
    set staff_user_id = v_actor, staff_signature = btrim(p_staff_initials), staff_confirmed_at = now()
    where id = p_session_id;

  for v_ru in
    select ru.* from public.reservation_units ru where ru.return_session_id = p_session_id
  loop
    v_entry := p_unit_results -> (v_ru.unit_id::text);
    v_cond := (v_entry ->> 'condition')::unit_condition;
    v_note := nullif(btrim(coalesce(v_entry ->> 'note', '')), '');

    select condition into v_current from public.item_units where id = v_ru.unit_id;
    if v_cond is distinct from v_current then
      -- runs item_units_condition_guard as this staff actor: downgrade
      -- needs a note (already checked) and files a condition_reviews
      -- flag against this still-active reservation; an upgrade by plain
      -- staff is rejected there, same rule as Edit Items.
      update public.item_units
        set condition = v_cond, condition_note = v_note
        where id = v_ru.unit_id;
    end if;

    insert into public.return_item_statuses
      (reservation_id, unit_id, condition_at_return, note,
       checked_out_by, checkout_session_id, return_session_id, recorded_by)
    values
      (v_ru.reservation_id, v_ru.unit_id, v_cond, v_note,
       v_ru.checked_out_by, v_ru.checkout_session_id, p_session_id, v_actor);

    delete from public.reservation_units
      where reservation_id = v_ru.reservation_id and unit_id = v_ru.unit_id;
  end loop;

  -- late fine, offered at the moment it's discovered (rules doc)
  if p_create_late_fine
     and v_res.dropoff_date is not null and v_res.dropoff_date < current_date
     and not exists (
       select 1 from public.fines
       where reservation_id = v_res.id and student_id = v_session.person_user_id
         and fine_type = 'late_return' and resolved_at is null
     )
  then
    insert into public.fines (student_id, reservation_id, fine_type, issued_by)
    values (v_session.person_user_id, v_res.id, 'late_return', v_actor);

    insert into public.notifications (user_id, type, title, body, related_reservation_id)
    values (
      v_session.person_user_id, 'fine_issued', 'Late return fine',
      format('Equipment from "%s" was returned after its %s drop-off date, so a late-return fine was added to your account.',
             v_res.reservation_name, to_char(v_res.dropoff_date, 'Mon DD')),
      v_res.id
    );
    v_fine_created := true;
  end if;

  -- complete once nothing checked out is left on the reservation
  if not exists (select 1 from public.reservation_units where reservation_id = v_res.id) then
    perform set_config('app.return_completing', 'true', true);
    update public.reservations set status = 'completed' where id = v_res.id;
    perform set_config('app.return_completing', 'false', true);
    v_completed := true;
  end if;

  return jsonb_build_object('completed', v_completed, 'fine_created', v_fine_created, 'units', v_count);
end;
$$;

-- ---- 6. retire the early-return stopgap ---------------------------------
drop function if exists public.return_reservation_early(uuid);

-- ---- 7. reservations_approval_guard(): 'completed' only via check-in -----
-- Full body copied from migration 28 (20261109120000); the ONLY change
-- is the active -> completed carve-out now also requiring
-- app.return_completing (plus a comment touch-up).
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
