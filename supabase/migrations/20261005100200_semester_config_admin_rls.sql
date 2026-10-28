-- ============================================================
-- semesters, academic_calendar, course_tier_mappings,
-- semester_checklist_items: none of these four ever had RLS enabled
-- at all. Confirmed 10/4: Admin-only — no one else (not even Staff)
-- should be able to touch these, since they define the semester
-- structure and tier definitions everything else hangs off of.
--
-- Reads are left open to every signed-in user (same "read_all"
-- pattern as the rest of the catalog) rather than also locking
-- reads to Admin, since students/staff legitimately need to read
-- these to know the current semester, see blocked dates, and see
-- their own tier mapping. The "admin only" decision was specifically
-- about who can *change* these four tables.
-- ============================================================

alter table public.semesters enable row level security;
alter table public.academic_calendar enable row level security;
alter table public.course_tier_mappings enable row level security;
alter table public.semester_checklist_items enable row level security;

create policy semesters_read_all on public.semesters
  for select using (auth.role() = 'authenticated');
create policy semesters_write_admin_only on public.semesters
  for all using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');

create policy academic_calendar_read_all on public.academic_calendar
  for select using (auth.role() = 'authenticated');
create policy academic_calendar_write_admin_only on public.academic_calendar
  for all using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');

create policy course_tier_mappings_read_all on public.course_tier_mappings
  for select using (auth.role() = 'authenticated');
create policy course_tier_mappings_write_admin_only on public.course_tier_mappings
  for all using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');

create policy semester_checklist_items_read_all on public.semester_checklist_items
  for select using (auth.role() = 'authenticated');
create policy semester_checklist_items_write_admin_only on public.semester_checklist_items
  for all using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');
