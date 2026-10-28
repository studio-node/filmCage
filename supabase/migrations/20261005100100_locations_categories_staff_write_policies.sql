-- ============================================================
-- locations and categories: RLS was enabled with a read-only policy
-- on both (locations_read_all, categories_read_all) and no write
-- policy at all — same missing-write-policy shape already fixed
-- elsewhere (student_profiles, notifications, condition_reviews).
-- Confirmed 10/4: Staff+ (staff/supervisor/admin) should be able to
-- write to both, nobody else — matches every other catalog/reference
-- table (item_models, kits, location_hours, location_closures,
-- kit_items).
-- ============================================================

create policy locations_write_staff_up on public.locations
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));

create policy categories_write_staff_up on public.categories
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));
