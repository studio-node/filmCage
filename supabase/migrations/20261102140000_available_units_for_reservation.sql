-- ============================================================
-- available_units_for_reservation(): the correct "what can I still
-- claim" list for the crew free-choice pickup screen.
--
-- A plain client-side query can't compute this correctly: item_units
-- is readable by everyone (item_units_read_all), but reservation_units
-- is only readable for a reservation the caller is actually on (their
-- own, their crew, or staff+) -- a crew member has no way to see
-- whether a given unit is already claimed on some OTHER, unrelated
-- reservation, which is exactly what submit_pickup's claim guard
-- (migration 25) checks server-side. Without this, the UI could offer
-- a unit that submit_pickup would then reject, misleading rather than
-- wrong -- but it's cheap to get this right instead.
--
-- SECURITY DEFINER so it can see every reservation_units row
-- regardless of whose it is (same justification as
-- item_unit_current_reservation(), 9/30) -- it only ever returns a
-- bare "still available" unit list, never any other reservation's
-- actual contents, and only to someone already authorized to be
-- picking up on p_reservation_id (its own student, a listed crew
-- member, or staff+) -- same actor check as submit_pickup itself.
-- ============================================================
create or replace function public.available_units_for_reservation(p_reservation_id uuid)
returns table (item_model_id uuid, unit_id uuid, unit_code text, condition public.unit_condition)
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_res record;
begin
  select * into v_res from public.reservations where id = p_reservation_id;
  if not found then
    return;
  end if;

  if v_actor <> v_res.student_id
     and not exists (
       select 1 from public.reservation_crew
       where reservation_id = p_reservation_id and user_id = v_actor
     )
     and public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Not authorized.';
  end if;

  return query
    select iu.item_model_id, iu.id, iu.unit_code, iu.condition
    from public.item_units iu
    join public.reservation_items ri
      on ri.item_model_id = iu.item_model_id and ri.reservation_id = p_reservation_id
    where iu.status = 'active'
      and not exists (select 1 from public.reservation_units ru where ru.unit_id = iu.id)
    order by iu.unit_code;
end;
$$;
