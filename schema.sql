-- ============================================================
-- Equipment Checkout System — Database Schema
-- Version: 1.0  |  July 2026
-- Database: PostgreSQL via Supabase
-- Auth: Supabase Auth (auth.users)
-- ============================================================

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role AS ENUM (
  'student', 'worker', 'admin', 'professor'
);

CREATE TYPE student_tier AS ENUM (
  'beginner', 'intermediate', 'advanced'
);

CREATE TYPE item_status AS ENUM (
  'green', 'yellow', 'red'
);

CREATE TYPE reservation_status AS ENUM (
  'draft',            -- auto-saved, not yet submitted
  'pending',          -- submitted, awaiting approval
  'approved',         -- approved, not yet picked up
  'denied',           -- denied; student can edit & resubmit
  'checked_out',      -- equipment currently with student
  'partially_returned',
  'returned',         -- all items returned
  'cancelled',        -- cancelled before pickup
  'deleted'           -- late no-show deletion (manual)
);

CREATE TYPE strike_reason AS ENUM (
  'damage', 'late_return', 'behavioral'
);

CREATE TYPE fine_type AS ENUM (
  'late_return', 'damage', 'other'
);

CREATE TYPE day_of_week_enum AS ENUM (
  'monday', 'tuesday', 'wednesday', 'thursday',
  'friday', 'saturday', 'sunday'
);

CREATE TYPE notification_type AS ENUM (
  'reservation_approved',
  'reservation_denied',
  'damage_alert',
  'fine_issued',
  'waitlist_available',
  'crew_invitation',
  'strike_issued',
  'account_blocked',
  'checkout_reminder',
  'return_reminder',
  'pre_meeting_scheduled',
  'pre_meeting_completed',
  'account_suspended'   -- checkout suspended due to fine threshold
);

-- ============================================================
-- USERS & PROFILES
-- ============================================================

-- Public profile extending Supabase auth.users.
-- auth.users is created automatically on signup via Supabase Auth.
CREATE TABLE public.users (
  id              UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           TEXT        NOT NULL UNIQUE,
  full_name       TEXT        NOT NULL,
  role                  user_role   NOT NULL DEFAULT 'student',
  onboarding_completed  BOOLEAN     NOT NULL DEFAULT FALSE,
  is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Student-specific data (tier, strikes, suspension)
CREATE TABLE public.student_profiles (
  user_id               UUID        PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  tier                  student_tier NOT NULL DEFAULT 'beginner',
  strike_count          INT         NOT NULL DEFAULT 0 CHECK (strike_count >= 0),
  is_blocked            BOOLEAN     NOT NULL DEFAULT FALSE,    -- admin hard-block
  checkout_suspended    BOOLEAN     NOT NULL DEFAULT FALSE,    -- auto: outstanding fines > $25 (TBC with client)
  suspended_at          TIMESTAMPTZ,
  suspended_reason      TEXT,
  blocked_at            TIMESTAMPTZ,
  blocked_by            UUID        REFERENCES public.users(id),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Admin notes and strikes on a student
CREATE TABLE public.student_notes (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  admin_id      UUID        NOT NULL REFERENCES public.users(id),
  note_text     TEXT        NOT NULL,
  is_strike     BOOLEAN     NOT NULL DEFAULT FALSE,
  strike_reason strike_reason,                    -- required when is_strike = TRUE
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT strike_reason_required CHECK (
    (is_strike = TRUE  AND strike_reason IS NOT NULL) OR
    (is_strike = FALSE AND strike_reason IS NULL)
  )
);

-- Tracks semester invitations sent to students
CREATE TABLE public.user_invitations (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT        NOT NULL,
  semester_id UUID,                             -- FK added after semesters table is created
  invited_by  UUID        REFERENCES public.users(id),
  invited_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  accepted_at TIMESTAMPTZ,
  UNIQUE (email, semester_id)
);

-- Courses the onboarding question pulls from; maps course → tier
CREATE TABLE public.course_tier_mappings (
  id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  course_name   TEXT         NOT NULL,          -- e.g. "COMM 1010 — Introduction to Film"
  course_code   TEXT,                           -- e.g. "COMM 1010"
  tier          student_tier NOT NULL,
  display_order INT          NOT NULL DEFAULT 0,
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by    UUID         REFERENCES public.users(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ============================================================
-- LOCATIONS
-- ============================================================

CREATE TABLE public.locations (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  building    TEXT,
  room        TEXT,
  address     TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by  UUID        REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Per-location operating hours (pickup & dropoff windows by day of week)
CREATE TABLE public.location_hours (
  id              UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id     UUID             NOT NULL REFERENCES public.locations(id) ON DELETE CASCADE,
  day_of_week     day_of_week_enum,   -- NULL when this row is a specific-date override
  specific_date   DATE,               -- NULL when this row is a regular weekly schedule
  pickup_open     TIME,
  pickup_close    TIME,
  dropoff_open    TIME,
  dropoff_close   TIME,
  is_closed       BOOLEAN          NOT NULL DEFAULT FALSE,
  created_by      UUID             REFERENCES public.users(id),
  created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

  -- Must be one or the other, never both, never neither
  CONSTRAINT day_or_date CHECK (
    (day_of_week IS NOT NULL AND specific_date IS NULL) OR
    (day_of_week IS NULL     AND specific_date IS NOT NULL)
  ),
  UNIQUE (location_id, day_of_week),
  UNIQUE (location_id, specific_date)
);

-- ============================================================
-- SEMESTERS
-- ============================================================

CREATE TABLE public.semesters (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,             -- e.g. "Fall 2026", "Spring 2027"
  start_date  DATE        NOT NULL,
  end_date    DATE        NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT FALSE,
  created_by  UUID        REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_dates CHECK (end_date > start_date)
);

-- Only one semester can be active at a time.
-- Postgres partial unique index trick: only one TRUE allowed, NULLs are ignored.
CREATE UNIQUE INDEX one_active_semester ON public.semesters (is_active)
  WHERE is_active = TRUE;

-- Now that semesters exists, add FK to user_invitations
ALTER TABLE public.user_invitations
  ADD CONSTRAINT fk_invitation_semester
  FOREIGN KEY (semester_id) REFERENCES public.semesters(id);

-- ============================================================
-- ACADEMIC CALENDAR
-- ============================================================

-- Individual blocked dates (holidays, breaks, etc.) — entered manually by admin
-- Scoped per semester so Fall 2026 holidays don't bleed into Spring 2027.
CREATE TABLE public.academic_calendar (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  semester_id UUID        NOT NULL REFERENCES public.semesters(id) ON DELETE CASCADE,
  date        DATE        NOT NULL,
  is_blocked  BOOLEAN     NOT NULL DEFAULT TRUE,
  reason      TEXT,                               -- e.g. "Thanksgiving", "Spring Break Day 1"
  created_by  UUID        REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (semester_id, date)
);

-- Global pickup/dropoff window rules by item count threshold
-- (currently: <25 items = 10am-5pm; 25+ items = pickup 2-5pm, dropoff 8-10am)
CREATE TABLE public.pickup_window_rules (
  id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  min_items     INT     NOT NULL DEFAULT 0,
  max_items     INT,                              -- NULL = no upper limit
  window_type   TEXT    NOT NULL CHECK (window_type IN ('pickup', 'dropoff')),
  start_time    TIME    NOT NULL,
  end_time      TIME    NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed data — matches requirements
INSERT INTO public.pickup_window_rules
  (min_items, max_items, window_type, start_time, end_time)
VALUES
  (0,  24,   'pickup',  '10:00', '17:00'),
  (25, NULL,  'pickup',  '14:00', '17:00'),
  (0,  24,   'dropoff', '10:00', '17:00'),
  (25, NULL,  'dropoff', '08:00', '10:00');

-- ============================================================
-- ITEMS & KITS
-- ============================================================

CREATE TABLE public.categories (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.items (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT        NOT NULL,
  brand           TEXT,
  model           TEXT,
  purchase_price  NUMERIC(10,2),
  picture_url     TEXT,
  location_id     UUID        NOT NULL REFERENCES public.locations(id),
  description     TEXT,
  status          item_status NOT NULL DEFAULT 'green',
  status_notes    TEXT,                           -- notes when yellow or red
  min_tier        student_tier NOT NULL DEFAULT 'beginner',
  quantity_total  INT         NOT NULL DEFAULT 1 CHECK (quantity_total >= 0),
  youtube_url     TEXT,                           -- optional demo/tutorial link
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_by      UUID        REFERENCES public.users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Many-to-many: items ↔ categories
CREATE TABLE public.item_categories (
  item_id     UUID NOT NULL REFERENCES public.items(id) ON DELETE CASCADE,
  category_id UUID NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,
  PRIMARY KEY (item_id, category_id)
);

-- Freeform key/value attributes per item
CREATE TABLE public.item_custom_attributes (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id         UUID        NOT NULL REFERENCES public.items(id) ON DELETE CASCADE,
  attribute_name  TEXT        NOT NULL,
  attribute_value TEXT        NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.kits (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL,
  description TEXT,
  location_id UUID        NOT NULL REFERENCES public.locations(id),
  created_by  UUID        REFERENCES public.users(id),
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE public.kit_items (
  id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  kit_id      UUID    NOT NULL REFERENCES public.kits(id) ON DELETE CASCADE,
  item_id     UUID    NOT NULL REFERENCES public.items(id) ON DELETE CASCADE,
  quantity    INT     NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (kit_id, item_id)
);

-- ============================================================
-- RECURRING RESERVATIONS  (professors / classes)
-- ============================================================

-- Parent record defines the pattern (day + date range, ~16 weeks adjustable)
CREATE TABLE public.recurring_reservations (
  id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  professor_id    UUID                NOT NULL REFERENCES public.users(id),
  location_id     UUID                NOT NULL REFERENCES public.locations(id),
  semester_id     UUID                REFERENCES public.semesters(id),
  title           TEXT                NOT NULL,           -- e.g. "FILM 301 — Tuesday Shoots"
  day_of_week     day_of_week_enum    NOT NULL,
  start_date      DATE                NOT NULL,
  end_date        DATE                NOT NULL,           -- adjustable; default ~16 weeks out
  pickup_time     TIME                NOT NULL,
  return_time     TIME                NOT NULL,
  status          reservation_status  NOT NULL DEFAULT 'pending',
  approved_by     UUID                REFERENCES public.users(id),
  approved_at     TIMESTAMPTZ,
  denial_reason   TEXT,
  created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_date_range CHECK (end_date > start_date)
);

CREATE TABLE public.recurring_reservation_items (
  id                        UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  recurring_reservation_id  UUID    NOT NULL REFERENCES public.recurring_reservations(id) ON DELETE CASCADE,
  item_id                   UUID    NOT NULL REFERENCES public.items(id),
  quantity                  INT     NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (recurring_reservation_id, item_id)
);

-- ============================================================
-- RESERVATIONS
-- ============================================================

CREATE TABLE public.reservations (
  id                        UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id                UUID                NOT NULL REFERENCES public.users(id),
  location_id               UUID                NOT NULL REFERENCES public.locations(id),
  status                    reservation_status  NOT NULL DEFAULT 'draft',

  -- Both pickup and return are booked at reservation creation time
  pickup_date               DATE                NOT NULL,
  pickup_time               TIME                NOT NULL,
  return_date               DATE                NOT NULL,
  return_time               TIME                NOT NULL,

  is_capstone               BOOLEAN             NOT NULL DEFAULT FALSE,
  is_crew_reservation       BOOLEAN             NOT NULL DEFAULT FALSE,

  -- Link back to recurring parent if this was generated from one
  recurring_reservation_id  UUID                REFERENCES public.recurring_reservations(id),

  denial_reason             TEXT,
  admin_notes               TEXT,

  -- created_by may differ from student_id when admin/worker creates on student's behalf
  created_by                UUID                NOT NULL REFERENCES public.users(id),
  approved_by               UUID                REFERENCES public.users(id),
  approved_at               TIMESTAMPTZ,
  checked_out_by            UUID                REFERENCES public.users(id),
  checked_out_at            TIMESTAMPTZ,

  created_at                TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

  -- Return must be after pickup
  CONSTRAINT return_after_pickup CHECK (
    (return_date > pickup_date) OR
    (return_date = pickup_date AND return_time > pickup_time)
  ),

  -- Maximum 4-day checkout window (enforced at DB level)
  CONSTRAINT max_checkout_days CHECK (
    return_date <= pickup_date + INTERVAL '4 days'
  )
);

-- Items (and optional kit reference) within a reservation
CREATE TABLE public.reservation_items (
  id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id  UUID    NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  item_id         UUID    NOT NULL REFERENCES public.items(id),
  kit_id          UUID    REFERENCES public.kits(id),       -- set if item was added via a kit
  quantity        INT     NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reservation_id, item_id)
);

-- Individual occurrence rows generated from a recurring reservation pattern
CREATE TABLE public.recurring_reservation_occurrences (
  id                        UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  recurring_reservation_id  UUID    NOT NULL REFERENCES public.recurring_reservations(id) ON DELETE CASCADE,
  reservation_id            UUID    REFERENCES public.reservations(id),  -- NULL until generated
  occurrence_date           DATE    NOT NULL,
  is_cancelled              BOOLEAN NOT NULL DEFAULT FALSE,
  cancellation_reason       TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (recurring_reservation_id, occurrence_date)
);

-- ============================================================
-- CAPSTONE PRE-MEETINGS
-- ============================================================

CREATE TABLE public.capstone_premeetings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id  UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE UNIQUE,
  scheduled_at    TIMESTAMPTZ,
  scheduled_by    UUID        REFERENCES public.users(id),
  completed_at    TIMESTAMPTZ,
  completed_by    UUID        REFERENCES public.users(id),  -- worker/admin who marks it done
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- CREW / GROUP RESERVATIONS
-- ============================================================

-- The producer's parent reservation is the anchor; this table hangs off it
CREATE TABLE public.crew_reservations (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  producer_id     UUID        NOT NULL REFERENCES public.users(id),
  reservation_id  UUID        NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE UNIQUE,
  title           TEXT,                           -- e.g. "FILM 402 Final Project"
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Each crew member gets their own sub-reservation linked here
CREATE TABLE public.crew_members (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  crew_reservation_id   UUID        NOT NULL REFERENCES public.crew_reservations(id) ON DELETE CASCADE,
  student_id            UUID        NOT NULL REFERENCES public.users(id),
  role_title            TEXT        NOT NULL,     -- e.g. "Camera Operator", "Sound"
  -- Sub-reservation holds this member's items + their own pickup time
  member_reservation_id UUID        REFERENCES public.reservations(id),
  notified_at           TIMESTAMPTZ,              -- when crew invitation notification was sent
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (crew_reservation_id, student_id)
);

-- ============================================================
-- CHECKOUT & RETURNS
-- ============================================================

-- Records the dual-confirmation (student + worker) at pickup
CREATE TABLE public.checkouts (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id        UUID        NOT NULL REFERENCES public.reservations(id) UNIQUE,
  worker_id             UUID        REFERENCES public.users(id),
  student_confirmed_at  TIMESTAMPTZ,
  worker_confirmed_at   TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Records the dual-confirmation (student + worker) at return
CREATE TABLE public.returns (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id        UUID        NOT NULL REFERENCES public.reservations(id) UNIQUE,
  worker_id             UUID        REFERENCES public.users(id),
  student_confirmed_at  TIMESTAMPTZ,
  worker_confirmed_at   TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Per-item condition check at return (before vs. after)
CREATE TABLE public.return_item_statuses (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id         UUID        NOT NULL REFERENCES public.returns(id) ON DELETE CASCADE,
  item_id           UUID        NOT NULL REFERENCES public.items(id),
  condition_before  item_status NOT NULL,
  condition_after   item_status NOT NULL,
  notes             TEXT,
  is_missing        BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- WAITLIST
-- ============================================================

CREATE TABLE public.waitlist_entries (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  item_id       UUID        REFERENCES public.items(id) ON DELETE CASCADE,
  kit_id        UUID        REFERENCES public.kits(id) ON DELETE CASCADE,
  desired_date  DATE,
  notified_at   TIMESTAMPTZ,                      -- when "now available" notification was sent
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Must be waiting on either an item or a kit, not both
  CONSTRAINT item_or_kit_only CHECK (
    (item_id IS NOT NULL AND kit_id IS NULL) OR
    (item_id IS NULL AND kit_id IS NOT NULL)
  )
);

-- ============================================================
-- FINES
-- ============================================================

-- One row per fine event (late day, damage, etc.)
-- Total outstanding = SUM(amount) WHERE is_paid = FALSE AND is_removed = FALSE
-- Suspension threshold (TBC with client): outstanding > $25 → checkout_suspended = TRUE
CREATE TABLE public.fines (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id      UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  reservation_id  UUID        REFERENCES public.reservations(id),
  item_id         UUID        REFERENCES public.items(id),
  fine_type       fine_type   NOT NULL,
  amount          NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  days_late       INT,                            -- populated for late_return fines
  reason          TEXT        NOT NULL,
  is_paid         BOOLEAN     NOT NULL DEFAULT FALSE,
  is_removed      BOOLEAN     NOT NULL DEFAULT FALSE,   -- admin waived
  removed_by      UUID        REFERENCES public.users(id),
  removed_at      TIMESTAMPTZ,
  removal_reason  TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- NOTIFICATIONS
-- ============================================================

CREATE TABLE public.notifications (
  id                      UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 UUID                NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  type                    notification_type   NOT NULL,
  title                   TEXT                NOT NULL,
  body                    TEXT                NOT NULL,
  related_reservation_id  UUID                REFERENCES public.reservations(id) ON DELETE SET NULL,
  related_fine_id         UUID                REFERENCES public.fines(id) ON DELETE SET NULL,
  related_note_id         UUID                REFERENCES public.student_notes(id) ON DELETE SET NULL,
  is_read                 BOOLEAN             NOT NULL DEFAULT FALSE,
  read_at                 TIMESTAMPTZ,
  sent_via_email          BOOLEAN             NOT NULL DEFAULT FALSE,
  email_sent_at           TIMESTAMPTZ,
  created_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Users
CREATE INDEX idx_users_role         ON public.users(role);
CREATE INDEX idx_users_email        ON public.users(email);

-- Student profiles
CREATE INDEX idx_sp_tier            ON public.student_profiles(tier);
CREATE INDEX idx_sp_blocked         ON public.student_profiles(is_blocked);
CREATE INDEX idx_sp_suspended       ON public.student_profiles(checkout_suspended);

-- Student notes
CREATE INDEX idx_sn_student         ON public.student_notes(student_id);
CREATE INDEX idx_sn_strike          ON public.student_notes(student_id, is_strike);

-- Academic calendar
CREATE INDEX idx_cal_date           ON public.academic_calendar(date);
CREATE INDEX idx_cal_blocked        ON public.academic_calendar(is_blocked);

-- Items
CREATE INDEX idx_items_location     ON public.items(location_id);
CREATE INDEX idx_items_status       ON public.items(status);
CREATE INDEX idx_items_tier         ON public.items(min_tier);
CREATE INDEX idx_items_active       ON public.items(is_active);
CREATE INDEX idx_items_name_search  ON public.items USING gin(to_tsvector('english', name || ' ' || COALESCE(brand, '') || ' ' || COALESCE(model, '') || ' ' || COALESCE(description, '')));

-- Reservations
CREATE INDEX idx_res_student        ON public.reservations(student_id);
CREATE INDEX idx_res_location       ON public.reservations(location_id);
CREATE INDEX idx_res_status         ON public.reservations(status);
CREATE INDEX idx_res_pickup         ON public.reservations(pickup_date);
CREATE INDEX idx_res_return         ON public.reservations(return_date);
CREATE INDEX idx_res_capstone       ON public.reservations(is_capstone) WHERE is_capstone = TRUE;
CREATE INDEX idx_res_recurring      ON public.reservations(recurring_reservation_id);

-- Reservation items
CREATE INDEX idx_ri_reservation     ON public.reservation_items(reservation_id);
CREATE INDEX idx_ri_item            ON public.reservation_items(item_id);

-- Fines
CREATE INDEX idx_fines_student      ON public.fines(student_id);
CREATE INDEX idx_fines_unpaid       ON public.fines(student_id, is_paid, is_removed)
  WHERE is_paid = FALSE AND is_removed = FALSE;

-- Notifications
CREATE INDEX idx_notif_user         ON public.notifications(user_id);
CREATE INDEX idx_notif_unread       ON public.notifications(user_id, is_read)
  WHERE is_read = FALSE;

-- Waitlist
CREATE INDEX idx_wait_student       ON public.waitlist_entries(student_id);
CREATE INDEX idx_wait_item          ON public.waitlist_entries(item_id);
CREATE INDEX idx_wait_active        ON public.waitlist_entries(is_active) WHERE is_active = TRUE;

-- Crew
CREATE INDEX idx_crew_producer      ON public.crew_reservations(producer_id);
CREATE INDEX idx_crew_members_res   ON public.crew_members(crew_reservation_id);
CREATE INDEX idx_crew_members_stu   ON public.crew_members(student_id);

-- ============================================================
-- VIEWS
-- ============================================================

-- Outstanding fine totals per student (used for suspension logic)
CREATE OR REPLACE VIEW public.student_fine_totals AS
SELECT
  student_id,
  COALESCE(SUM(amount) FILTER (WHERE is_paid = FALSE AND is_removed = FALSE), 0) AS outstanding_balance,
  COUNT(*)           FILTER (WHERE is_paid = FALSE AND is_removed = FALSE)        AS unpaid_count
FROM public.fines
GROUP BY student_id;

-- Real-time item availability (total quantity minus currently checked-out qty)
CREATE OR REPLACE VIEW public.item_availability AS
SELECT
  i.id               AS item_id,
  i.name,
  i.location_id,
  i.status,
  i.quantity_total,
  i.quantity_total - COALESCE(out.qty, 0) AS quantity_available
FROM public.items i
LEFT JOIN (
  SELECT ri.item_id, SUM(ri.quantity) AS qty
  FROM public.reservation_items ri
  JOIN public.reservations r ON r.id = ri.reservation_id
  WHERE r.status = 'checked_out'
  GROUP BY ri.item_id
) out ON out.item_id = i.id
WHERE i.is_active = TRUE;

-- Kit availability
-- A kit is unavailable if any of its required items have 0 qty available AND no duplicates
CREATE OR REPLACE VIEW public.kit_availability AS
SELECT
  k.id                AS kit_id,
  k.name,
  k.location_id,
  BOOL_AND(ia.quantity_available >= ki.quantity) AS is_available
FROM public.kits k
JOIN public.kit_items ki ON ki.kit_id = k.id
JOIN public.item_availability ia ON ia.item_id = ki.item_id
WHERE k.is_active = TRUE
GROUP BY k.id, k.name, k.location_id;

-- Admin dashboard summary
CREATE OR REPLACE VIEW public.admin_dashboard_summary AS
SELECT
  (SELECT COUNT(*) FROM public.reservations WHERE status = 'pending')         AS pending_approvals,
  (SELECT COUNT(*) FROM public.reservations WHERE status = 'checked_out')     AS items_checked_out,
  (SELECT COUNT(*) FROM public.reservations
   WHERE status = 'approved' AND pickup_date = CURRENT_DATE)                  AS pickups_today,
  (SELECT COUNT(*) FROM public.reservations
   WHERE status = 'checked_out' AND return_date = CURRENT_DATE)               AS returns_today,
  (SELECT COUNT(*) FROM public.student_profiles WHERE is_blocked = TRUE)      AS open_holds;

-- ============================================================
-- NOTES FOR SUPABASE RLS (Row Level Security)
-- ============================================================
-- RLS policies should be added per table. High-level intent:
--
-- public.users
--   SELECT: authenticated users can read their own row;
--           workers/admins can read all rows.
--
-- public.reservations
--   SELECT: students see only their own; workers/admins see all.
--   INSERT: students (with 2-week lead-time check in app layer);
--           workers/admins bypass lead-time.
--   UPDATE: students (draft/denied status only);
--           workers (in-progress edits);
--           admins (all fields).
--
-- public.student_notes / public.student_profiles
--   SELECT: admins only (or student sees own profile, not notes).
--   INSERT/UPDATE: admins only.
--
-- public.fines
--   SELECT: student sees own fines; admin sees all.
--   INSERT: system/admin only.
--   UPDATE (removal fields): admin only.
--
-- public.notifications
--   SELECT: user sees only their own notifications.
--   UPDATE (is_read): user can mark their own as read.
--
-- public.academic_calendar / public.locations / public.items
--   SELECT: all authenticated users.
--   INSERT/UPDATE/DELETE: admins only (items: workers can UPDATE, not INSERT).
-- ============================================================

-- ============================================================
-- TRIGGER FUNCTIONS
-- ============================================================

-- Fires on every new auth.users INSERT.
-- 1. Validates utahtech.edu domain
-- 2. Creates public.users row
-- 3. Creates public.student_profiles row (default beginner, onboarding pending)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.email NOT LIKE '%@utahtech.edu' THEN
    RAISE EXCEPTION 'Only utahtech.edu email addresses are permitted.';
  END IF;

  INSERT INTO public.users (id, email, full_name, role, onboarding_completed)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    'student',
    FALSE
  );

  INSERT INTO public.student_profiles (user_id)
  VALUES (NEW.id);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Fires when a semester's is_active flips to TRUE.
-- 1. Deactivates any previously active semester
-- 2. Resets onboarding_completed for all students and professors
--    so they are re-prompted at the start of each semester
CREATE OR REPLACE FUNCTION public.handle_semester_activation()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_active = TRUE AND (OLD.is_active = FALSE OR OLD.is_active IS NULL) THEN

    UPDATE public.semesters
    SET is_active = FALSE, updated_at = NOW()
    WHERE id <> NEW.id AND is_active = TRUE;

    UPDATE public.users
    SET onboarding_completed = FALSE, updated_at = NOW()
    WHERE role IN ('student', 'professor');

  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_semester_activated
  AFTER UPDATE OF is_active ON public.semesters
  FOR EACH ROW EXECUTE FUNCTION public.handle_semester_activation();

-- Fires after a student_note is inserted with is_strike = TRUE.
-- Keeps the strike_count on student_profiles in sync automatically.
-- Also blocks the student if strike_count reaches 3.
CREATE OR REPLACE FUNCTION public.handle_strike_added()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_strike = TRUE THEN
    UPDATE public.student_profiles
    SET
      strike_count = strike_count + 1,
      is_blocked   = CASE WHEN strike_count + 1 >= 3 THEN TRUE ELSE is_blocked END,
      blocked_at   = CASE WHEN strike_count + 1 >= 3 AND is_blocked = FALSE THEN NOW() ELSE blocked_at END,
      updated_at   = NOW()
    WHERE user_id = NEW.student_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_strike_added
  AFTER INSERT ON public.student_notes
  FOR EACH ROW EXECUTE FUNCTION public.handle_strike_added();

-- ============================================================
-- SEED DATA — SEMESTERS
-- ============================================================

INSERT INTO public.semesters (name, start_date, end_date, is_active) VALUES
  ('Fall 2026',   '2026-08-19', '2026-12-04', TRUE),
  ('Spring 2027', '2027-01-11', '2027-04-27', FALSE),
  ('Summer 2027', '2027-05-17', '2027-08-06', FALSE);

-- ============================================================
-- SEED DATA — ACADEMIC CALENDAR (BLOCKED DATES)
-- Source: catalog.utahtech.edu/academiccalendar (retrieved Aug 2026)
-- Note: Utah Tech reserves the right to change dates without notice.
--       Admin should verify and update each semester from the registrar.
-- ============================================================

-- Fall 2026
INSERT INTO public.academic_calendar (semester_id, date, is_blocked, reason)
SELECT s.id, v.date::DATE, TRUE, v.reason
FROM public.semesters s,
(VALUES
  ('2026-09-07', 'Labor Day'),
  ('2026-10-15', 'Fall Semester Break'),
  ('2026-10-16', 'Fall Semester Break'),
  ('2026-11-23', 'Thanksgiving Break'),
  ('2026-11-24', 'Thanksgiving Break'),
  ('2026-11-25', 'Thanksgiving Break'),
  ('2026-11-26', 'Thanksgiving Break'),
  ('2026-11-27', 'Thanksgiving Break')
) AS v(date, reason)
WHERE s.name = 'Fall 2026';

-- Spring 2027
INSERT INTO public.academic_calendar (semester_id, date, is_blocked, reason)
SELECT s.id, v.date::DATE, TRUE, v.reason
FROM public.semesters s,
(VALUES
  ('2027-01-18', 'Dr. Martin Luther King Jr. Day'),
  ('2027-02-15', 'Presidents Day'),
  ('2027-03-08', 'Spring Break'),
  ('2027-03-09', 'Spring Break'),
  ('2027-03-10', 'Spring Break'),
  ('2027-03-11', 'Spring Break'),
  ('2027-03-12', 'Spring Break')
) AS v(date, reason)
WHERE s.name = 'Spring 2027';

-- Summer 2027
INSERT INTO public.academic_calendar (semester_id, date, is_blocked, reason)
SELECT s.id, v.date::DATE, TRUE, v.reason
FROM public.semesters s,
(VALUES
  ('2027-05-31', 'Memorial Day'),
  ('2027-06-18', 'Juneteenth National Freedom Day'),
  ('2027-07-05', 'Independence Day'),
  ('2027-07-24', 'Pioneer Day')
) AS v(date, reason)
WHERE s.name = 'Summer 2027';

-- ============================================================
-- SEED DATA — PICKUP WINDOW RULES
-- (already included inline above; listed here for reference)
-- ============================================================
-- Reservations under 25 items:  pickup 10am–5pm,  dropoff 10am–5pm
-- Reservations 25+ items:       pickup 2pm–5pm,   dropoff 8am–10am

-- ============================================================
-- SEED DATA — COURSE TIER MAPPINGS (starter set — admin should update)
-- ============================================================

INSERT INTO public.course_tier_mappings
  (course_name, course_code, tier, display_order, is_active)
VALUES
  ('Introduction to Media Production',  'COMM 1010', 'beginner',     1, TRUE),
  ('Media Production Fundamentals',     'COMM 2110', 'beginner',     2, TRUE),
  ('Film Production I',                 'FILM 2300', 'intermediate', 3, TRUE),
  ('Film Production II',                'FILM 3300', 'intermediate', 4, TRUE),
  ('Advanced Film Production',          'FILM 4300', 'advanced',     5, TRUE),
  ('Capstone / Senior Production',      'FILM 4800', 'advanced',     6, TRUE);