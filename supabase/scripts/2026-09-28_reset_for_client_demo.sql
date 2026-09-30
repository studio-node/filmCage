-- One-time data reset. Keeps exactly ONE item ("Sony ZV-E10" -- the
-- real item you and the client hand-entered to test item entry) and
-- clears every other item, plus all reservation/checkout/condition/
-- fine/waitlist test activity, so you're starting clean with real
-- items and real reservations from here on.
--
-- Superseded: 2026-09-25_reset_for_client_demo.sql (that one targeted
-- the seed catalog's "Canon EOS R6 Mark II" -- no longer relevant
-- since the seed items were deleted by hand from the dashboard).
--
-- This is NOT a schema migration -- it's a one-off data operation. Run
-- it by hand in the Supabase SQL Editor (or psql), NOT via
-- `supabase db push`.
--
-- Does NOT touch: locations, categories, kits (kit shells stay, just
-- lose any line items that pointed at a deleted item), semesters,
-- academic_calendar, users/student_profiles, student_notes.
--
-- Does NOT touch the kept item's existing units. Whatever unit rows
-- (and their QR codes / serial numbers / conditions) already exist
-- under Sony ZV-E10 are left exactly as they are -- this script only
-- deletes OTHER items. If it doesn't already have exactly 11 units,
-- true that up afterward in Edit Items ("+ Add unit" / delete a row
-- and Save changes), rather than guessing at it here in SQL.
--
-- Safe to re-run: if the named item is missing, or its name doesn't
-- match exactly, the whole transaction aborts and nothing is changed.

begin;

-- Safety check: abort the whole transaction unless exactly one item
-- matches this name. Edit the name here if it's spelled differently
-- in your catalog (run the preview script first to check).
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.item_models
  where name = 'Sony ZV-E10';

  if v_count <> 1 then
    raise exception
      'Expected exactly 1 item_models row named "Sony ZV-E10", found %. Aborting -- check the exact spelling with the preview script, fix the name in this script if needed, and re-run.',
      v_count;
  end if;
end $$;

-- (Older versions of this script nulled item_units.current_reservation_id
-- here before deleting reservations. As of migration
-- 20260930160000_fines_view_and_current_reservation_fix.sql that column
-- no longer exists -- "currently checked out" is now computed live from
-- reservation_units + reservations.status via the item_units_with_status
-- view, so there's nothing to null out and nothing that can drift.)

-- Clear activity/test data (child tables first, respecting foreign keys)
delete from public.notifications;
delete from public.fines;
delete from public.return_item_statuses;
delete from public.checkout_sessions;
delete from public.reservation_assignments;
delete from public.reservation_crew;
delete from public.waitlist_entries;
delete from public.condition_reviews;
delete from public.reservation_units;
delete from public.reservation_items;
delete from public.recurring_reservation_occurrences;
delete from public.recurring_reservation_items;
delete from public.recurring_reservations;
delete from public.reservations;

-- Clear the catalog down to the one real item.
-- item_units, item_custom_attributes, and kit_items for the deleted
-- models cascade automatically (all declared "on delete cascade").
-- The kept item's own units are untouched.
delete from public.item_models where name <> 'Sony ZV-E10';

-- Final tally -- review before trusting the commit.
-- unit_count here should read 11 -- if it doesn't, fix it afterward
-- in Edit Items rather than re-running this script.
select
  (select count(*) from public.item_models) as item_models,
  (select count(*) from public.item_units) as item_units,
  (select count(*) from public.item_units u join public.item_models m on m.id = u.item_model_id where m.name = 'Sony ZV-E10') as sony_zv_e10_unit_count,
  (select count(*) from public.reservations) as reservations,
  (select count(*) from public.condition_reviews) as condition_reviews,
  (select count(*) from public.fines) as fines,
  (select count(*) from public.waitlist_entries) as waitlist_entries;

commit;
