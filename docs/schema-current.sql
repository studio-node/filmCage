-- ============================================================
-- The Film Cage — Current Database Schema (assembled for review)
-- Assembled: September 30, 2026
-- Database: PostgreSQL via Supabase (project oaopmujdbjswuytazhjs)
-- Auth:     Supabase Auth (auth.users)
--
-- WHAT THIS FILE IS
-- This is not a migration — it's a hand-assembled snapshot of the
-- schema as it exists right now, after all 10 real migrations have
-- been applied in order:
--   20260923163000_initial_schema
--   20260923174500_handle_new_user
--   20260923235600_seed_sample_catalog          (data only, no DDL)
--   20260924000000_reservation_items_student_insert
--   20260924010000_item_units_qr_code
--   20260924020000_condition_reviews_policies
--   20260924030000_remaining_table_policies
--   20260925000000_item_units_serial_number
--   20260930160000_fines_view_and_current_reservation_fix
--   20260930170000_fines_days_late_computed
--
-- It was built by applying all 10 migration files to a fresh local
-- Postgres database (with a stub auth.users/auth.uid()/auth.role())
-- and pg_dump'ing the result, then reorganizing that dump back into
-- the same commented, grouped-by-feature style as the original
-- initial_schema.sql migration, with notes on what changed since and
-- why. Every table, column, constraint, index, trigger, function and
-- RLS policy below is confirmed to match the dump byte-for-byte in
-- substance — nothing here is "what it should be," it's what's
-- actually live once migration 11 is pushed (see note below).
--
-- ONE THING NOT YET LIVE: this file includes migration 11
-- (20260930170000_fines_days_late_computed — the manual_amount column
-- and the days_late-is-computed version of fines_with_amount). As of
-- this writing that migration is written and locally validated but
-- NOT YET PUSHED to the real Supabase project. Everything else below
-- is confirmed live.
--
-- HOW TO USE THIS FOR THE TABLE-BY-TABLE REVIEW
-- Each section is one feature area, in the same order the original
-- schema introduced them. A "REVIEW NOTE" comment marks a spot we've
-- already flagged as a possible normalization issue but haven't
-- acted on — see the full list at the bottom too. Everything else is
-- the schema as-is, ready for you to mark up with what you're seeing
-- on the dashboard visualizer.
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================
-- pgcrypto is already enabled on every Supabase project (it's what
-- gen_random_uuid() below comes from) — not re-declared here.

-- ============================================================
-- ENUMS
-- ============================================================
create type user_role as enum ('student', 'staff', 'supervisor', 'admin', 'professor');
create type student_tier as enum ('beginner', 'intermediate', 'advanced');
create type strike_reason as enum ('damage', 'late_return', 'behavioral');
create type day_of_week_enum as enum ('monday','tuesday','wednesday','thursday','friday','saturday','sunday');
create type category_kind as enum ('direct', 'general');
-- 'missing' covers a unit that couldn't be found at return (or is
-- discovered missing later) — folded into the condition scale itself
-- rather than a separate boolean, and ranked worse than 'damaged'
-- (see item_units_condition_guard's rank_map below).
create type unit_condition as enum ('good', 'caution', 'damaged', 'missing');
create type reservation_status as enum (
  'pending', 'denied', 'waitlisted', 'waitlist_offered', 'cancelled',
  'awaiting_appointment', 'awaiting_schedule',
  'approved', 'active', 'completed'
);
create type checkout_phase as enum ('pickup', 'return');
create type fine_type as enum ('late_return', 'damage', 'missing', 'other');
create type fine_status as enum ('warning', 'active', 'on_hold', 'resolved');
create type notification_type as enum (
  'reservation_approved', 'reservation_denied', 'damage_alert', 'fine_issued',
  'waitlist_available', 'crew_invitation', 'strike_issued', 'account_blocked',
  'checkout_reminder', 'return_reminder', 'pre_meeting_scheduled', 'pre_meeting_completed',
  'account_suspended', 'condition_downgrade_flag', 'role_changed', 'tier_reconfirm_needed'
);
create type notification_channel as enum ('in_app', 'email');
create type semester_task_key as enum (
  'location_hours', 'closures', 'tier_reset', 'class_list', 'staff_roles',
  'recurring_equipment_requests' -- ask professors to (re)submit their ongoing/recurring equipment needs for the new semester
);
-- Queue state for a reservation waiting on an item_model that's fully
-- checked out. 'waiting' = in line; 'offered' = a unit just freed up
-- and this student has 48 hours to confirm; 'confirmed'/'declined'/
-- 'expired' are terminal outcomes for that offer.
create type waitlist_entry_status as enum ('waiting', 'offered', 'confirmed', 'declined', 'expired');

-- ============================================================
-- HELPER: touch updated_at
-- ============================================================
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
-- USERS
-- ============================================================
create table public.users (
  id                    uuid primary key references auth.users(id) on delete cascade,
  email                 text not null unique,
  full_name             text not null,
  role                  user_role not null default 'student',
  onboarding_completed  boolean not null default false,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create trigger users_set_updated_at before update on public.users
  for each row execute function public.set_updated_at();

-- Shared role lookup, used by nearly every policy/trigger below
-- instead of repeating the same subquery. Defined here (right after
-- public.users exists) rather than up with the other helpers, since
-- as a `language sql` function its body is validated against the
-- catalog at CREATE FUNCTION time.
create or replace function public.current_user_role()
returns user_role
language sql stable security definer
set search_path = public
as $$
  select role from public.users where id = auth.uid();
$$;

-- Only Admin can promote/demote to or from Supervisor/Admin.
create or replace function public.users_role_change_guard()
returns trigger language plpgsql as $$
begin
  if new.role = old.role then
    return new;
  end if;
  if (new.role in ('supervisor', 'admin') or old.role in ('supervisor', 'admin'))
     and public.current_user_role() <> 'admin' then
    raise exception 'Only an admin can change access levels to or from Supervisor or Admin.';
  end if;
  return new;
end;
$$;
create trigger users_role_change_guard
  before update of role on public.users
  for each row execute function public.users_role_change_guard();

-- Auto-provision public.users (and a student_profiles row) whenever
-- someone signs up through Supabase Auth. New signups always start as
-- 'student' — promotion is a separate, deliberate action guarded by
-- users_role_change_guard above.
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

-- ============================================================
-- LOCATIONS, HOURS, ACADEMIC CALENDAR & SEMESTER SETUP
-- ============================================================
create table public.locations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  building    text,
  room        text,
  address     text,
  is_active   boolean not null default true,
  created_by  uuid references public.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger locations_set_updated_at before update on public.locations
  for each row execute function public.set_updated_at();

create table public.location_hours (
  id                uuid primary key default gen_random_uuid(),
  location_id       uuid not null references public.locations(id) on delete cascade,
  day_of_week       day_of_week_enum not null,
  is_open           boolean not null default true,
  appointment_only  boolean not null default false,
  open_time         time,
  close_time        time,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (location_id, day_of_week),
  constraint open_hours_required check (
    (is_open = false) or (open_time is not null and close_time is not null)
  )
);
create trigger location_hours_set_updated_at before update on public.location_hours
  for each row execute function public.set_updated_at();

create table public.semesters (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,           -- e.g. "Fall 2026"
  start_date  date not null,
  end_date    date not null,
  is_current  boolean not null default false,
  created_by  uuid references public.users(id),
  created_at  timestamptz not null default now(),
  constraint semester_date_range check (end_date > start_date)
);
-- Only one semester can be "current" at a time.
create unique index semesters_one_current on public.semesters (is_current) where is_current;

create table public.academic_calendar (
  id          uuid primary key default gen_random_uuid(),
  semester_id uuid references public.semesters(id) on delete cascade,
  date        date not null,
  is_blocked  boolean not null default true,
  reason      text,                    -- e.g. "Thanksgiving Break"
  created_at  timestamptz not null default now(),
  unique (semester_id, date)
);

-- One-off, per-location closures that aren't holiday-driven
-- (e.g. "Studio C closed 10/3 for an AV upgrade").
create table public.location_closures (
  id           uuid primary key default gen_random_uuid(),
  location_id  uuid not null references public.locations(id) on delete cascade,
  date         date not null,
  reason       text not null,
  created_by   uuid references public.users(id),
  created_at   timestamptz not null default now(),
  unique (location_id, date)
);

create table public.course_tier_mappings (
  id             uuid primary key default gen_random_uuid(),
  course_name    text not null,        -- e.g. "Introduction to Media Production"
  course_code    text,                 -- e.g. "COMM 1010"
  tier           student_tier not null,
  display_order  int not null default 0,
  is_active      boolean not null default true,
  created_by     uuid references public.users(id),
  created_at     timestamptz not null default now()
);

create table public.semester_checklist_items (
  id           uuid primary key default gen_random_uuid(),
  semester_id  uuid not null references public.semesters(id) on delete cascade,
  task_key     semester_task_key not null,
  is_done      boolean not null default false,
  done_by      uuid references public.users(id),
  done_at      timestamptz,
  unique (semester_id, task_key)
);

-- ============================================================
-- STUDENT / PROFESSOR PROFILES & STRIKES
-- ============================================================
create table public.student_profiles (
  user_id                     uuid primary key references public.users(id) on delete cascade,
  tier                        student_tier not null default 'beginner',
  class_taken                 uuid references public.course_tier_mappings(id),
  strike_count                int not null default 0 check (strike_count >= 0),
  is_blocked                  boolean not null default false,
  checkout_suspended          boolean not null default false,
  suspended_at                timestamptz,
  suspended_reason            text,
  blocked_at                  timestamptz,
  blocked_by                  uuid references public.users(id),
  needs_tier_reconfirmation   boolean not null default false,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create trigger student_profiles_set_updated_at before update on public.student_profiles
  for each row execute function public.set_updated_at();

create or replace function public.student_profiles_unblock_guard()
returns trigger language plpgsql as $$
begin
  if old.is_blocked = true and new.is_blocked = false
     and public.current_user_role() <> 'admin'
  then
    raise exception 'Only an admin can remove a student block.';
  end if;
  return new;
end;
$$;
create trigger student_profiles_unblock_guard
  before update of is_blocked on public.student_profiles
  for each row execute function public.student_profiles_unblock_guard();

create table public.professor_profiles (
  user_id          uuid primary key references public.users(id) on delete cascade,
  employment_type  text,               -- e.g. "Full-time"
  created_at       timestamptz not null default now()
);

create table public.student_notes (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references public.users(id) on delete cascade,
  author_id      uuid not null references public.users(id),
  note_text      text not null,
  is_strike      boolean not null default false,
  strike_reason  strike_reason,
  created_at     timestamptz not null default now(),
  constraint strike_reason_required check (
    (is_strike = true  and strike_reason is not null) or
    (is_strike = false and strike_reason is null)
  )
);

-- 3rd strike auto-blocks the student and notifies them. security
-- definer because it writes student_profiles and notifications on
-- behalf of the student being struck, not the staff member logging
-- the note (fixed 9/30 — see REVIEW NOTE in RLS section below for
-- the bug this was silently hitting before the fix).
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
create trigger student_notes_apply_strike
  after insert on public.student_notes
  for each row execute function public.student_notes_apply_strike();

-- ============================================================
-- CATEGORIES & EQUIPMENT CATALOG
-- ============================================================
-- REVIEW NOTE: item_models has BOTH direct_category_id and
-- general_category_id (two FKs into the same categories table,
-- distinguished only by categories.kind). item_models_check_category_kinds
-- below exists purely to police that split. Splitting categories into
-- two tables (direct_categories / general_categories) would let a
-- plain FK do that job and remove this trigger — flagged as a
-- possible cleanup, not yet done.
create table public.categories (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  kind           category_kind not null,
  display_order  int not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (name, kind)
);

create table public.item_models (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  brand               text,
  model               text,
  purchase_price      numeric(10,2),
  picture_url         text,
  location_id         uuid not null references public.locations(id),
  description         text,
  direct_category_id  uuid references public.categories(id),
  general_category_id uuid references public.categories(id),
  min_tier            student_tier not null default 'beginner',
  youtube_url         text,
  is_active           boolean not null default true,
  created_by          uuid references public.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
-- A plain FK can't enforce "direct_category_id must point at a category
-- with kind = 'direct'" (and likewise for general_category_id), since
-- that depends on another column's value in the referenced row — so
-- it's enforced with a trigger instead of a CHECK/FK constraint.
create or replace function public.item_models_check_category_kinds()
returns trigger language plpgsql as $$
begin
  if new.direct_category_id is not null and not exists (
    select 1 from public.categories where id = new.direct_category_id and kind = 'direct'
  ) then
    raise exception 'direct_category_id must reference a category with kind = direct';
  end if;
  if new.general_category_id is not null and not exists (
    select 1 from public.categories where id = new.general_category_id and kind = 'general'
  ) then
    raise exception 'general_category_id must reference a category with kind = general';
  end if;
  return new;
end;
$$;
create trigger item_models_check_category_kinds
  before insert or update of direct_category_id, general_category_id on public.item_models
  for each row execute function public.item_models_check_category_kinds();

create trigger item_models_set_updated_at before update on public.item_models
  for each row execute function public.set_updated_at();

create table public.item_custom_attributes (
  id               uuid primary key default gen_random_uuid(),
  item_model_id    uuid not null references public.item_models(id) on delete cascade,
  attribute_name   text not null,
  attribute_value  text not null,
  created_at       timestamptz not null default now()
);

-- ============================================================
-- KITS
-- ============================================================
create table public.kits (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  description  text,
  location_id  uuid not null references public.locations(id),
  min_tier     student_tier not null default 'beginner',
  created_by   uuid references public.users(id),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger kits_set_updated_at before update on public.kits
  for each row execute function public.set_updated_at();

create table public.kit_items (
  id             uuid primary key default gen_random_uuid(),
  kit_id         uuid not null references public.kits(id) on delete cascade,
  item_model_id  uuid not null references public.item_models(id) on delete cascade,
  quantity       int not null default 1 check (quantity > 0),
  created_at     timestamptz not null default now(),
  unique (kit_id, item_model_id)
);

-- ============================================================
-- RESERVATIONS
-- ============================================================
create table public.reservations (
  id                          uuid primary key default gen_random_uuid(),
  reservation_name            text not null,          -- required v4 field, e.g. "FILM 2300, Interview Doc"
  student_id                  uuid not null references public.users(id),
  location_id                 uuid not null references public.locations(id),
  status                      reservation_status not null default 'pending',
  is_capstone                 boolean not null default false,
  capstone_appointment_date   date,
  appointment_completed       boolean not null default false,
  pickup_date                 date,
  pickup_time                 time,
  dropoff_date                date,
  dropoff_time                time,
  scheduled                   boolean not null default false,
  is_group_reservation        boolean not null default false,
  -- Crew reservations only. false (default): the crew comes together,
  -- or the director (the student who made the reservation) is
  -- responsible for picking up all equipment. true: each named crew
  -- member may set their own pickup/dropoff time for their assigned
  -- gear (see reservation_crew.pickup_time_override below).
  allow_individual_pickup_times boolean not null default false,
  denial_reason               text,
  admin_notes                 text,
  -- created_by may differ from student_id when staff/admin creates on a student's behalf
  created_by                  uuid not null references public.users(id),
  approved_by                 uuid references public.users(id),
  approved_at                 timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  -- No overlap/exclusion constraint: overlapping reservations are explicitly allowed.
  constraint dropoff_after_pickup check (
    is_capstone or pickup_date is null or dropoff_date is null or
    (dropoff_date > pickup_date) or
    (dropoff_date = pickup_date and dropoff_time > pickup_time)
  )
);
create trigger reservations_set_updated_at before update on public.reservations
  for each row execute function public.set_updated_at();
create index reservations_student_idx on public.reservations (student_id);
create index reservations_status_idx on public.reservations (status);

-- Computes whether a reservation needs staff approval and sets status
-- accordingly, so the client-side warning and DB enforcement can't drift.
create or replace function public.reservations_approval_guard()
returns trigger language plpgsql as $$
declare
  item_count int;
  loan_days int;
  requires_approval boolean := false;
begin
  if new.is_capstone then
    if tg_op = 'INSERT' then
      new.status := 'pending';
    end if;
    return new;
  end if;

  select coalesce(sum(quantity), 0) into item_count
    from public.reservation_items where reservation_id = new.id;

  if item_count > 20 then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 then
    requires_approval := true; -- Friday pickup
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
    requires_approval := true; -- Friday drop-off
  end if;

  if new.pickup_date is not null and new.pickup_date < current_date + 3 then
    requires_approval := true; -- under the 3-day minimum lead time
  end if;

  if new.pickup_date is not null and new.dropoff_date is not null then
    loan_days := new.dropoff_date - new.pickup_date;
    if loan_days > 3 then
      requires_approval := true; -- past the default 3-day loan window
    end if;
  end if;

  if requires_approval and new.status not in
    ('denied', 'active', 'completed', 'cancelled', 'waitlist_offered')
  then
    new.status := 'pending';
  end if;

  return new;
end;
$$;
create trigger reservations_approval_guard
  before insert or update of pickup_date, pickup_time, dropoff_date, dropoff_time on public.reservations
  for each row execute function public.reservations_approval_guard();
-- NOTE: item_count is read from reservation_items, which is normally
-- inserted right after the reservation row itself — the app is
-- expected to re-save the reservation (or otherwise re-fire this
-- trigger) after writing reservation_items in the same flow, so a
-- >20-item reservation is correctly flagged even though the count
-- wasn't known at INSERT time.

create table public.reservation_items (
  id              uuid primary key default gen_random_uuid(),
  reservation_id  uuid not null references public.reservations(id) on delete cascade,
  item_model_id   uuid not null references public.item_models(id),
  kit_id          uuid references public.kits(id),  -- set if this line was added via a kit
  quantity        int not null default 1 check (quantity > 0),
  created_at      timestamptz not null default now(),
  unique (reservation_id, item_model_id)
);

-- ============================================================
-- PER-UNIT INVENTORY & CONDITION
-- ============================================================
create table public.item_units (
  id                       uuid primary key default gen_random_uuid(),
  item_model_id            uuid not null references public.item_models(id) on delete cascade,
  unit_code                text not null,          -- e.g. "EQ-102-A"
  condition                unit_condition not null default 'good',
  condition_note           text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  -- qr_code: added 9/24. Nullable, no auto-generation — some equipment
  -- already has physical QR stickers from before this system existed,
  -- so staff type in (or scan in) the real code whenever one exists.
  qr_code                  text,
  -- serial_number: added 9/25. Deliberately NOT unique (unlike
  -- qr_code) — real-world manufacturer data transcribed by hand, not
  -- an identifier this system generates and relies on for lookups.
  serial_number            text,
  unique (item_model_id, unit_code),
  constraint item_units_qr_code_unique unique (qr_code)
);
create trigger item_units_set_updated_at before update on public.item_units
  for each row execute function public.set_updated_at();
create index item_units_model_idx on public.item_units (item_model_id);

create table public.reservation_units (
  reservation_id  uuid not null references public.reservations(id) on delete cascade,
  -- REVIEW NOTE: item_model_id here is redundant — it's always equal to
  -- item_units.item_model_id for the referenced unit_id, since a unit
  -- belongs to exactly one model. It's never null (no FK enforces
  -- that, but the app always sets it). Could be dropped and read via
  -- a join to item_units when needed. Same story below on
  -- condition_reviews.item_model_id.
  item_model_id   uuid not null references public.item_models(id),
  unit_id         uuid not null references public.item_units(id),
  created_at      timestamptz not null default now(),
  primary key (reservation_id, unit_id)
);

-- Was a stored current_reservation_id column, read by Browse Equipment
-- to decide "is this unit available" — but nothing in the app ever
-- wrote to it (Pickup/Return isn't built yet), so it could never
-- reflect reality once real checkouts start happening. Replaced 9/30
-- with a live derivation from reservation_units + reservation status,
-- so availability is always correct without anything needing to
-- remember to set/clear a pointer.
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

create view public.item_units_with_status as
select
  u.id, u.item_model_id, u.unit_code, u.condition, u.condition_note,
  u.qr_code, u.serial_number, u.created_at, u.updated_at,
  public.item_unit_current_reservation(u.id) as current_reservation_id
from public.item_units u;
-- The app reads item_units_with_status (not item_units directly) to
-- get current_reservation_id — see BrowseEquipmentView.vue.

-- Staff: downgrade only. Supervisor/Admin: either direction.
-- Any downgrade requires a note and creates a condition_reviews row.
-- A brand-new unit's initial condition needs a note but no review row.
create or replace function public.item_units_condition_guard()
returns trigger language plpgsql as $$
declare
  old_rank int;
  new_rank int;
  actor_role user_role;
  v_current_reservation_id uuid;
  -- 'missing' ranks below 'damaged' — the worst state a unit can be in.
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
    return new; -- no condition change on this update, nothing to guard
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
create trigger item_units_condition_guard
  before insert or update of condition on public.item_units
  for each row execute function public.item_units_condition_guard();

create table public.condition_reviews (
  id              uuid primary key default gen_random_uuid(),
  unit_id         uuid not null references public.item_units(id) on delete cascade,
  -- REVIEW NOTE: same redundancy as reservation_units.item_model_id above.
  item_model_id   uuid not null references public.item_models(id),
  reservation_id  uuid references public.reservations(id),   -- null for a manual edit outside a return
  student_id      uuid references public.users(id),
  condition       unit_condition not null,
  note            text,
  is_reviewed     boolean not null default false,
  reviewed_by     uuid references public.users(id),
  reviewed_at     timestamptz,
  created_at      timestamptz not null default now()
);

-- ============================================================
-- WAITLIST
-- Per-item queue for reservations that couldn't be granted the unit(s)
-- they need. The app decides *when* a reservation needs to join the
-- queue (checking item_units_with_status availability against the
-- request) and calls add_to_waitlist(); the functions below own the
-- queue mechanics from there.
-- ============================================================
create table public.waitlist_entries (
  id                uuid primary key default gen_random_uuid(),
  reservation_id    uuid not null references public.reservations(id) on delete cascade,
  item_model_id     uuid not null references public.item_models(id),
  student_id        uuid not null references public.users(id),
  status            waitlist_entry_status not null default 'waiting',
  queue_position    int not null,
  offered_at        timestamptz,
  offer_expires_at  timestamptz,   -- offered_at + 48 hours
  responded_at      timestamptz,
  created_at        timestamptz not null default now(),
  unique (reservation_id, item_model_id)
);
create index waitlist_entries_queue_idx
  on public.waitlist_entries (item_model_id, queue_position)
  where status = 'waiting';

-- add_to_waitlist(): called by the app once it determines a reservation
-- can't be granted the requested item right now.
create or replace function public.add_to_waitlist(
  p_reservation_id uuid, p_item_model_id uuid, p_student_id uuid
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_next_position int;
  v_id uuid;
begin
  select coalesce(max(queue_position), 0) + 1 into v_next_position
    from public.waitlist_entries where item_model_id = p_item_model_id;

  insert into public.waitlist_entries (reservation_id, item_model_id, student_id, queue_position)
  values (p_reservation_id, p_item_model_id, p_student_id, v_next_position)
  returning id into v_id;

  update public.reservations set status = 'waitlisted' where id = p_reservation_id;

  return v_id;
end;
$$;

-- Offers the next waiting entry for an item_model a 48-hour window to
-- confirm. Called when a unit frees up, and again after a decline/expiry
-- to move on to the next person in line.
create or replace function public.offer_next_waitlist_entry(p_item_model_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_entry record;
begin
  select * into v_entry
    from public.waitlist_entries
    where item_model_id = p_item_model_id and status = 'waiting'
    order by queue_position asc
    limit 1;

  if not found then
    return;
  end if;

  update public.waitlist_entries
    set status = 'offered', offered_at = now(), offer_expires_at = now() + interval '48 hours'
    where id = v_entry.id;

  -- Only offered when the reservation doesn't independently require
  -- staff approval (capstone / >20 items / lead-time / loan-window) —
  -- the app checks that before calling this function.
  update public.reservations set status = 'waitlist_offered' where id = v_entry.reservation_id;

  insert into public.notifications (user_id, type, title, body, related_reservation_id)
  values (
    v_entry.student_id, 'waitlist_available', 'Equipment now available',
    'An item you were waitlisted for is available. Confirm within 48 hours or it will be offered to the next student in line.',
    v_entry.reservation_id
  );
end;
$$;

-- Student confirms they still want the item — approves the reservation
-- directly, since offer_next_waitlist_entry only makes an offer when no
-- other approval trigger applies.
create or replace function public.confirm_waitlist_entry(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_reservation_id uuid;
begin
  update public.waitlist_entries
    set status = 'confirmed', responded_at = now()
    where id = p_entry_id and status = 'offered'
    returning reservation_id into v_reservation_id;

  if v_reservation_id is null then
    raise exception 'This waitlist offer is no longer available to confirm.';
  end if;

  update public.reservations
    set status = 'approved', approved_at = now(),
        admin_notes = coalesce(admin_notes || E'\n', '') || 'Auto-approved: confirmed from waitlist.'
    where id = v_reservation_id;
end;
$$;

-- Student declines — the reservation is cancelled and the item moves
-- down the list to the next waiting entry.
create or replace function public.decline_waitlist_entry(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_reservation_id uuid;
  v_item_model_id uuid;
begin
  update public.waitlist_entries
    set status = 'declined', responded_at = now()
    where id = p_entry_id and status = 'offered'
    returning reservation_id, item_model_id into v_reservation_id, v_item_model_id;

  if v_reservation_id is null then
    raise exception 'This waitlist offer is no longer available to decline.';
  end if;

  update public.reservations set status = 'cancelled' where id = v_reservation_id;

  perform public.offer_next_waitlist_entry(v_item_model_id);
end;
$$;

-- Meant to be invoked periodically (e.g. hourly, via pg_cron or a
-- Supabase Edge Function) — expires any offer left unanswered past its
-- 48-hour window and moves each one to the next person in line.
-- REVIEW NOTE: like escalate_late_fines used to be, this isn't wired
-- up to any scheduler yet — nothing calls it today.
create or replace function public.expire_stale_waitlist_offers()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  for r in
    select id, reservation_id, item_model_id
    from public.waitlist_entries
    where status = 'offered' and offer_expires_at < now()
  loop
    update public.waitlist_entries set status = 'expired', responded_at = now() where id = r.id;
    update public.reservations set status = 'cancelled' where id = r.reservation_id;
    perform public.offer_next_waitlist_entry(r.item_model_id);
  end loop;
end;
$$;

-- ============================================================
-- CREW / GROUP RESERVATIONS
-- ============================================================
create table public.reservation_crew (
  id              uuid primary key default gen_random_uuid(),
  reservation_id  uuid not null references public.reservations(id) on delete cascade,
  user_id         uuid not null references public.users(id),
  crew_role       text not null,   -- Director (default, set for the student who made the reservation) / Producer / Camera Operator / Sound / Gaffer-Lighting / Grip / Editor
  is_producer     boolean not null default false,
  -- Only meaningful when the parent reservation has
  -- allow_individual_pickup_times = true; otherwise this crew member
  -- follows the reservation's shared pickup_time/dropoff_time.
  pickup_time_override   time,
  dropoff_time_override  time,
  created_at      timestamptz not null default now(),
  unique (reservation_id, user_id)
);

create table public.reservation_assignments (
  reservation_id       uuid not null references public.reservations(id) on delete cascade,
  item_model_id        uuid not null references public.item_models(id),
  assigned_to_user_id  uuid not null references public.users(id),
  primary key (reservation_id, item_model_id)
);

-- ============================================================
-- PICKUP & RETURN
-- ============================================================
create table public.checkout_sessions (
  id                    uuid primary key default gen_random_uuid(),
  reservation_id        uuid not null references public.reservations(id) on delete cascade,
  phase                 checkout_phase not null,
  person_user_id        uuid references public.users(id),
  person_signature      text,
  person_confirmed_at   timestamptz,
  staff_user_id         uuid references public.users(id),
  staff_confirmed_at    timestamptz,
  created_at            timestamptz not null default now(),
  unique (reservation_id, phase)
);

create table public.return_item_statuses (
  reservation_id       uuid not null references public.reservations(id) on delete cascade,
  unit_id              uuid not null references public.item_units(id),
  condition_at_return  unit_condition not null,   -- condition_at_return = 'missing' replaces the old standalone is_missing flag
  note                 text,
  created_at           timestamptz not null default now(),
  primary key (reservation_id, unit_id)
);

-- ============================================================
-- FINES & HOLDS
--
-- days_late / rate_per_day / current_amount used to be stored columns,
-- kept correct only by remembering to call recalculate_fine_amount()
-- (and a daily escalate_late_fines() job that was never actually wired
-- up to a scheduler, so they were stale from the moment a fine was
-- created). All three are now computed live in fines_with_amount
-- below — nothing left to remember to keep in sync.
--
-- Not every fine is a per-day late fee: damage / missing / other fines
-- need a staff-entered dollar amount unrelated to elapsed days, so
-- manual_amount (a real column) holds that, and the view only applies
-- the day-based formula when fine_type = 'late_return'.
-- ============================================================
create table public.fines (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references public.users(id),
  reservation_id    uuid references public.reservations(id),
  unit_id           uuid references public.item_units(id),
  fine_type         fine_type not null,
  status            fine_status not null default 'warning',
  escalation_note   text,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz,
  resolved_by       uuid references public.users(id),
  -- manual_amount: added 9/30 (migration 11). Staff-entered amount;
  -- used as current_amount in the view below for every fine_type
  -- except late_return.
  manual_amount     numeric(10,2) not null default 0
);
create index fines_student_idx on public.fines (student_id);

-- Day 1 = $5, days 2-3 = $10/day, day 4+ = $25/day (flat per-day rate).
create or replace function public.fine_rate_for_day(p_day_number int)
returns numeric(10,2)
language sql immutable as $$
  select case
    when p_day_number <= 1 then 5.00
    when p_day_number <= 3 then 10.00
    else 25.00
  end;
$$;

-- Cumulative total across all days so far, given a days_late value.
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

-- days_late itself is computed too: (the day it was resolved, or today
-- if still open) minus the reservation's dropoff_date, for late_return
-- fines only. "Stop counting" is keyed off fines.resolved_at, not an
-- actual item-return timestamp (none exists yet — Pickup/Return isn't
-- built) — a fine put on 'on_hold' without being resolved keeps
-- accruing live. Worth revisiting once Pickup/Return exists and there's
-- a real return timestamp to key off of instead.
create or replace view public.fines_with_amount as
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
  f.resolved_by
from public.fines f
left join public.reservations r on r.id = f.reservation_id
left join lateral (
  select case
    when f.fine_type = 'late_return' and r.dropoff_date is not null
      then greatest(0, (coalesce(f.resolved_at::date, current_date) - r.dropoff_date))::int
    else null
  end as days_late
) computed on true;
-- The app reads fines_with_amount (not fines directly) to get
-- current_amount — see DashboardView.vue.

-- ============================================================
-- NOTIFICATIONS
-- ============================================================
create table public.notifications (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.users(id) on delete cascade,
  type                    notification_type not null,
  title                   text not null,
  body                    text,
  related_reservation_id  uuid references public.reservations(id),
  is_read                 boolean not null default false,
  channel                 notification_channel not null default 'in_app',
  created_at              timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, is_read);

-- ============================================================
-- RECURRING RESERVATIONS (professors / classes)
-- ============================================================
create table public.recurring_reservations (
  id             uuid primary key default gen_random_uuid(),
  professor_id   uuid not null references public.users(id),
  location_id    uuid not null references public.locations(id),
  semester_id    uuid references public.semesters(id),
  title          text not null,           -- e.g. "FILM 3400 — Tuesday Shoots"
  day_of_week    day_of_week_enum not null,
  start_date     date not null,
  end_date       date not null,
  pickup_time    time not null,
  return_time    time not null,
  status         reservation_status not null default 'pending',
  approved_by    uuid references public.users(id),
  approved_at    timestamptz,
  denial_reason  text,
  -- An admin can end an ongoing/recurring reservation at any time
  -- (e.g. the professor no longer needs the standing gear). Guarded
  -- below by recurring_reservations_end_guard so only Admin can set it.
  ended_at       timestamptz,
  ended_by       uuid references public.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint recurring_date_range check (end_date > start_date)
);
create trigger recurring_reservations_set_updated_at before update on public.recurring_reservations
  for each row execute function public.set_updated_at();

create or replace function public.recurring_reservations_end_guard()
returns trigger language plpgsql as $$
begin
  if new.ended_at is not null and old.ended_at is null then
    if public.current_user_role() <> 'admin' then
      raise exception 'Only an admin can end an ongoing (recurring) reservation.';
    end if;
    new.ended_by := auth.uid();
  end if;
  return new;
end;
$$;
create trigger recurring_reservations_end_guard
  before update of ended_at on public.recurring_reservations
  for each row execute function public.recurring_reservations_end_guard();

create table public.recurring_reservation_items (
  id                         uuid primary key default gen_random_uuid(),
  recurring_reservation_id  uuid not null references public.recurring_reservations(id) on delete cascade,
  item_model_id              uuid not null references public.item_models(id),
  quantity                   int not null default 1 check (quantity > 0),
  created_at                 timestamptz not null default now(),
  unique (recurring_reservation_id, item_model_id)
);

create table public.recurring_reservation_occurrences (
  id                         uuid primary key default gen_random_uuid(),
  recurring_reservation_id  uuid not null references public.recurring_reservations(id) on delete cascade,
  reservation_id             uuid references public.reservations(id),  -- null until generated
  occurrence_date            date not null,
  is_cancelled                boolean not null default false,
  cancellation_reason         text,
  created_at                  timestamptz not null default now(),
  unique (recurring_reservation_id, occurrence_date)
);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.users enable row level security;
alter table public.student_profiles enable row level security;
alter table public.locations enable row level security;
alter table public.location_hours enable row level security;
alter table public.location_closures enable row level security;
alter table public.categories enable row level security;
alter table public.item_models enable row level security;
alter table public.item_units enable row level security;
alter table public.kits enable row level security;
alter table public.kit_items enable row level security;
alter table public.reservations enable row level security;
alter table public.reservation_items enable row level security;
alter table public.reservation_units enable row level security;
alter table public.condition_reviews enable row level security;
alter table public.checkout_sessions enable row level security;
alter table public.fines enable row level security;
alter table public.notifications enable row level security;
alter table public.waitlist_entries enable row level security;
alter table public.recurring_reservations enable row level security;
alter table public.reservation_crew enable row level security;
alter table public.reservation_assignments enable row level security;
alter table public.student_notes enable row level security;
-- Note: item_units_with_status and fines_with_amount are plain views
-- (not materialized), so they run with the querying user's own RLS —
-- no separate policy needed for them.

-- Equipment browsing is open to every signed-in tier, prices included.
create policy item_models_read_all on public.item_models
  for select using (auth.role() = 'authenticated');
create policy item_units_read_all on public.item_units
  for select using (auth.role() = 'authenticated');
create policy locations_read_all on public.locations
  for select using (auth.role() = 'authenticated');
create policy kits_read_all on public.kits
  for select using (auth.role() = 'authenticated');
create policy categories_read_all on public.categories
  for select using (auth.role() = 'authenticated');

-- Catalog/inventory writes: Staff, Supervisor, Admin only.
create policy item_models_write_staff_up on public.item_models
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy item_units_write_staff_up on public.item_units
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy kits_write_staff_up on public.kits
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- location_hours / location_closures / kit_items: reference data,
-- same as locations/item_models/kits themselves.
create policy location_hours_read_all on public.location_hours
  for select using (auth.role() = 'authenticated');
create policy location_hours_write_staff_up on public.location_hours
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

create policy location_closures_read_all on public.location_closures
  for select using (auth.role() = 'authenticated');
create policy location_closures_write_staff_up on public.location_closures
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

create policy kit_items_read_all on public.kit_items
  for select using (auth.role() = 'authenticated');
create policy kit_items_write_staff_up on public.kit_items
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- Reservations: students see/manage only their own; Staff+ see everything.
create policy reservations_own_or_staff on public.reservations
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservations_insert_own_or_staff on public.reservations
  for insert with check (created_by = auth.uid());
-- A student may edit their own reservation only while it hasn't moved
-- past pending/waitlisted/awaiting_* into a staff-controlled status,
-- and never for a capstone (capstone edits go through the staff-run
-- pre-pickup meeting instead). Staff+ can always edit.
create policy reservations_update_own_editable_or_staff on public.reservations
  for update using (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid() and not is_capstone
      and status not in ('approved','active','completed','denied','cancelled','waitlist_offered')
    )
  );

-- reservation_items: readable via the parent reservation; a student may
-- add/edit/remove their own lines within that same editable window.
create policy reservation_items_via_reservation on public.reservation_items
  for select using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and (r.student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin'))
    )
  );
create policy reservation_items_insert_own on public.reservation_items
  for insert
  with check (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );
create policy reservation_items_update_own on public.reservation_items
  for update
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );
create policy reservation_items_delete_own on public.reservation_items
  for delete
  using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_id
        and r.student_id = auth.uid()
        and not r.is_capstone
        and r.status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

-- reservation_units: which physical unit is assigned to which
-- reservation. Readable by the reservation's own student or Staff+;
-- write stays Staff+ only — specific-unit assignment is deliberately
-- a staff/pickup-time step, not student-facing.
create policy reservation_units_read_own_or_staff on public.reservation_units
  for select using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_units.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_units_write_staff_up on public.reservation_units
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- condition_reviews: a student can see reviews on their own reservations; Staff+ manage everything.
create policy condition_reviews_read_own_or_staff on public.condition_reviews
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy condition_reviews_write_staff_up on public.condition_reviews
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- checkout_sessions: a pickup/return signature step. Readable by
-- either party on it or Staff+; write is Staff+ only for now — once
-- Pickup/Return is actually built, the student confirming their own
-- signature will need its own narrower WITH CHECK (person_user_id =
-- auth.uid(), touching only person_signature/person_confirmed_at)
-- rather than opening the whole row to student writes.
create policy checkout_sessions_read_own_or_staff on public.checkout_sessions
  for select using (
    person_user_id = auth.uid()
    or staff_user_id = auth.uid()
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy checkout_sessions_write_staff_up on public.checkout_sessions
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- fines: a student sees their own; Staff+ manage everything.
create policy fines_own_or_staff on public.fines
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy fines_write_staff_up on public.fines
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy fines_update_staff_up on public.fines
  for update using (public.current_user_role() in ('staff','supervisor','admin'));

-- notifications: strictly own-only, both directions — even Staff+
-- can't read another user's notifications. Any system-generated
-- notification written on behalf of another user (e.g. the 3-strike
-- block notice, or a waitlist offer) must go through a security
-- definer function, since there is deliberately no INSERT policy here.
create policy notifications_own_only on public.notifications
  for select using (user_id = auth.uid());
create policy notifications_update_own on public.notifications
  for update using (user_id = auth.uid());

-- waitlist_entries: a student sees their own entries; Staff+ see and manage everything.
create policy waitlist_entries_own_or_staff on public.waitlist_entries
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy waitlist_entries_write_staff_up on public.waitlist_entries
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy waitlist_entries_update_staff_up on public.waitlist_entries
  for update using (public.current_user_role() in ('staff','supervisor','admin'));
-- Note: the actual student-facing confirm/decline flow goes through
-- confirm_waitlist_entry() / decline_waitlist_entry() (security
-- definer), not a direct UPDATE from the student — so this UPDATE
-- policy being Staff+-only is intentional, not a gap.

-- recurring_reservations: a professor sees their own; Staff+ see and manage everything.
create policy recurring_reservations_own_or_staff on public.recurring_reservations
  for select using (
    professor_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy recurring_reservations_write_staff_up on public.recurring_reservations
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy recurring_reservations_update_staff_up on public.recurring_reservations
  for update using (public.current_user_role() in ('staff','supervisor','admin'));

-- reservation_crew: who's on a reservation's crew. Readable by that
-- crew member, the reservation's own student, or Staff+; write is
-- Staff+ only for now — a student self-managing their own crew list
-- would need its own policy once that flow is built.
create policy reservation_crew_read_own_or_staff on public.reservation_crew
  for select using (
    user_id = auth.uid()
    or exists (
      select 1 from public.reservations r
      where r.id = reservation_crew.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_crew_write_staff_up on public.reservation_crew
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- reservation_assignments: which crew member is responsible for which
-- item model on a reservation. Same shape as reservation_crew.
create policy reservation_assignments_read_own_or_staff on public.reservation_assignments
  for select using (
    assigned_to_user_id = auth.uid()
    or exists (
      select 1 from public.reservations r
      where r.id = reservation_assignments.reservation_id and r.student_id = auth.uid()
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservation_assignments_write_staff_up on public.reservation_assignments
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- student_notes: staff notes and strikes on a student's record.
-- Readable by that student (about themselves) or Staff+; write is
-- Staff+ only — students are never the author.
create policy student_notes_read_own_or_staff on public.student_notes
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy student_notes_write_staff_up on public.student_notes
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- student_profiles: everyone reads their own, Staff+ reads everyone's;
-- writes are Staff+ only (added 9/30 — see REVIEW NOTE below, this
-- table had RLS on with no write policy at all until then).
create policy student_profiles_own_or_staff on public.student_profiles
  for select using (
    user_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy student_profiles_write_staff_up on public.student_profiles
  for update using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

-- users: every signed-in user can read the directory; a user updates
-- their own row (role changes are further guarded by
-- users_role_change_guard above), or an admin updates anyone's.
create policy users_read_all_authenticated on public.users
  for select using (auth.role() = 'authenticated');
create policy users_update_self_or_admin on public.users
  for update using (id = auth.uid() or public.current_user_role() = 'admin');

-- ============================================================
-- SCHEMA REVIEW NOTES (as of 9/30/2026)
-- Open items flagged so far, roughly in priority order. Add what
-- you're seeing on the dashboard visualizer to this list.
-- ============================================================
-- 1. DONE 9/30: fines.days_late / rate_per_day / current_amount were
--    stored, drift-prone columns — replaced with fines_with_amount
--    (a view computing them live). Added fines.manual_amount for
--    non-late-return fine types.
-- 2. DONE 9/30: item_units.current_reservation_id was a stored,
--    never-written pointer — replaced with item_units_with_status
--    (a view deriving it live from reservation_units + reservation
--    status).
-- 3. DONE 9/30: student_profiles had RLS enabled with no write policy
--    at all — student_notes_apply_strike()'s own UPDATE to it was
--    being silently dropped to zero rows, so the 3-strike auto-block
--    had never actually worked against a real (non-superuser)
--    connection. Fixed with student_profiles_write_staff_up, and by
--    making student_notes_apply_strike() security definer (it also
--    writes notifications on behalf of the student being struck,
--    which has the same "no INSERT policy" shape — notifications is
--    deliberately own-only, so this was solved with security definer
--    rather than opening a policy).
-- 4. NOT YET DONE: reservation_units.item_model_id and
--    condition_reviews.item_model_id are both redundant with
--    item_units.item_model_id (a unit belongs to exactly one model).
--    Low risk/low priority — could be dropped and read via a join to
--    item_units when needed, but nothing is broken today.
-- 5. NOT YET DONE: item_models has direct_category_id and
--    general_category_id, both FKs into the same categories table,
--    policed only by the item_models_check_category_kinds trigger.
--    Splitting categories into two tables (direct_categories /
--    general_categories) would let a plain FK do that job instead and
--    remove the trigger. Bigger change, not urgent.
-- 6. Two background jobs are referenced in comments but not wired up
--    to any scheduler yet: escalate_late_fines() (removed in the
--    days_late-computed migration, since nothing ever called it) and
--    expire_stale_waitlist_offers() (still present, still unwired).
--    Worth deciding whether these need pg_cron / a Supabase Edge
--    Function before Pickup/Return and the waitlist UI go live, or
--    whether they're handled another way.
-- ============================================================
