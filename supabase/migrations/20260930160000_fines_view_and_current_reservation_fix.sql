-- ============================================================
-- Three fixes, all in the same "stored value can drift from its
-- source of truth" family, found while auditing the schema for
-- normalization issues:
--
-- 1. fines.rate_per_day / fines.current_amount were stored values
--    derived from days_late, kept correct only by remembering to call
--    recalculate_fine_amount() -- and the daily job that's supposed to
--    call it (escalate_late_fines()) isn't wired up to a scheduler
--    yet, so these are already stale from the moment a fine is
--    created. Replaced with a view that computes them live from
--    days_late, so there's nothing left to remember to keep in sync.
--
-- 2. item_units.current_reservation_id is read live by Browse
--    Equipment to decide "is this unit available", but nothing in the
--    app writes to it (Pickup/Return isn't built yet) -- so it can
--    never reflect reality once real checkouts start happening.
--    Replaced with a view that derives "currently checked out, and by
--    which reservation" directly from reservation_units + reservation
--    status, so availability is always correct without any code
--    needing to remember to set/clear a pointer.
--
-- 3. student_profiles has row-level security enabled but only ever
--    had a SELECT policy -- no INSERT/UPDATE/DELETE policy was ever
--    written for it. student_notes_apply_strike() (the trigger that
--    increments strike_count and auto-blocks a student on their 3rd
--    strike) is a plain trigger, not security definer, so its own
--    UPDATE to student_profiles runs as the staff/admin user who
--    logged the strike -- and RLS silently drops that update to zero
--    rows, since no policy grants it. Net effect: strike_count has
--    never actually been able to increment against a real (non-
--    superuser) connection, and the 3-strike auto-block has been
--    dead code since the day it was written. This is the same bug
--    shape as the condition_reviews gap fixed on 9/24 -- a table with
--    RLS turned on but an incomplete set of policies.
--
-- 4. Found while validating #3: notifications has the identical gap
--    (RLS on, no INSERT policy), so the "account blocked" notification
--    that same trigger inserts was also being silently dropped.
--    student_notes_apply_strike() is now security definer, matching
--    the pattern already used for the waitlist notification functions.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Fines: view instead of stored rate_per_day / current_amount
-- ------------------------------------------------------------

-- Closed-form equivalent of summing fine_rate_for_day(1..days_late) --
-- day 1 = $5, days 2-3 = $10/day, day 4+ = $25/day. Immutable, so this
-- is cheap to compute per row in the view (no loop needed).
create or replace function public.fine_current_amount(p_days_late int)
returns numeric(10,2)
language sql immutable as $$
  select case
    when p_days_late is null or p_days_late <= 0 then 0.00
    when p_days_late = 1 then 5.00
    when p_days_late <= 3 then 5.00 + 10.00 * (p_days_late - 1)
    else 25.00 * (p_days_late - 2)
  end;
$$;

create view public.fines_with_amount as
select
  f.id,
  f.student_id,
  f.reservation_id,
  f.unit_id,
  f.fine_type,
  f.status,
  f.days_late,
  public.fine_rate_for_day(f.days_late) as rate_per_day,
  public.fine_current_amount(f.days_late) as current_amount,
  f.escalation_note,
  f.created_at,
  f.resolved_at,
  f.resolved_by
from public.fines f;

-- escalate_late_fines() no longer needs to recalculate and store an
-- amount -- bumping days_late is the only thing left to do; the view
-- picks up the new amount automatically on next read.
create or replace function public.escalate_late_fines()
returns void language plpgsql as $$
begin
  update public.fines
    set days_late = days_late + 1
    where fine_type = 'late_return' and status in ('warning', 'active');
end;
$$;

drop function if exists public.recalculate_fine_amount(uuid);

alter table public.fines
  drop column rate_per_day,
  drop column current_amount;

-- ------------------------------------------------------------
-- 2. item_units: view instead of a stored current_reservation_id
-- ------------------------------------------------------------

-- security definer: this has to see every reservation_units/
-- reservations row to correctly compute checked-out status for units
-- reserved by *other* students, regardless of the querying user's own
-- RLS visibility into those tables. It only ever returns a bare
-- reservation id (or null) -- the same thing item_units.
-- current_reservation_id already exposed to every authenticated user
-- today, so this doesn't widen access, just makes it correct.
create or replace function public.item_unit_current_reservation(p_unit_id uuid)
returns uuid
language sql stable security definer set search_path = public
as $$
  select ru.reservation_id
  from public.reservation_units ru
  join public.reservations res on res.id = ru.reservation_id
  where ru.unit_id = p_unit_id and res.status = 'active'
  limit 1;
$$;

-- item_units_condition_guard used new.current_reservation_id to file
-- a condition_reviews row against whichever reservation currently
-- holds the unit -- now computed the same way the view computes it,
-- since the column itself is going away below.
create or replace function public.item_units_condition_guard()
returns trigger language plpgsql as $$
declare
  old_rank int;
  new_rank int;
  actor_role user_role;
  v_current_reservation_id uuid;
  rank_map constant jsonb := '{"missing": -1, "damaged": 0, "caution": 1, "good": 2}'::jsonb;
begin
  actor_role := public.current_user_role();
  new_rank := (rank_map ->> new.condition::text)::int;

  if tg_op = 'INSERT' then
    if new.condition <> 'good' and (new.condition_note is null or btrim(new.condition_note) = '') then
      raise exception 'A note is required when a unit is not created in Good condition.';
    end if;
    return new;
  end if;

  old_rank := (rank_map ->> old.condition::text)::int;

  if new.condition = old.condition then
    return new;
  end if;

  if new_rank > old_rank and actor_role = 'staff' then
    raise exception 'Staff can downgrade a unit''s condition, but only a Supervisor or Admin can move it back to a better state.';
  end if;

  if new_rank < old_rank then
    if new.condition_note is null or btrim(new.condition_note) = '' then
      raise exception 'A note is required when downgrading a unit''s condition.';
    end if;

    v_current_reservation_id := public.item_unit_current_reservation(new.id);

    insert into public.condition_reviews (unit_id, item_model_id, reservation_id, student_id, condition, note)
    values (
      new.id, new.item_model_id, v_current_reservation_id,
      (select student_id from public.reservations where id = v_current_reservation_id),
      new.condition, new.condition_note
    );
  end if;

  return new;
end;
$$;

drop index if exists public.item_units_reservation_idx;

alter table public.item_units
  drop column current_reservation_id;

create view public.item_units_with_status as
select
  u.id,
  u.item_model_id,
  u.unit_code,
  u.condition,
  u.condition_note,
  u.qr_code,
  u.serial_number,
  u.created_at,
  u.updated_at,
  public.item_unit_current_reservation(u.id) as current_reservation_id
from public.item_units u;

-- ------------------------------------------------------------
-- 3. student_profiles: the missing write policy
-- ------------------------------------------------------------
create policy student_profiles_write_staff_up on public.student_profiles
  for update using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- ------------------------------------------------------------
-- 4. student_notes_apply_strike(): found while validating #3 above.
-- Even with the student_profiles policy added, this trigger's own
-- notifications insert (the "account blocked" message) was still
-- getting silently dropped by RLS -- notifications has RLS enabled
-- but never had an INSERT policy either. Rather than open up
-- notifications for direct staff inserts (notifications should only
-- ever be system-generated by a specific, well-defined trigger, not
-- freely writable), this trigger becomes security definer instead,
-- the same fix already used for the waitlist notification functions
-- (offer_next_waitlist_entry() etc.) for the identical reason: writing
-- a notification on behalf of a different user than the one making
-- the request.
-- ------------------------------------------------------------
create or replace function public.student_notes_apply_strike()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  new_count int;
begin
  if new.is_strike then
    update public.student_profiles
      set strike_count = strike_count + 1
      where user_id = new.student_id
      returning strike_count into new_count;

    if new_count >= 3 then
      update public.student_profiles
        set is_blocked = true, blocked_at = now(), blocked_by = new.author_id
        where user_id = new.student_id and is_blocked = false;

      insert into public.notifications (user_id, type, title, body)
      values (new.student_id, 'account_blocked', 'Account blocked',
              'Your account has been blocked after a 3rd strike. Contact an admin to resolve this.');
    end if;
  end if;
  return new;
end;
$$;
