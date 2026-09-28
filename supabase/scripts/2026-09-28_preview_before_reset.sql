-- Read-only. Run this FIRST in the Supabase SQL Editor and eyeball the
-- results before running 2026-09-28_reset_for_client_demo.sql.
--
-- Superseded: 2026-09-25_preview_before_reset.sql / _reset_for_client_demo.sql
-- (those assumed the 9-item seed catalog was still intact; Suzanne has
-- since deleted items by hand from the Supabase dashboard, so this
-- version doesn't assume anything about what's currently in the table
-- and instead shows the real, current state.)

-- Every item currently in the catalog, with how many units each has.
select
  m.id,
  m.name,
  m.brand,
  m.model,
  count(u.id) as unit_count
from public.item_models m
left join public.item_units u on u.item_model_id = m.id
group by m.id, m.name, m.brand, m.model
order by m.name;

-- How much test/activity data currently exists in each table the
-- reset script is about to clear.
select 'item_models' as table_name, count(*) from public.item_models
union all select 'item_units', count(*) from public.item_units
union all select 'reservations', count(*) from public.reservations
union all select 'reservation_items', count(*) from public.reservation_items
union all select 'reservation_units', count(*) from public.reservation_units
union all select 'condition_reviews', count(*) from public.condition_reviews
union all select 'checkout_sessions', count(*) from public.checkout_sessions
union all select 'return_item_statuses', count(*) from public.return_item_statuses
union all select 'fines', count(*) from public.fines
union all select 'waitlist_entries', count(*) from public.waitlist_entries
union all select 'notifications', count(*) from public.notifications
union all select 'recurring_reservations', count(*) from public.recurring_reservations
union all select 'recurring_reservation_items', count(*) from public.recurring_reservation_items
union all select 'recurring_reservation_occurrences', count(*) from public.recurring_reservation_occurrences
union all select 'reservation_crew', count(*) from public.reservation_crew
union all select 'reservation_assignments', count(*) from public.reservation_assignments;
