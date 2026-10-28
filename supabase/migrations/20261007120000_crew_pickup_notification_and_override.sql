-- ============================================================
-- Crew notification + self-service pickup/drop-off time, with the
-- director as the default fallback.
--
-- Suzanne asked (10/7): when a group production reservation names a
-- crew member, does anything notify them? Can they set their own
-- pickup time? If they don't, does it correctly fall back to the
-- producer/director who made the reservation?
--
-- Answer found before writing anything: the schema already had two
-- of the three pieces, since the very first migration --
-- reservations.allow_individual_pickup_times (default false) and
-- reservation_crew.pickup_time_override/dropoff_time_override -- with
-- the exact fallback behavior Suzanne described already being the
-- default (a null override just means "use the reservation's shared
-- time"). There's even a crew_invitation value sitting unused in the
-- notification_type enum. None of it was ever wired up: no
-- notification ever fired, a named crew member couldn't even read
-- the parent reservation (only its director/staff could), and there
-- was no policy letting a crew member touch their own override
-- columns at all. This migration closes all three gaps; the frontend
-- changes (toggle + crew-member time picker) ride along in the same
-- pass, no separate migration needed for those.
-- ============================================================

-- --- 1. a crew member can now actually see the reservation they're
--        named on, not just their own reservation_crew row -------------
-- Previously reservations_own_or_staff only let the director
-- (student_id = auth.uid()) or staff+ read a reservation at all. A
-- named crew member could already read their own reservation_crew row
-- (reservation_crew_read_own_or_staff already covers this) but had no
-- way to join it to the reservation's own name/location/time -- RLS
-- would filter that row out before the join ever happened.
--
-- Caught during local validation, before this was ever pushed: a
-- first draft wrote this as a plain inline EXISTS against
-- reservation_crew, same shape as reservation_crew's own read policy.
-- That created real mutual RLS recursion, not just a theoretical risk
-- -- reservation_crew_read_own_or_staff already queries reservations
-- to let the director read the crew list, and once reservations'
-- OWN select policy started querying reservation_crew right back,
-- Postgres chased the two policies in a circle (reservations -> crew
-- -> reservations -> crew -> ...) until it errored with "infinite
-- recursion detected in policy for relation reservation_crew" on
-- every single query touching either table, including ones that
-- predate this migration entirely (the director's own crew-list
-- read). Fixed by routing the reservation_crew lookup through a
-- SECURITY DEFINER function instead of an inline subquery -- same
-- reasoning as item_unit_current_reservation() elsewhere in this
-- schema: a security definer function runs as its owner (postgres,
-- same as every migration), which bypasses RLS entirely for the
-- query inside it, so the chain stops there instead of re-entering
-- reservation_crew's own policies.
create or replace function public.reservation_has_crew_member(p_reservation_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.reservation_crew rc
    where rc.reservation_id = p_reservation_id and rc.user_id = p_user_id
  );
$$;

create policy reservations_read_crew_member on public.reservations
  for select using (
    public.reservation_has_crew_member(id, auth.uid())
  );

-- --- 2. a crew member can set their own pickup/drop-off time override,
--        and ONLY that -- never their own role or who they are --------
-- reservation_crew_update_own (migration 12) only ever let the
-- DIRECTOR edit the crew list (student_id = auth.uid()); a named crew
-- member had no update policy at all for their own row. This adds
-- one, gated on the reservation actually allowing individual times
-- and not yet in a terminal state where there's nothing left to pick
-- up or drop off -- deliberately narrower than the director's own
-- status window (denied/cancelled/completed only) since the
-- motivating case is setting a time AFTER a reservation auto-approves,
-- which is the common case, not before.
create policy reservation_crew_update_self_override on public.reservation_crew
  for update
  using (
    user_id = auth.uid()
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.allow_individual_pickup_times
        and r.status not in ('denied', 'cancelled', 'completed')
    )
  )
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.allow_individual_pickup_times
        and r.status not in ('denied', 'cancelled', 'completed')
    )
  );

-- RLS alone only makes the ROW reachable -- same lesson as
-- users_self_update_guard and reservations_student_cancel_guard
-- elsewhere in this schema. Without a column-level guard, a crew
-- member could use this same policy to rewrite their own user_id
-- (hijacking someone else's crew slot) or crew_role/is_producer. The
-- director (student_id = auth.uid()) and staff+ keep full,
-- unrestricted access to every column on this table, unchanged --
-- only a non-director, non-staff actor updating their OWN crew row
-- gets pinned to the two override columns.
create or replace function public.reservation_crew_self_override_guard()
returns trigger language plpgsql as $$
declare
  v_student_id uuid;
begin
  if auth.uid() is null or public.current_user_role() in ('staff', 'supervisor', 'admin') then
    return new; -- staff+, or no app-level actor at all (SQL Editor/service role): unrestricted, unchanged.
  end if;

  select student_id into v_student_id from public.reservations where id = new.reservation_id;
  if v_student_id = auth.uid() then
    return new; -- the director managing their own crew list: unrestricted, unchanged.
  end if;

  -- A named crew member updating their own row -- RLS already
  -- confines this to user_id = auth.uid(), so only the override times
  -- are theirs to change; everything else snaps back regardless of
  -- what the client sent in the same statement.
  new.user_id := old.user_id;
  new.crew_role := old.crew_role;
  new.is_producer := old.is_producer;
  return new;
end;
$$;
create trigger reservation_crew_self_override_guard
  before update on public.reservation_crew
  for each row execute function public.reservation_crew_self_override_guard();

-- --- 3. notify a crew member when they're actually named ---------------
-- crew_invitation has sat unused in notification_type since the very
-- first migration. Fires once per reservation_crew insert, skipped
-- for the director's own row (the actor adding themselves obviously
-- doesn't need telling) -- compared against auth.uid() directly
-- rather than the row's crew_role/is_producer, since a real Producer
-- crew member (a different person, also is_producer = true) must
-- still get notified.
create or replace function public.reservation_crew_notify_invite()
returns trigger security definer language plpgsql as $$
declare
  v_reservation record;
begin
  if new.user_id = auth.uid() then
    return new;
  end if;

  select reservation_name, allow_individual_pickup_times
    into v_reservation
    from public.reservations where id = new.reservation_id;

  insert into public.notifications (user_id, type, title, body, related_reservation_id)
  values (
    new.user_id,
    'crew_invitation',
    'Added to a reservation',
    case when v_reservation.allow_individual_pickup_times then
      format(
        'You''ve been named %s on "%s". You can set your own pickup/drop-off time in My Reservations -- if you don''t, it falls back to the reservation''s shared time.',
        new.crew_role, coalesce(v_reservation.reservation_name, 'a reservation')
      )
    else
      format(
        'You''ve been named %s on "%s". The reservation''s organizer is responsible for pickup and drop-off on this one.',
        new.crew_role, coalesce(v_reservation.reservation_name, 'a reservation')
      )
    end,
    new.reservation_id
  );
  return new;
end;
$$;
create trigger reservation_crew_notify_invite
  after insert on public.reservation_crew
  for each row execute function public.reservation_crew_notify_invite();
