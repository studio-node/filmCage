-- ============================================================
-- "Personal use" + different-person checkout rule, confirmed 10/4.
--
-- A Staff+ account can book equipment for their own personal use
-- (not an official/department purpose) via reservations.is_personal_use.
-- When set, whoever picks it up or returns it must be a different
-- person than who it's for — at every Staff+ level, not just Admin.
--
-- Two triggers, not a plain CHECK on either table, since each one
-- needs to look at a column on a *different* table than the one it's
-- enforcing against (same shape as the user_profiles role-fields
-- guard).
-- ============================================================

alter table public.reservations
  add column is_personal_use boolean not null default false;

create or replace function public.reservations_personal_use_guard()
returns trigger language plpgsql as $$
declare
  v_role user_role;
begin
  if new.is_personal_use then
    select role into v_role from public.users where id = new.student_id;
    if v_role not in ('staff','supervisor','admin') then
      raise exception 'is_personal_use is only valid for a staff, supervisor, or admin reservation';
    end if;
  end if;
  return new;
end;
$$;
create trigger reservations_personal_use_guard
  before insert or update of is_personal_use, student_id on public.reservations
  for each row execute function public.reservations_personal_use_guard();

create or replace function public.checkout_sessions_personal_use_guard()
returns trigger language plpgsql as $$
declare
  v_is_personal boolean;
begin
  select is_personal_use into v_is_personal
    from public.reservations where id = new.reservation_id;
  if v_is_personal and new.person_user_id is not null and new.person_user_id = new.staff_user_id then
    raise exception 'personal-use reservations require a different staff member for pickup/return';
  end if;
  return new;
end;
$$;
create trigger checkout_sessions_personal_use_guard
  before insert or update on public.checkout_sessions
  for each row execute function public.checkout_sessions_personal_use_guard();
