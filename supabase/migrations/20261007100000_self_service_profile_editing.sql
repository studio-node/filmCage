-- ============================================================
-- Self-service profile editing — a student/staff/supervisor/admin
-- can now edit their own display name from the new profile drawer
-- (top nav bar), and a student can change which class they're
-- taking (which affects their equipment tier). Password changes go
-- straight through Supabase Auth client-side (supabase.auth.
-- updateUser({ password })) and need no schema change at all.
--
-- Two real gaps found while building this, both fixed here:
--
-- 1. public.users' existing self-update policy
--    (users_update_self_or_admin, from the initial schema) only
--    restricts WHICH ROWS a non-admin can update (their own) — it
--    does not restrict which COLUMNS. As written, before this
--    migration, any signed-in student could call the Supabase
--    client directly (not just through the UI) and set their own
--    role to 'admin', flip is_active, or change their email,
--    because RLS's USING/WITH CHECK only gate row reachability, not
--    column-level writes. This is the same "RLS makes the row
--    reachable, something else has to police what's actually
--    allowed to change" problem already documented for reservations
--    (see reservations_student_cancel_guard in migration 15) — same
--    fix shape: a BEFORE UPDATE trigger that pins every column
--    except the ones self-service editing is actually meant to
--    touch back to their old value, for anyone who isn't staff+.
--
-- 2. public.user_profiles never had a self-update policy at all
--    (only user_profiles_write_staff_up, staff+ only) — a student
--    couldn't change their own class_taken even though the catalog
--    schema was clearly designed to support it
--    (course_tier_mappings + needs_tier_reconfirmation already
--    existed). Added a self-update policy, guarded the same way as
--    #1: a non-staff actor can only change class_taken, never tier
--    or any of the accountability columns (strike_count, blocks,
--    suspensions) directly.
--
-- Per Suzanne (10/7): a student picking a new class should NOT
-- instantly change their tier — it flags the account
-- (needs_tier_reconfirmation = true) for staff to review and
-- confirm from the Dashboard's new "Pending tier changes" card,
-- same as the already-designed reconfirmation flag implies. tier
-- itself only ever changes through that staff confirmation (or
-- direct staff edit), never through the student's own update.
-- ============================================================

-- --- #1: users self-update guard -----------------------------------
create or replace function public.users_self_update_guard()
returns trigger language plpgsql as $$
begin
  -- auth.uid() is null for anything running outside a real app
  -- session with a JWT -- the Supabase SQL Editor, a service-role
  -- script, this migration's own validation harness run as the
  -- Postgres superuser. None of that is "a non-staff user editing
  -- their own row" (there's no "self" at all), so it stays fully
  -- trusted, same as staff+ -- this restriction exists only to stop
  -- an authenticated, non-privileged APP user from writing to
  -- columns their own profile drawer shouldn't expose.
  if auth.uid() is null or public.current_user_role() in ('staff', 'supervisor', 'admin') then
    return new; -- staff+ (or no app-level actor at all) keep full write access, unchanged.
  end if;
  -- Below this point: a non-staff actor updating their own row (the
  -- only row users_update_self_or_admin's USING clause lets them
  -- reach at all). Self-service profile editing only covers the
  -- display name — email, role, active status, and onboarding state
  -- all stay pinned to their prior value no matter what the client
  -- sends.
  new.email := old.email;
  new.role := old.role;
  new.onboarding_completed := old.onboarding_completed;
  new.is_active := old.is_active;
  return new;
end;
$$;
create trigger users_self_update_guard
  before update on public.users
  for each row execute function public.users_self_update_guard();

-- --- #2: user_profiles self-update policy + guard ------------------
create policy user_profiles_self_update on public.user_profiles
  for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.user_profiles_self_update_guard()
returns trigger language plpgsql as $$
begin
  -- Same auth.uid()-is-null reasoning as users_self_update_guard above.
  if auth.uid() is null or public.current_user_role() in ('staff', 'supervisor', 'admin') then
    return new; -- staff+ (or no app-level actor at all) keep full write access, unchanged.
  end if;
  -- Below this point: a non-staff actor updating their own profile
  -- row. Only class_taken may actually change. tier never moves
  -- through self-service — picking a new class just flags the
  -- account for staff to review (see the Dashboard's "Pending tier
  -- changes" card) and sets/clears needs_tier_reconfirmation based
  -- on whether the class actually changed, regardless of whatever
  -- value the client itself sent for that column.
  new.strike_count := old.strike_count;
  new.is_blocked := old.is_blocked;
  new.checkout_suspended := old.checkout_suspended;
  new.suspended_at := old.suspended_at;
  new.suspended_reason := old.suspended_reason;
  new.blocked_at := old.blocked_at;
  new.blocked_by := old.blocked_by;
  new.tier := old.tier;

  if new.class_taken is distinct from old.class_taken then
    new.needs_tier_reconfirmation := true;
  else
    new.needs_tier_reconfirmation := old.needs_tier_reconfirmation;
  end if;

  return new;
end;
$$;
create trigger user_profiles_self_update_guard
  before update on public.user_profiles
  for each row execute function public.user_profiles_self_update_guard();
