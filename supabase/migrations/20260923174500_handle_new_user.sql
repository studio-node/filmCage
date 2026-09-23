-- ============================================================
-- Auto-provision public.users (and a student_profiles row) whenever
-- someone signs up through Supabase Auth.
--
-- Without this, a new auth.users row has no matching public.users row,
-- so the app can't look up their role/name/tier — every fresh signup
-- would be invisible to the rest of the schema until someone manually
-- inserted a row for them.
--
-- New signups always start as 'student' (public.users.role's own
-- default) — promotion to staff/supervisor/admin, or marking someone a
-- professor, is a separate, deliberate action, guarded by
-- users_role_change_guard from the initial migration.
-- ============================================================
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

  insert into public.student_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
