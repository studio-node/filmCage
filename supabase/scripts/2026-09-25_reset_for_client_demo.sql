-- One-time data reset for today's client meeting.
-- Keeps exactly ONE item ("Canon EOS R6 Mark II") as a live example and
-- clears every other item, plus all reservation/checkout/condition/fine/
-- waitlist test activity, so the client sees a clean system.
--
-- This is NOT a schema migration — it's a one-off data operation. Run it
-- by hand in the Supabase SQL Editor (or psql), NOT via `supabase db push`.
-- It does not touch: locations, categories, kits (the kit shells stay,
-- just lose any line items that pointed at a deleted item), semesters,
-- academic_calendar, users/student_profiles, student_notes.
--
-- Safe to re-run: if the named item is missing (e.g. already deleted, or
-- the name doesn't match exactly), the whole transaction aborts and
-- nothing is changed.
--
-- Run 2026-09-25_preview_before_reset.sql first to confirm the exact
-- item name and see what's about to be cleared.

begin;

-- Safety check: abort the whole transaction unless exactly one item
-- matches this name. Edit the name here if you're keeping a different item.
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.item_models
  where name = 'Canon EOS R6 Mark II';

  if v_count <> 1 then
    raise exception
      'Expected exactly 1 item_models row named "Canon EOS R6 Mark II", found %. Aborting -- fix the name in this script and re-run.',
      v_count;
  end if;
end $$;

-- Detach units from any in-progress reservation before reservations go away
update public.item_units set current_reservation_id = null;

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

-- Clear the catalog down to the one example item.
-- item_units, item_custom_attributes, and kit_items for the deleted
-- models cascade automatically (all declared "on delete cascade").
delete from public.item_models where name <> 'Canon EOS R6 Mark II';

-- Final tally -- review before trusting the commit
select 'item_models' as table_name, count(*) from public.item_models
union all select 'item_units', count(*) from public.item_units
union all select 'reservations', count(*) from public.reservations
union all select 'condition_reviews', count(*) from public.condition_reviews
union all select 'fines', count(*) from public.fines
union all select 'waitlist_entries', count(*) from public.waitlist_entries;

commit;
