-- ============================================================
-- Migration 32 — Users page (staff+): account management + fine resolution
-- ============================================================
-- Suzanne, 11/18: a new staff+ "Users" page with two tabs, Users and
-- Fine Resolution. Admin edits a person's name, email, password, role,
-- tier and active state; staff+ resolve fines, issue damage/missing/
-- other fines, block/suspend accounts and log notes/strikes.
--
-- What this migration adds:
--   1. fines: how a fine was settled (paid / waived / reduced), the
--      amount actually collected, a required note, and a description
--      of what a manually issued fine is for. A fine can only become
--      'resolved' through resolve_fine(), and a resolved fine is locked
--      for everyone but admin.
--   2. issue_fine(): staff+ create a damage/missing/other fine with an
--      amount. The student is notified.
--   3. fines_with_amount: rebuilt as security_invoker (it used to run
--      with its owner's rights, so any signed-in user could read every
--      fine through it), with the new columns, and with a late fine's
--      day count frozen at the date it was created (= the return
--      check-in), not still growing until someone resolves it.
--   4. Admin-only account RPCs that have to touch auth.users, which the
--      browser can't reach: admin_update_user_account() (name + email),
--      admin_set_user_password(), admin_set_user_active() (deactivate =
--      sign-in blocked through auth.users.banned_until).
--   5. user_profiles: blocked_at/by and suspended_at are stamped by a
--      trigger instead of trusted from the client, and cleared on
--      unblock/unsuspend.
--   6. student_notes: author_id pinned to the real actor.
--
-- Role and tier changes need no new SQL: admin already has update
-- rights on users (users_update_self_or_admin) and staff+ on
-- user_profiles; the existing guards (users_role_change_guard,
-- users_role_change_clears_profile_fields, user_profiles_unblock_guard)
-- keep applying.
-- ============================================================

-- ------------------------------------------------------------
-- 1. fines: resolution columns
-- ------------------------------------------------------------
create type public.fine_resolution as enum ('paid', 'waived', 'reduced');

alter type public.notification_type add value if not exists 'fine_resolved';

alter table public.fines
  add column resolution_method public.fine_resolution,
  add column amount_paid numeric(10,2),
  add column resolution_note text,
  add column description text;

alter table public.fines
  add constraint fines_resolution_only_when_resolved check (
    status = 'resolved' or (resolution_method is null and amount_paid is null)
  ),
  add constraint fines_amount_paid_nonnegative check (amount_paid is null or amount_paid >= 0),
  add constraint fines_manual_amount_nonnegative check (manual_amount >= 0);

-- Guard every write to fines.
--   INSERT: issued_by pinned to the actor; can't be born resolved;
--           a non-late fine needs a positive amount.
--   UPDATE: a resolved fine is locked unless the actor is admin (or a
--           direct SQL session); becoming 'resolved' is only allowed
--           inside resolve_fine() (session flag, same pattern as
--           app.waitlist_confirming / app.return_completing).
create or replace function public.fines_guard()
returns trigger
language plpgsql
as $$
declare
  v_actor uuid := auth.uid();
  v_role  user_role := public.current_user_role();
  v_resolving boolean := coalesce(current_setting('app.fine_resolving', true), '') = 'true';
begin
  if tg_op = 'INSERT' then
    if v_actor is not null then
      new.issued_by := v_actor;
    end if;
    if new.status = 'resolved' or new.resolution_method is not null or new.resolved_at is not null then
      raise exception 'A new fine can''t start out resolved.';
    end if;
    if new.fine_type <> 'late_return' and coalesce(new.manual_amount, 0) <= 0 then
      raise exception 'A % fine needs an amount greater than $0.', new.fine_type;
    end if;
    return new;
  end if;

  -- UPDATE
  if v_actor is null then
    return new;  -- SQL editor / service role: fully trusted
  end if;

  if old.status = 'resolved' and v_role is distinct from 'admin' then
    raise exception 'This fine is already resolved. Only an admin can change it.';
  end if;

  if new.status = 'resolved' and old.status is distinct from 'resolved' and not v_resolving then
    raise exception 'Resolve a fine with the Resolve action so the method and note are recorded.';
  end if;

  -- issued_by / student / type never move after creation
  new.issued_by  := old.issued_by;
  new.student_id := old.student_id;
  new.fine_type  := old.fine_type;
  return new;
end;
$$;

create trigger fines_guard
  before insert or update on public.fines
  for each row execute function public.fines_guard();

-- ------------------------------------------------------------
-- 3. fines_with_amount (rebuilt; done before the RPCs that read it)
-- ------------------------------------------------------------
drop view if exists public.fines_with_amount;

create view public.fines_with_amount
with (security_invoker = true)
as
select
  f.id,
  f.student_id,
  f.reservation_id,
  f.unit_id,
  f.fine_type,
  f.status,
  computed.days_late,
  case when f.fine_type = 'late_return' then public.fine_rate_for_day(computed.days_late) else null end as rate_per_day,
  case when f.fine_type = 'late_return' then public.fine_current_amount(computed.days_late) else f.manual_amount end as current_amount,
  f.manual_amount,
  f.escalation_note,
  f.created_at,
  f.resolved_at,
  f.resolved_by,
  f.issued_by,
  f.resolution_method,
  f.amount_paid,
  f.resolution_note,
  f.description
from public.fines f
left join public.reservations r on r.id = f.reservation_id
left join lateral (
  select case
    -- Late fines are created at return check-in (submit/staff_confirm_return),
    -- so the fine's own creation date IS the day the gear came back.
    -- Counting stops there instead of running on until someone resolves it.
    when f.fine_type = 'late_return' and r.dropoff_date is not null
      then greatest(0, (least(f.created_at::date, coalesce(f.resolved_at::date, current_date)) - r.dropoff_date))::int
    else null
  end as days_late
) computed on true;

grant select on public.fines_with_amount to authenticated;

-- ------------------------------------------------------------
-- 1b. resolve_fine()
-- ------------------------------------------------------------
create or replace function public.resolve_fine(
  p_fine_id uuid,
  p_method public.fine_resolution,
  p_amount_paid numeric,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fine   public.fines_with_amount%rowtype;
  v_paid   numeric(10,2);
begin
  if public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Only staff can resolve fines.';
  end if;
  if p_note is null or btrim(p_note) = '' then
    raise exception 'Add a note explaining how this fine was resolved.';
  end if;

  select * into v_fine from public.fines_with_amount where id = p_fine_id;
  if not found then
    raise exception 'Fine not found.';
  end if;
  if v_fine.status = 'resolved' then
    raise exception 'This fine is already resolved.';
  end if;

  if p_method = 'paid' then
    v_paid := v_fine.current_amount;
  elsif p_method = 'waived' then
    v_paid := 0;
  else -- reduced
    if p_amount_paid is null or p_amount_paid <= 0 then
      raise exception 'Enter the reduced amount that was collected.';
    end if;
    if p_amount_paid >= v_fine.current_amount then
      raise exception 'A reduced amount has to be less than the full $%.', v_fine.current_amount;
    end if;
    v_paid := p_amount_paid;
  end if;

  perform set_config('app.fine_resolving', 'true', true);
  update public.fines
    set status = 'resolved',
        resolved_at = now(),
        resolved_by = auth.uid(),
        resolution_method = p_method,
        amount_paid = v_paid,
        resolution_note = btrim(p_note)
    where id = p_fine_id;
  perform set_config('app.fine_resolving', 'false', true);

  insert into public.notifications (user_id, type, title, body, related_reservation_id)
  values (
    v_fine.student_id, 'fine_resolved', 'Fine resolved',
    case p_method
      when 'paid'    then format('Your fine was marked paid ($%s).', v_paid)
      when 'waived'  then 'Your fine was waived.'
      else format('Your fine was reduced and resolved ($%s collected).', v_paid)
    end,
    v_fine.reservation_id
  );
end;
$$;

-- ------------------------------------------------------------
-- 2. issue_fine()
-- ------------------------------------------------------------
create or replace function public.issue_fine(
  p_student_id uuid,
  p_fine_type fine_type,
  p_amount numeric,
  p_description text,
  p_reservation_id uuid default null,
  p_unit_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if public.current_user_role() not in ('staff', 'supervisor', 'admin') then
    raise exception 'Only staff can issue fines.';
  end if;
  if p_fine_type = 'late_return' then
    raise exception 'Late-return fines are added at return check-in, not issued by hand.';
  end if;
  if p_description is null or btrim(p_description) = '' then
    raise exception 'Describe what the fine is for.';
  end if;
  if p_reservation_id is not null and not exists (
    select 1 from public.reservations r
    where r.id = p_reservation_id
      and (r.student_id = p_student_id
           or exists (select 1 from public.reservation_crew c
                      where c.reservation_id = r.id and c.user_id = p_student_id))
  ) then
    raise exception 'That reservation doesn''t belong to this person.';
  end if;

  insert into public.fines (student_id, reservation_id, unit_id, fine_type, status, manual_amount, description, issued_by)
  values (p_student_id, p_reservation_id, p_unit_id, p_fine_type, 'active', p_amount, btrim(p_description), auth.uid())
  returning id into v_id;

  insert into public.notifications (user_id, type, title, body, related_reservation_id)
  values (
    p_student_id, 'fine_issued', 'Fine added to your account',
    format('A %s fine of $%s was added: %s', replace(p_fine_type::text, '_', ' '), p_amount, btrim(p_description)),
    p_reservation_id
  );
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 4. Admin account RPCs (touch auth.users)
-- ------------------------------------------------------------
create or replace function public.admin_update_user_account(
  p_user_id uuid,
  p_full_name text,
  p_email text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(p_email));
  v_old_email text;
begin
  if public.current_user_role() is distinct from 'admin' then
    raise exception 'Only an admin can edit another person''s account details.';
  end if;
  if p_full_name is null or btrim(p_full_name) = '' then
    raise exception 'Name can''t be blank.';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.';
  end if;

  select email into v_old_email from public.users where id = p_user_id;
  if not found then
    raise exception 'User not found.';
  end if;

  if v_email <> lower(v_old_email) then
    if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user_id) then
      raise exception 'Another account already uses %.', v_email;
    end if;

    update auth.users set email = v_email, updated_at = now() where id = p_user_id;

    -- Keep the password-provider identity in step so sign-in by the
    -- new address works. (Skipped where auth.identities doesn't exist,
    -- e.g. the local test harness.)
    if to_regclass('auth.identities') is not null then
      execute $q$
        update auth.identities
          set identity_data = jsonb_set(coalesce(identity_data, '{}'::jsonb), '{email}', to_jsonb($1::text)),
              updated_at = now()
          where user_id = $2 and provider = 'email'
      $q$ using v_email, p_user_id;
    end if;
  end if;

  update public.users
    set full_name = btrim(p_full_name), email = v_email
    where id = p_user_id;
end;
$$;

create or replace function public.admin_set_user_password(
  p_user_id uuid,
  p_password text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.current_user_role() is distinct from 'admin' then
    raise exception 'Only an admin can set another person''s password.';
  end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'Password must be at least 8 characters.';
  end if;
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'User not found.';
  end if;

  update auth.users
    set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
        updated_at = now()
    where id = p_user_id;
end;
$$;

create or replace function public.admin_set_user_active(
  p_user_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_user_role() is distinct from 'admin' then
    raise exception 'Only an admin can deactivate or reactivate an account.';
  end if;
  if p_user_id = auth.uid() and not p_active then
    raise exception 'You can''t deactivate your own account.';
  end if;

  update public.users set is_active = p_active where id = p_user_id;
  if not found then
    raise exception 'User not found.';
  end if;

  -- Supabase Auth refuses sign-in (and token refresh) while
  -- banned_until is in the future.
  update auth.users
    set banned_until = case when p_active then null else timestamptz '2999-12-31 00:00:00+00' end,
        updated_at = now()
    where id = p_user_id;
end;
$$;

revoke execute on function public.admin_update_user_account(uuid, text, text) from public, anon;
revoke execute on function public.admin_set_user_password(uuid, text) from public, anon;
revoke execute on function public.admin_set_user_active(uuid, boolean) from public, anon;
revoke execute on function public.resolve_fine(uuid, public.fine_resolution, numeric, text) from public, anon;
revoke execute on function public.issue_fine(uuid, fine_type, numeric, text, uuid, uuid) from public, anon;
grant execute on function public.admin_update_user_account(uuid, text, text) to authenticated;
grant execute on function public.admin_set_user_password(uuid, text) to authenticated;
grant execute on function public.admin_set_user_active(uuid, boolean) to authenticated;
grant execute on function public.resolve_fine(uuid, public.fine_resolution, numeric, text) to authenticated;
grant execute on function public.issue_fine(uuid, fine_type, numeric, text, uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 5. user_profiles: stamp block/suspend metadata
-- ------------------------------------------------------------
create or replace function public.user_profiles_status_stamps()
returns trigger
language plpgsql
as $$
begin
  if new.is_blocked and not old.is_blocked then
    new.blocked_at := now();
    new.blocked_by := coalesce(auth.uid(), new.blocked_by);
  elsif not new.is_blocked and old.is_blocked then
    new.blocked_at := null;
    new.blocked_by := null;
  else
    new.blocked_at := old.blocked_at;
    new.blocked_by := old.blocked_by;
  end if;

  if new.checkout_suspended and not old.checkout_suspended then
    new.suspended_at := now();
    if new.suspended_reason is null or btrim(new.suspended_reason) = '' then
      raise exception 'Add a reason for suspending checkout.';
    end if;
  elsif not new.checkout_suspended and old.checkout_suspended then
    new.suspended_at := null;
    new.suspended_reason := null;
  elsif not new.checkout_suspended then
    new.suspended_at := null;
    new.suspended_reason := null;
  else
    new.suspended_at := old.suspended_at;
  end if;
  return new;
end;
$$;

create trigger user_profiles_status_stamps
  before update on public.user_profiles
  for each row execute function public.user_profiles_status_stamps();

-- ------------------------------------------------------------
-- 6. student_notes: author is always the real actor
-- ------------------------------------------------------------
create or replace function public.student_notes_author_guard()
returns trigger
language plpgsql
as $$
begin
  if auth.uid() is not null then
    new.author_id := auth.uid();
  end if;
  if btrim(coalesce(new.note_text, '')) = '' then
    raise exception 'A note can''t be blank.';
  end if;
  return new;
end;
$$;

create trigger student_notes_author_guard
  before insert on public.student_notes
  for each row execute function public.student_notes_author_guard();
