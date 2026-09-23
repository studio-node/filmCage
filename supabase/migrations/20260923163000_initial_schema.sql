-- ============================================================
-- The Film Cage — Database Schema
-- Version: 2.1  |  September 2026
-- Database: PostgreSQL via Supabase
-- Auth:     Supabase Auth (auth.users)
--
-- Supersedes the July 2026 v1.0 draft to match the finalized
-- September mockup. The two structural changes from v1.0: equipment
-- is tracked per physical unit (item_models + item_units) instead of
-- a quantity counter, and the role hierarchy grows to
-- student / staff / supervisor / admin / professor.
--
-- v2.1 folds in the client-feedback round from 9/23: per-crew-member
-- pickup time overrides, fine-escalation rates, 3-strike auto-block,
-- a "missing" unit condition, the waitlist offer/expiry workflow, and
-- admin-only termination of recurring (ongoing) reservations.
--
-- Full rationale per section: docs/schema-design.md
-- One question is still open (whether capstone pre-pickup meetings
-- can be handled by Staff/Supervisor or must be Admin-only) — see
-- that doc's "Open questions" section. It has no schema impact either
-- way, so it isn't blocking this migration.
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================
create extension if not exists "pgcrypto"; -- gen_random_uuid()

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

-- ============================================================
-- CATEGORIES & EQUIPMENT CATALOG
-- ============================================================
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
-- (item_units references reservations for current_reservation_id,
--  so reservations is created before item_units.)
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
  current_reservation_id   uuid references public.reservations(id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (item_model_id, unit_code)
);
create trigger item_units_set_updated_at before update on public.item_units
  for each row execute function public.set_updated_at();
create index item_units_model_idx on public.item_units (item_model_id);
create index item_units_reservation_idx on public.item_units (current_reservation_id);

create table public.reservation_units (
  reservation_id  uuid not null references public.reservations(id) on delete cascade,
  item_model_id   uuid not null references public.item_models(id),
  unit_id         uuid not null references public.item_units(id),
  created_at      timestamptz not null default now(),
  primary key (reservation_id, unit_id)
);

create table public.condition_reviews (
  id              uuid primary key default gen_random_uuid(),
  unit_id         uuid not null references public.item_units(id) on delete cascade,
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
-- queue (checking item_units availability against the request) and
-- calls add_to_waitlist(); the functions below own the queue mechanics
-- from there (see BUSINESS-RULE FUNCTIONS & TRIGGERS).
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
-- ============================================================
create table public.fines (
  id                uuid primary key default gen_random_uuid(),
  student_id        uuid not null references public.users(id),
  reservation_id    uuid references public.reservations(id),
  unit_id           uuid references public.item_units(id),
  fine_type         fine_type not null,
  status            fine_status not null default 'warning',
  days_late         int not null default 0,
  rate_per_day      numeric(10,2) not null default 0,
  current_amount    numeric(10,2) not null default 0,
  escalation_note   text,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz,
  resolved_by       uuid references public.users(id)
);
create index fines_student_idx on public.fines (student_id);

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
-- Carried forward from the v1.0 draft with light renames.
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
-- BUSINESS-RULE FUNCTIONS & TRIGGERS
-- ============================================================

-- Shared role lookup, used by every policy/trigger below instead of
-- repeating the same subquery.
create or replace function public.current_user_role()
returns user_role
language sql stable security definer
set search_path = public
as $$
  select role from public.users where id = auth.uid();
$$;

-- --- item_units: condition change permissions -----------------
-- Staff: downgrade only. Supervisor/Admin: either direction.
-- Any downgrade requires a note and creates a condition_reviews row.
-- A brand-new unit's initial condition needs a note but no review row.
create or replace function public.item_units_condition_guard()
returns trigger language plpgsql as $$
declare
  old_rank int;
  new_rank int;
  actor_role user_role;
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
    insert into public.condition_reviews (unit_id, item_model_id, reservation_id, student_id, condition, note)
    values (
      new.id, new.item_model_id, new.current_reservation_id,
      (select student_id from public.reservations where id = new.current_reservation_id),
      new.condition, new.condition_note
    );
  end if;

  return new;
end;
$$;
create trigger item_units_condition_guard
  before insert or update of condition on public.item_units
  for each row execute function public.item_units_condition_guard();

-- --- users: only Admin can promote/demote to or from Supervisor/Admin ---
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

-- --- reservations: scheduling & approval-trigger rules -----------------
-- Computes whether a reservation needs staff approval and sets status
-- accordingly, so the client-side warning and DB enforcement can't drift.
-- Fires only on plain student-facing inserts/updates of the schedule
-- fields; staff overrides that explicitly set status are respected.
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
-- inserted right after the reservation row itself — call
-- recompute_reservation_approval(reservation_id) (a thin wrapper around
-- the same logic, omitted here for brevity) after writing
-- reservation_items in the same transaction, so a >20-item reservation
-- is correctly flagged even though the count wasn't known at INSERT time.

-- --- recurring_reservations: only Admin can end an ongoing reservation ---
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

-- --- student_notes: 3rd strike auto-blocks the student -----------------
-- Resolving/removing a block is Admin-only, enforced separately by
-- student_profiles_unblock_guard below.
create or replace function public.student_notes_apply_strike()
returns trigger language plpgsql as $$
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

-- --- fines: escalating daily rate ---------------------------------------
-- Day 1 = $5, days 2-3 = $10/day, day 4+ = $25/day (flat per-day rate,
-- not cumulative-per-day-times-days — current_amount below is the sum
-- across all days so far).
-- OPEN QUESTION: no amount/day threshold has been specified yet for
-- auto-setting student_profiles.checkout_suspended off the back of an
-- escalating fine — left as a manual staff/admin action for now.
create or replace function public.fine_rate_for_day(p_day_number int)
returns numeric(10,2)
language sql immutable as $$
  select case
    when p_day_number <= 1 then 5.00
    when p_day_number <= 3 then 10.00
    else 25.00
  end;
$$;

create or replace function public.recalculate_fine_amount(p_fine_id uuid)
returns void language plpgsql as $$
declare
  v_days_late int;
  v_total numeric(10,2) := 0;
  v_day int;
begin
  select days_late into v_days_late from public.fines where id = p_fine_id;
  if v_days_late is null or v_days_late <= 0 then
    return;
  end if;
  for v_day in 1..v_days_late loop
    v_total := v_total + public.fine_rate_for_day(v_day);
  end loop;
  update public.fines
    set rate_per_day = public.fine_rate_for_day(v_days_late),
        current_amount = v_total
    where id = p_fine_id;
end;
$$;

-- Meant to be invoked once/day by an external scheduler (pg_cron or a
-- Supabase Edge Function on a cron trigger) — bumps days_late for every
-- open late_return fine and recalculates its amount.
create or replace function public.escalate_late_fines()
returns void language plpgsql as $$
declare
  r record;
begin
  for r in
    select id from public.fines
    where fine_type = 'late_return' and status in ('warning', 'active')
  loop
    update public.fines set days_late = days_late + 1 where id = r.id;
    perform public.recalculate_fine_amount(r.id);
  end loop;
end;
$$;

-- --- waitlist: offer / confirm / decline / expire -----------------------
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

-- Reservations: students see/manage only their own; Staff+ see everything.
create policy reservations_own_or_staff on public.reservations
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy reservations_insert_own_or_staff on public.reservations
  for insert with check (
    created_by = auth.uid()
  );
create policy reservations_update_own_editable_or_staff on public.reservations
  for update using (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (not is_capstone)
      and status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  );

create policy waitlist_entries_own_or_staff on public.waitlist_entries
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy waitlist_entries_write_staff_up on public.waitlist_entries
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy waitlist_entries_update_staff_up on public.waitlist_entries
  for update using (public.current_user_role() in ('staff','supervisor','admin'));

create policy recurring_reservations_own_or_staff on public.recurring_reservations
  for select using (
    professor_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy recurring_reservations_write_staff_up on public.recurring_reservations
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy recurring_reservations_update_staff_up on public.recurring_reservations
  for update using (public.current_user_role() in ('staff','supervisor','admin'));

create policy reservation_items_via_reservation on public.reservation_items
  for select using (
    exists (
      select 1 from public.reservations r where r.id = reservation_id
      and (r.student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin'))
    )
  );

create policy fines_own_or_staff on public.fines
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy fines_write_staff_up on public.fines
  for insert with check (public.current_user_role() in ('staff','supervisor','admin'));
create policy fines_update_staff_up on public.fines
  for update using (public.current_user_role() in ('staff','supervisor','admin'));

create policy notifications_own_only on public.notifications
  for select using (user_id = auth.uid());
create policy notifications_update_own on public.notifications
  for update using (user_id = auth.uid());

create policy users_read_all_authenticated on public.users
  for select using (auth.role() = 'authenticated');
create policy users_update_self_or_admin on public.users
  for update using (id = auth.uid() or public.current_user_role() = 'admin');

create policy student_profiles_own_or_staff on public.student_profiles
  for select using (
    user_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );

-- Remaining tables (location_hours, location_closures, kit_items,
-- reservation_units, condition_reviews, checkout_sessions,
-- reservation_crew, reservation_assignments, student_notes) follow the
-- same two patterns above (read: everyone or own-row; write: Staff+)
-- and are omitted here for length — flag if you want them spelled out
-- individually before this ships.

-- ============================================================
-- SEED DATA — CATEGORIES
-- ============================================================
insert into public.categories (name, kind, display_order) values
  ('Batteries',       'direct', 1),
  ('Cameras',         'direct', 2),
  ('Lenses',          'direct', 3),
  ('Lights',          'direct', 4),
  ('Light Stands',    'direct', 5),
  ('SD Cards',        'direct', 6),
  ('Sound Equipment',  'direct', 7),
  ('Camera Dept',     'general', 1),
  ('Sound Dept',      'general', 2),
  ('Misc',            'general', 3);

-- ============================================================
-- SEED DATA — COURSE TIER MAPPINGS (starter set — admin should update)
-- ============================================================
insert into public.course_tier_mappings (course_name, course_code, tier, display_order) values
  ('Introduction to Video Production',   'FILM 1010', 'beginner',     1),
  ('Intermediate Production',            'FILM 2500', 'intermediate', 2),
  ('Advanced Production',                'FILM 3400', 'intermediate', 3),
  ('Capstone Production',                'FILM 4800', 'advanced',     4);
