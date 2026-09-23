# The Film Cage — Schema Design

September 23, 2026 (updated same day with the first round of client-feedback answers)

This reconciles the existing `schema.sql` draft (July 2026, mostly reusable for locations, the academic calendar, and kits) with the data model finalized in the September mockup — the two real structural changes are per-unit equipment tracking and the new Staff / Supervisor / Admin role split.

**Update log:** the original version of this doc left several items as open questions. You answered most of them (crew pickup-time rights, fine escalation rates, 3-strike auto-blocking, the "missing" condition tag, waitlist promotion, and recurring-reservation termination) after a first pass of client feedback — those sections below are rewritten to match, and the corresponding SQL is already in `supabase/migrations/20260923163000_initial_schema.sql`. One question is still open (capstone pre-pickup meetings: Admin-only or Staff/Supervisor too) — see Open questions at the end.

## Purpose & approach

The `filmCage` repo already had a solid `schema.sql` draft from July 2026 (35 tables), but it was written against the requirements as they stood before the September mockup work — before per-unit inventory, before the Staff/Supervisor split, before the v4 category and scheduling rules. Two changes are structural enough that they touch nearly every table around them:

1. **Per-unit inventory.** The old draft tracks each catalog entry as one row with a `quantity_total` counter and one shared status. The mockup tracks every physical unit individually (`EQ-102-A`, `EQ-102-B`, …), each with its own condition and its own holder. `items` splits into `item_models` (the catalog entry — name, brand, price, category) and `item_units` (the physical inventory).
2. **Role hierarchy.** `user_role` grows from `student / worker / admin / professor` to `student / staff / supervisor / admin / professor`, and every rule that used to check `role = 'admin'` now needs a rank comparison instead of an equality check.

Everything else in the old draft is a good starting point with lighter changes: `locations`, `location_hours`, `semesters`, `academic_calendar`, `course_tier_mappings`, `kits` / `kit_items`, and the notification/strike/fine enums all carry forward with renamed values or a few added columns, not a rebuild.

Table names stay plural and unprefixed (`public.reservations`, not `public.tbl_reservation`), matching the existing draft's own convention.

## Roles, users & access tiers

```sql
CREATE TYPE user_role AS ENUM ('student', 'staff', 'supervisor', 'admin', 'professor');
CREATE TYPE student_tier AS ENUM ('beginner', 'intermediate', 'advanced');
CREATE TYPE strike_reason AS ENUM ('damage', 'late_return', 'behavioral');
```

`public.users` extends `auth.users` as before: `id`, `email`, `full_name`, `role`, `onboarding_completed`, `is_active`, `created_at`, `updated_at`.

`public.student_profiles`: `user_id` (PK), `tier`, `strike_count`, `is_blocked`, `checkout_suspended`, `suspended_at`, `suspended_reason`, `blocked_at`, `blocked_by`, `class_taken` (FK to `course_tier_mappings`), and a new `needs_tier_reconfirmation` boolean — set `true` by the Semester Setup bulk reset, cleared the next time the student logs in and confirms their class.

`public.professor_profiles`: `user_id` (PK), `employment_type` (e.g. "Full-time") — kept minimal since it's display-only today.

`public.student_notes`: `id`, `student_id`, `author_id`, `note_text`, `is_strike`, `strike_reason`, `created_at` — carried over as-is from the July draft.

**Permission summary** (what each tier can do — this is what the RLS/trigger section later maps to actual Postgres enforcement):

| Action | Student | Professor | Staff | Supervisor | Admin |
| --- | --- | --- | --- | --- | --- |
| Browse & reserve equipment | Yes | Yes | Yes | Yes | Yes |
| Approve / deny reservations | — | — | Yes | Yes | Yes |
| Manage catalog, kits, locations | — | — | Yes | Yes | Yes |
| Confirm pickup / return | — | — | Yes | Yes | Yes |
| Downgrade a unit's condition | — | — | Yes | Yes | Yes |
| Upgrade a unit's condition | — | — | No | Yes | Yes |
| Promote / demote a user | — | — | No | No | Yes |
| View full Admin Panel | — | — | Yes | Yes | Yes |

## Locations, hours, academic calendar & Semester Setup

```sql
CREATE TYPE day_of_week_enum AS ENUM ('monday','tuesday','wednesday','thursday','friday','saturday','sunday');
```

`public.locations`: `id`, `name`, `building`, `room`, `address`, `is_active`, `created_by`, timestamps — reused as-is; adding a future location is just a new row.

`public.location_hours`: `id`, `location_id`, `day_of_week`, `is_open`, `appointment_only`, `open_time`, `close_time` — one row per location per weekday, editable per location (the mockup's shared `HOURS` table, made per-location).

`public.academic_calendar`: `id`, `semester_id`, `date`, `is_blocked`, `reason` — school-wide holidays/breaks that block pickup, drop-off, and capstone meetings everywhere. Reused almost unchanged from the July draft.

`public.location_closures` **(new)**: `id`, `location_id`, `date`, `reason`, `created_by`, `created_at` — one-off closures for a single location that aren't holiday-driven ("Studio C closed 10/3 for an AV upgrade"), per your confirmation that closures need to be adjustable per location independent of the shared calendar. A date counts as closed for a location if it appears in `academic_calendar`, in `location_closures` for that location, or if `location_hours` marks that weekday closed.

`public.course_tier_mappings`: `id`, `course_name`, `course_code`, `tier`, `display_order`, `is_active`, `created_by`, `created_at` — the editable class list from Semester Setup, reused as-is.

`public.semesters`: `id`, `name`, `start_date`, `end_date`, `is_current`, `created_at` — reused; `is_current` flips when the "set next semester's start date" checklist step runs.

`public.semester_checklist_items` **(new)**: `id`, `semester_id`, `task_key` (`location_hours` / `closures` / `tier_reset` / `class_list` / `staff_roles`), `is_done`, `done_by`, `done_at` — one row per Semester Setup task per semester. Generic on purpose, since the board only needs to "show a list of tasks" for now, not enforce what finishing each one means.

## Categories & equipment catalog

```sql
CREATE TYPE category_kind AS ENUM ('direct', 'general');
```

`public.categories`: `id`, `name`, `kind`, `display_order`, `is_active` — seeded with the 7 direct categories (Batteries, Cameras, Lenses, Lights, Light Stands, SD Cards, Sound Equipment) and the 3 general ones (Camera Dept, Sound Dept, Misc). Both kinds share one table since they're both just flat named lists.

`public.item_models`: `id`, `name`, `brand`, `model`, `purchase_price`, `picture_url`, `location_id`, `description`, `direct_category_id`, `general_category_id`, `min_tier`, `youtube_url`, `is_active`, `created_by`, timestamps. Direct and general category are two independent picks at creation — not derived from each other — matching your confirmation that Misc is a free choice, not a hardcoded catch-all.

`public.item_custom_attributes`: `id`, `item_model_id`, `attribute_name`, `attribute_value`, `created_at` — reused unchanged, the freeform key/value fields per item.

Dropped from the old `items` table: `status`, `status_notes`, `quantity_total`. All three move to `item_units`, next.

## Per-unit inventory & condition rules

```sql
CREATE TYPE unit_condition AS ENUM ('good', 'caution', 'damaged', 'missing');
```

`public.item_units`: `id`, `item_model_id`, `unit_code` (e.g. `EQ-102-A`), `condition`, `condition_note`, `current_reservation_id` (nullable — who holds it right now), `created_at`, `updated_at`.

**Resolved:** "missing" is its own `unit_condition` value rather than a separate boolean flag, per your answer. It ranks below `damaged` (the worst state a unit can be in), so marking a unit missing still counts as a downgrade — it still requires a note and still creates a `condition_reviews` row, exactly like any other downgrade — and reversing it (missing → anything better) is an upgrade, so it's Supervisor/Admin-only like any other upgrade. `return_item_statuses.is_missing` is dropped for the same reason — `condition_at_return = 'missing'` says the same thing.

`public.condition_reviews`: `id`, `unit_id`, `item_model_id`, `reservation_id` (nullable — null for a manual edit outside a return), `student_id` (nullable), `condition`, `note`, `is_reviewed`, `reviewed_by`, `reviewed_at`, `created_at`. A row is created automatically whenever a unit's condition is downgraded, whether that happens through the return flow or a direct manual edit — exactly the mockup's existing flag behavior, just triggered at the database layer so it can't be skipped by a future client that bypasses the app.

**Trigger logic on `item_units`:**

| Situation | Result |
| --- | --- |
| Staff attempts an upgrade (caution/damaged → better) | Blocked — the trigger raises an exception, not just a UI toast |
| Supervisor or admin changes condition, either direction | Allowed, no restriction |
| Any downgrade, any role | `condition_note` required; a `condition_reviews` row is inserted for admin |
| A brand-new unit's initial condition (`INSERT`, not `UPDATE`) | Note still required, but no `condition_reviews` row — there's no prior state to compare against |

Role is read inside the trigger via a `current_user_role()` helper (see RLS section) rather than trusting anything the client sends.

## Kits

`public.kits`: `id`, `name`, `description`, `location_id`, `min_tier`, `created_by`, `is_active`, timestamps.

`public.kit_items`: `id`, `kit_id`, `item_model_id`, `quantity`, `created_at`, unique on (`kit_id`, `item_model_id`). Kits reference item *models*, not specific units — units get assigned at reservation time the same way a directly-added item does.

Carried forward unchanged from the July draft except for adding `min_tier`, to match the per-kit tier gate the mockup already enforces.

## Reservations: fields, lifecycle & scheduling rules

```sql
CREATE TYPE reservation_status AS ENUM (
  'pending', 'denied', 'waitlisted', 'waitlist_offered', 'cancelled',
  'awaiting_appointment', 'awaiting_schedule',
  'approved', 'active', 'completed'
);
```

Two statuses added for the waitlist workflow (see that section below): `waitlist_offered` (a unit just freed up and the student has 48 hours to confirm) and `cancelled` (the student declined, or a 48-hour offer expired unanswered).

`public.reservations`: `id`, `reservation_name` (new, required — the v4 "name your reservation" field), `student_id`, `location_id`, `status`, `is_capstone`, `capstone_appointment_date`, `appointment_completed`, `pickup_date`, `pickup_time`, `dropoff_date`, `dropoff_time`, `scheduled`, `is_group_reservation`, `allow_individual_pickup_times` (new — see Crew section), `denial_reason`, `admin_notes`, `created_by`, `approved_by`, `approved_at`, timestamps. No overlap/exclusion constraint on the time range — overlapping reservations across locations are explicitly allowed.

`public.reservation_items`: `reservation_id`, `item_model_id`, `kit_id` (nullable), `quantity`.

`public.reservation_units`: `reservation_id`, `item_model_id`, `unit_id` — the actual assigned physical units, replacing the mockup's in-memory `units[]` array. Populated by a function at auto-confirm or staff-approval time (mirrors `assignUnitsToReservation`).

**Status lifecycle:**

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> approved: basic, at/under 20 items, non-Friday
    pending --> denied: staff denies
    pending --> waitlisted: nothing available
    pending --> awaiting_appointment: capstone gear approved
    awaiting_appointment --> awaiting_schedule: pre-pickup meeting confirmed
    awaiting_schedule --> approved: pickup/return time scheduled
    approved --> active: pickup checklist complete
    active --> completed: return checklist complete
    denied --> pending: student edits & resubmits
    waitlisted --> waitlist_offered: a unit frees up, next in line offered
    waitlist_offered --> approved: student confirms within 48h
    waitlist_offered --> cancelled: student declines, or 48h expires
    cancelled --> waitlisted: item moves down to the next person in line
```

**Scheduling limits:**

| Rule | Value |
| --- | --- |
| Closed days | Saturday, Sunday — never selectable |
| Min lead time, basic reservation | 3 days |
| Min lead time, over 20 items | 7 days |
| Capstone pre-pickup meeting | 3 days min, 2 weeks max |
| Lands on a closed day | Rolls to the next open day |
| Default loan window (basic) | 3 days, pickup → drop-off |

**Approval is required** (status starts at `pending` instead of auto-confirming) when any of: capstone, or over 20 items; any Friday pickup, drop-off, or meeting; a pickup date under 3 days out; or a basic reservation's loan window exceeding the 3-day default (both dates then need approval, not just pickup). A single `BEFORE INSERT OR UPDATE` trigger function computes this and sets `status`, so the app's live pop-up warning and the DB's actual enforcement can't drift apart.

**Editing rights:** a basic reservation stays student-editable any time, as long as the edit still passes the rule above — an edit that breaks it flips `status` back to `pending`. A capstone/over-20-item reservation is student-editable only up to staff approval, enforced by an RLS `UPDATE` policy on `status` + `student_id = auth.uid()`.

Deletion confirmation is a client-side modal, not schema-level — nothing here blocks a `DELETE` at the database layer.

## Waitlist

**Resolved.** When a reservation can't get the item(s) it needs, it goes to `waitlisted` and joins a per-`item_model` queue (`public.waitlist_entries`). When a unit frees up — a return, a cancellation, someone declining an offer — the next entry in line gets a 48-hour window to confirm.

```sql
CREATE TYPE waitlist_entry_status AS ENUM ('waiting', 'offered', 'confirmed', 'declined', 'expired');
```

`public.waitlist_entries`: `id`, `reservation_id`, `item_model_id`, `student_id`, `status`, `queue_position`, `offered_at`, `offer_expires_at`, `responded_at`, `created_at`.

The flow, matching your description exactly:

1. **Joining the queue.** The app calls `add_to_waitlist()` when it determines a reservation can't be granted the item right now — this sets the reservation's status to `waitlisted` and its queue position to the back of the line for that item.
2. **An offer goes out.** `offer_next_waitlist_entry()` is called when a unit frees up. It only offers when the reservation doesn't independently trigger one of the other approval requirements (capstone, over 20 items, under the lead-time minimum, outside the drop-off window) — matching "as long as the reservation doesn't have any of the other necessary triggers for approval." The reservation's status becomes `waitlist_offered` and a notification goes out.
3. **The student decides.** `confirm_waitlist_entry()` — the student wants it, so the reservation goes straight to `approved` (no separate staff approval needed, since step 2 already confirmed nothing else requires it). `decline_waitlist_entry()` — the student doesn't want it, the reservation is `cancelled`, and the item is immediately re-offered to the next person in line.
4. **No response.** `expire_stale_waitlist_offers()` is meant to run on a schedule (hourly, via `pg_cron` or a Supabase Edge Function cron trigger — not built here, since scheduling itself lives outside the database). Any offer past its 48-hour window is marked `expired`, its reservation `cancelled`, and the item re-offered to the next person — same as an explicit decline.

## Crew / group reservations

`public.reservation_crew`: `id`, `reservation_id`, `user_id`, `crew_role` (**Director** — the default role for the student who creates the reservation — plus Producer / Camera Operator / Sound / Gaffer-Lighting / Grip / Editor), `is_producer`, `pickup_time_override`, `dropoff_time_override`, `created_at`. Unlike the mockup, which matches crew by typed name against a hardcoded student list, this is a real FK to `users` — a crew invite is unambiguous.

`public.reservation_assignments`: `reservation_id`, `item_model_id`, `assigned_to_user_id` — which crew member is responsible for which item line, mirroring the mockup's `assignments{}` object.

**Resolved**, matching your description of the flow:

- The student who starts the reservation defaults to **Director**. They add the other students on the crew, assign each one a role, and assign each one the specific equipment they'll be responsible for (`reservation_assignments`).
- `reservations.allow_individual_pickup_times` is the toggle between the two pickup models: **false (default)** — everyone is notified of one shared pickup time (`reservations.pickup_time`/`dropoff_time`) and either the whole crew comes together or the Director takes responsibility for picking up all the equipment. **true** — each named crew member can view the reservation on their own dashboard and set their own `pickup_time_override`/`dropoff_time_override` in `reservation_crew` for just their assigned gear; anyone who doesn't set one falls back to the shared time / Director-picks-up-everything default.

## Pickup & return, fines & holds

`public.checkout_sessions`: `id`, `reservation_id`, `phase` (`pickup` / `return`), `person_user_id`, `person_signature`, `person_confirmed_at`, `staff_user_id`, `staff_confirmed_at` — mirrors the mockup's two-party sign-off (the student or assigned crew member signs, staff confirms separately).

`public.return_item_statuses`: `reservation_id`, `unit_id`, `condition_at_return`, `note` — per-unit outcomes recorded at return, feeding the `condition_reviews` trigger from the per-unit inventory section. (`is_missing` is dropped — `condition_at_return = 'missing'` covers it, per the Per-unit inventory section above.)

```sql
CREATE TYPE fine_type AS ENUM ('late_return', 'damage', 'missing', 'other');
CREATE TYPE fine_status AS ENUM ('warning', 'active', 'on_hold', 'resolved');
```

`public.fines`: `id`, `student_id`, `reservation_id` (nullable), `unit_id` (nullable), `fine_type`, `status`, `days_late`, `rate_per_day`, `current_amount`, `escalation_note`, `created_at`, `resolved_at`, `resolved_by`.

**Resolved — escalation rate**, per your answer: day 1 is $5, days 2–3 are $10/day, day 4 onward is $25/day. `fine_rate_for_day(day_number)` returns the right rate for a given day, and `recalculate_fine_amount(fine_id)` sums the days-so-far into `current_amount` and sets `rate_per_day` to the current day's rate. `escalate_late_fines()` is meant to run once a day (same "external scheduler" caveat as the waitlist expiry function) to bump every open late-return fine's `days_late` and recalculate it.

One thing your answer didn't restate: the original requirements also mention checkout privileges eventually getting suspended. `student_profiles.checkout_suspended` still exists for this, but no dollar-amount or day-count threshold has been specified to auto-trigger it — for now it's a manual staff/admin action, not automatic. Flagged in Open questions in case that's still wanted.

**Resolved — 3-strike auto-block.** `public.student_notes` (Roles section) doubles as the strike log — `is_strike = true` rows with a `strike_reason`. A trigger on `student_notes` now increments `student_profiles.strike_count` on every strike, and automatically sets `is_blocked = true` the moment the count reaches 3, notifying the student. Un-blocking is Admin-only — a separate guard trigger rejects any attempt to flip `is_blocked` back to `false` unless the acting user's role is `admin`, exactly per your answer ("the resolution or descalation should be by admin privilege only").

## Recurring (ongoing) reservations

**Resolved.** The July draft's `recurring_reservations` / `recurring_reservation_items` / `recurring_reservation_occurrences` tables carry forward with light renames, for professors who need the same equipment on a standing basis (e.g. "FILM 3400 — Tuesday Shoots").

Two things came out of your latest answers:

- **Semester Setup gets a new task.** `semester_task_key` adds `recurring_equipment_requests` — a Semester Setup checklist item asking professors to (re)submit the ongoing equipment they'll need for the new semester, alongside the existing `location_hours` / `closures` / `tier_reset` / `class_list` / `staff_roles` tasks.
- **Admin can end one at any time.** `recurring_reservations` gets `ended_at` / `ended_by`. A guard trigger only lets an `admin` set `ended_at` — Staff and Supervisor can create/manage recurring reservations day-to-day, but only Admin can terminate a standing one, per your answer.

## Notifications

```sql
CREATE TYPE notification_type AS ENUM (
  'reservation_approved', 'reservation_denied', 'damage_alert', 'fine_issued',
  'waitlist_available', 'crew_invitation', 'strike_issued', 'account_blocked',
  'checkout_reminder', 'return_reminder', 'pre_meeting_scheduled', 'pre_meeting_completed',
  'account_suspended', 'condition_downgrade_flag', 'role_changed', 'tier_reconfirm_needed'
);
```

Carried over from the July draft, with three additions for rules confirmed since: `condition_downgrade_flag`, `role_changed`, `tier_reconfirm_needed`.

`public.notifications`: `id`, `user_id`, `type`, `title`, `body`, `related_reservation_id` (nullable), `is_read`, `channel` (`in_app` / `email`), `created_at`.

Which type goes to email versus stays in-app is a send-time decision made by the Node backend catching Supabase's Database Webhooks, per the confirmed tech stack — this table just records what was generated, for the in-app feed and as an audit trail, regardless of channel.

## RLS & permission enforcement plan

Every table gets RLS enabled. One helper does the role lookup so policies and triggers don't each repeat the same subquery:

```sql
CREATE FUNCTION current_user_role() RETURNS user_role
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$;
```

**Row-visibility policies:**

- Students see and edit only their own rows in `reservations`, `reservation_items`, `checkout_sessions`, `fines`, `notifications`.
- Staff, Supervisor, and Admin see all rows across those same tables — writes to `users` / `student_profiles` role and tier fields are restricted further below.
- `item_units`, `item_models`, `kits`, `locations` are readable by everyone — equipment browsing, prices included, is open to all tiers per the original requirements — writable only by Staff, Supervisor, or Admin.

**Trigger-enforced rules** (things RLS alone can't express, since they compare old vs. new values rather than just "who owns this row"):

| Rule | Enforced by |
| --- | --- |
| Staff can't upgrade a unit's condition | `BEFORE UPDATE` trigger on `item_units` |
| Downgrade requires a note + creates a `condition_reviews` row | Same trigger |
| Only Admin can promote/demote to or from Supervisor/Admin | `BEFORE UPDATE` trigger on `users.role` |
| Friday / lead-time / item-count / loan-window approval rules | `BEFORE INSERT OR UPDATE` trigger on `reservations` |
| Editing rights change once a capstone/over-20 reservation is approved | RLS `UPDATE` policy, gated on `status` |
| 3rd strike auto-blocks a student; only Admin can un-block | `AFTER INSERT` trigger on `student_notes`; `BEFORE UPDATE` guard on `student_profiles.is_blocked` |
| Only Admin can end (terminate) a recurring reservation | `BEFORE UPDATE` trigger on `recurring_reservations.ended_at` |

Two Postgres roles the app actually uses: `authenticated` (anon key + a user's JWT — the Vue frontend, subject to every policy above) and `service_role` (the Node backend only, bypasses RLS entirely — used for webhook-driven email sends and any scheduled job like the fine escalation walk, never exposed to the browser).

## Open questions & decisions needed

- [ ] **Capstone pre-pickup meetings:** Admin-only, or can Staff/Supervisor handle them too? Determines who a trigger or RLS policy allows to mark a meeting completed. The only item still open from the first round — no schema impact either way, so it isn't blocking anything in the current migration.
- [ ] **Checkout-suspension threshold:** the requirements describe fines eventually suspending checkout privileges, but no dollar amount or day count has been specified for when that kicks in automatically. `student_profiles.checkout_suspended` exists and can be set manually by staff/admin today; happy to wire up an automatic trigger once there's a number to enforce.
- [ ] Anything else from the upcoming client meeting — this doc and the migration will get another pass once you have it.

This is a living document — as of 9/23 it matches `supabase/migrations/20260923163000_initial_schema.sql`, re-validated against a local Postgres instance including the new waitlist, strike, fine-escalation, and recurring-reservation logic.
