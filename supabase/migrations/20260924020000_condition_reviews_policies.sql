-- ============================================================
-- condition_reviews: missing RLS policies.
--
-- Real bug, reported by Suzanne: downgrading a unit's condition in
-- Edit Items (with a note, as required) failed with "new row violates
-- row-level security policy for table \"condition_reviews\"".
--
-- Cause: condition_reviews had row level security enabled
-- (20260923163000_initial_schema.sql) but no policies were ever
-- created for it — that migration's own comment flagged this
-- ("Remaining tables ... condition_reviews ... are omitted here for
-- length — flag if you want them spelled out individually before this
-- ships"). With RLS on and zero policies, every operation is denied
-- by default, including the automatic insert that
-- item_units_condition_guard() makes into this table whenever a unit
-- is downgraded — that trigger function runs as the calling user
-- (it's not security definer), so it's bound by this table's RLS just
-- like a direct request would be.
--
-- Confirmed locally (as a non-superuser, RLS-enforcing role — the
-- earlier local validation of the downgrade path ran as the Postgres
-- superuser, which bypasses RLS entirely and so never touched this):
-- the exact update Suzanne made reproduced this exact error before
-- these policies existed, and succeeds after.
--
-- Follows the same "read: own row or Staff+; write: Staff+" pattern
-- used for reservations (reservations_own_or_staff) and the
-- item_models/item_units write policies elsewhere in the initial
-- schema migration. student_id is nullable and only descriptive here
-- (whose reservation the downgrade happened during) — only staff+
-- roles can ever reach this trigger in the first place, since only
-- they can update item_units.condition per item_units_write_staff_up.
-- ============================================================
create policy condition_reviews_read_own_or_staff on public.condition_reviews
  for select using (
    student_id = auth.uid() or public.current_user_role() in ('staff','supervisor','admin')
  );
create policy condition_reviews_write_staff_up on public.condition_reviews
  for all using (public.current_user_role() in ('staff','supervisor','admin'))
  with check (public.current_user_role() in ('staff','supervisor','admin'));
