-- Read-only. Run this FIRST in the Supabase SQL Editor and eyeball the
-- results before running 2026-09-25_reset_for_client_demo.sql.
-- Confirms: (1) the exact spelling of the item you want to keep, and
-- (2) how much test data currently exists in each table that the
-- reset script is about to clear.

select id, name, brand, model from public.item_models order by name;

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
