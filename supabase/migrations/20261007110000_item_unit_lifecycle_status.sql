-- ============================================================
-- Item unit lifecycle status — a real way to take ONE physical unit
-- out of the working fleet (retired, lost, stolen, or temporarily
-- out for repair) without touching its siblings and without
-- destroying anything.
--
-- Prompted by Suzanne asking how deletion currently works: mostly,
-- it doesn't, on purpose. item_units_write_staff_up / item_models_
-- write_staff_up (initial schema) already grant staff+ DELETE at
-- the RLS layer ("for all" covers every command) — but the moment a
-- unit or model has ever shown up in a reservation, a plain foreign
-- key with no cascade path (reservation_items.item_model_id,
-- reservation_units.unit_id/.item_model_id) refuses the delete
-- outright rather than silently losing history. That's exactly the
-- behavior we want for anything with real history. This migration
-- is the other half: a way to take something out of service when
-- hard-deleting it isn't, and shouldn't be, possible.
--
-- status is a separate axis from condition on purpose. condition is
-- a point-in-time quality read, tied to checkout/return and feeding
-- condition_reviews. status is "is this unit part of the working
-- fleet right now" — a unit can be in good condition and retired
-- (replaced by a newer model), or damaged and still active, waiting
-- on a repair decision staff haven't made yet. Collapsing the two
-- into one column would make both harder to reason about, so a
-- return coming back `damaged` does NOT automatically flip status to
-- out_for_repair — that stays a deliberate second action.
--
-- Per Suzanne (10/7):
--   - Five states, not just active/retired: out_for_repair is
--     temporary (expected to flip back to active once fixed);
--     retired/lost/stolen are all permanent, just different paper
--     trails (insurance, replacement budgeting).
--   - No note required on a status change (unlike a condition
--     downgrade, which item_units_condition_guard already requires
--     a note for — this is a deliberately lighter-weight action).
--   - A unit currently checked out on an active reservation can't
--     have its status changed at all until it's returned — retiring/
--     repairing/losing something mid-loan doesn't make sense; staff
--     wait for the return first.
-- ============================================================

create type public.unit_status as enum ('active', 'out_for_repair', 'retired', 'lost', 'stolen');

alter table public.item_units
  add column status unit_status not null default 'active',
  add column status_note text,
  add column status_changed_at timestamptz,
  add column status_changed_by uuid references public.users(id);

create or replace function public.item_units_status_guard()
returns trigger language plpgsql as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if public.item_unit_current_reservation(new.id) is not null then
    raise exception 'This unit is currently checked out on an active reservation -- its status can''t change until it''s returned.';
  end if;

  -- Server-stamped, not client-trusted, same reasoning as
  -- reservations.approved_by/approved_at and condition_reviews.
  -- reviewed_by/reviewed_at elsewhere in this schema.
  new.status_changed_at := now();
  new.status_changed_by := auth.uid();
  return new;
end;
$$;
create trigger item_units_status_guard
  before update of status on public.item_units
  for each row execute function public.item_units_status_guard();

-- item_units_with_status (added 9/30, migration
-- 20260930160000_fines_view_and_current_reservation_fix) now also
-- carries status. The new columns are appended after the view's
-- existing last column (current_reservation_id) rather than
-- interleaved among the original ones — `create or replace view`
-- can only add columns at the end, never reorder or insert among
-- existing ones.
create or replace view public.item_units_with_status as
select
  u.id,
  u.item_model_id,
  u.unit_code,
  u.condition,
  u.condition_note,
  u.qr_code,
  u.serial_number,
  u.created_at,
  u.updated_at,
  public.item_unit_current_reservation(u.id) as current_reservation_id,
  u.status,
  u.status_note,
  u.status_changed_at,
  u.status_changed_by
from public.item_units u;
