-- ============================================================
-- Collapse student_profiles + professor_profiles into one
-- user_profiles table, one row per public.users account regardless
-- of role.
--
-- Confirmed 10/4-10/5 during the schema review:
--  - The universal accountability fields (strike_count, is_blocked,
--    checkout_suspended, suspended_at/reason, blocked_at/by) are
--    meaningful for ANY role, not just students+instructors — a
--    staff/supervisor/admin account can now also pick up a
--    personal-use strike (see the reservations/checkout_sessions
--    migrations later in this review). Staff/supervisor/admin never
--    had a profile row at all before this.
--  - tier / class_taken / needs_tier_reconfirmation stay
--    student-only, left nullable for every other role and enforced
--    by the trigger below (not a plain CHECK — role lives on
--    public.users, not this table).
--  - professor_profiles.employment_type is NOT carried over at all —
--    confirmed there's no full-time/part-time distinction in
--    practice, just the role itself (renamed professor ->
--    class_instructor in an earlier migration). No replacement
--    column.
-- ============================================================

create table public.user_profiles (
  user_id                     uuid primary key references public.users(id) on delete cascade,
  strike_count                int not null default 0 check (strike_count >= 0),
  is_blocked                  boolean not null default false,
  checkout_suspended          boolean not null default false,
  suspended_at                timestamptz,
  suspended_reason            text,
  blocked_at                  timestamptz,
  blocked_by                  uuid references public.users(id),
  -- Student-only. Nullable for every other role; kept non-null for
  -- students by convention/backfill, and the trigger below rejects a
  -- non-null value here for anyone who isn't a student.
  tier                        student_tier default 'beginner',
  class_taken                 uuid references public.course_tier_mappings(id),
  needs_tier_reconfirmation   boolean default false,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create trigger user_profiles_set_updated_at before update on public.user_profiles
  for each row execute function public.set_updated_at();

-- Backfill: one row for every existing user, regardless of role —
-- this is what gives staff/supervisor/admin a profile row for the
-- first time. created_at defaults to the user's own created_at as a
-- reasonable stand-in for "when this profile started existing."
-- tier/needs_tier_reconfirmation are explicitly nulled here (rather
-- than left to their column defaults) so a non-student doesn't pick
-- up a stray 'beginner'/false value from this baseline insert — the
-- update below is what gives an actual student their real values.
insert into public.user_profiles (user_id, created_at, tier, needs_tier_reconfirmation)
select id, created_at, null, null from public.users
on conflict (user_id) do nothing;

-- Carry over the real history from student_profiles (strike counts,
-- blocks, suspensions, tier) onto the rows just created above.
-- professor_profiles has nothing left worth carrying over —
-- employment_type isn't coming along, and every account already got
-- a baseline row in the insert above.
update public.user_profiles up
set
  strike_count               = sp.strike_count,
  is_blocked                 = sp.is_blocked,
  checkout_suspended         = sp.checkout_suspended,
  suspended_at               = sp.suspended_at,
  suspended_reason           = sp.suspended_reason,
  blocked_at                 = sp.blocked_at,
  blocked_by                 = sp.blocked_by,
  tier                       = sp.tier,
  class_taken                = sp.class_taken,
  needs_tier_reconfirmation  = sp.needs_tier_reconfirmation,
  updated_at                 = sp.updated_at
from public.student_profiles sp
where up.user_id = sp.user_id;

alter table public.user_profiles enable row level security;

create policy user_profiles_own_or_staff on public.user_profiles
  for select using (
    user_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy user_profiles_write_staff_up on public.user_profiles
  for update using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- Same admin-only-can-unblock rule as before, just renamed/retargeted.
create or replace function public.user_profiles_unblock_guard()
returns trigger language plpgsql as $$
begin
  if old.is_blocked = true and new.is_blocked = false
     and public.current_user_role() <> 'admin'
  then
    raise exception 'Only an admin can unblock an account.';
  end if;
  return new;
end;
$$;
create trigger user_profiles_unblock_guard
  before update of is_blocked on public.user_profiles
  for each row execute function public.user_profiles_unblock_guard();

-- Enforce that tier/class_taken/needs_tier_reconfirmation stay null
-- for every role except student. Trigger, not a plain CHECK, because
-- role lives on public.users, a different table.
--
create or replace function public.user_profiles_role_fields_guard()
returns trigger language plpgsql as $$
declare
  v_role user_role;
begin
  select role into v_role from public.users where id = new.user_id;
  if v_role <> 'student' and (
    new.tier is not null or new.class_taken is not null or new.needs_tier_reconfirmation is not null
  ) then
    raise exception 'tier, class_taken, and needs_tier_reconfirmation are only valid for a student account';
  end if;
  return new;
end;
$$;
create trigger user_profiles_role_fields_guard
  before insert or update of tier, class_taken, needs_tier_reconfirmation on public.user_profiles
  for each row execute function public.user_profiles_role_fields_guard();

-- A role change on users.role doesn't touch user_profiles on its
-- own, so without this, a student promoted to staff/supervisor/admin
-- would keep their old tier/class_taken/needs_tier_reconfirmation
-- values (now stale, but still non-null) until something else wrote
-- to user_profiles — and the reverse, demoting someone back to
-- student, would leave them with no tier at all. This keeps the two
-- tables in sync automatically whenever role crosses the
-- student/non-student line. security definer so it isn't at the
-- mercy of whether the account doing the role change also happens to
-- satisfy user_profiles' own write policy (same reasoning as
-- student_notes_apply_strike below).
create or replace function public.users_role_change_clears_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role <> 'student' and old.role = 'student' then
    update public.user_profiles
      set tier = null, class_taken = null, needs_tier_reconfirmation = null
      where user_id = new.id;
  elsif new.role = 'student' and old.role <> 'student' then
    update public.user_profiles
      set tier = coalesce(tier, 'beginner'),
          needs_tier_reconfirmation = coalesce(needs_tier_reconfirmation, false)
      where user_id = new.id;
  end if;
  return new;
end;
$$;
create trigger users_role_change_clears_profile_fields
  after update of role on public.users
  for each row execute function public.users_role_change_clears_profile_fields();

-- handle_new_user() provisioned a student_profiles row for every new
-- signup; now provisions user_profiles instead. Every signup still
-- starts as 'student' (see users_role_change_guard), so this insert
-- is always valid against the role-fields guard above.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

  insert into public.user_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

-- student_notes_apply_strike() wrote directly to student_profiles;
-- now writes to user_profiles.
create or replace function public.student_notes_apply_strike()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  new_count int;
begin
  if new.is_strike then
    update public.user_profiles
      set strike_count = strike_count + 1
      where user_id = new.student_id
      returning strike_count into new_count;

    if new_count >= 3 then
      update public.user_profiles
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

-- Retire the old tables and their now-orphaned function.
drop table if exists public.professor_profiles;
drop table if exists public.student_profiles;
drop function if exists public.student_profiles_unblock_guard();
