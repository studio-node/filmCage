-- ============================================================
-- recurring_reservations_end_guard() restricted ending a recurring
-- reservation to Admin only, inconsistent with a plain reservation
-- (which any Staff+ can cancel). Confirmed 10/4: change to Staff+
-- for consistency.
-- ============================================================

create or replace function public.recurring_reservations_end_guard()
returns trigger language plpgsql as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    if public.current_user_role() not in ('staff','supervisor','admin') then
      raise exception 'Only Staff+ can end an ongoing (recurring) reservation.';
    end if;
    new.ended_by := auth.uid();
  end if;
  return new;
end;
$$;
