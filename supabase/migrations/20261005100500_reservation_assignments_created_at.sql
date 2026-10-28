-- ============================================================
-- reservation_assignments had no timestamp column at all — every
-- other junction table (kit_items, reservation_units,
-- reservation_crew, waitlist_entries) has at least created_at.
-- Plain gap, not a created_by question (confirmed 10/4): who made a
-- crew assignment isn't an accountable decision the way a fine or a
-- condition note is, so created_by isn't added.
-- ============================================================

alter table public.reservation_assignments
  add column created_at timestamptz not null default now();
