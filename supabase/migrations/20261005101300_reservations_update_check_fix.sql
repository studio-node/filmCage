-- ============================================================
-- Found while validating migration 13 (reservations_approval_guard
-- auto-approve fix), before either was pushed.
--
-- reservations_update_own_editable_or_staff (from the original base
-- migration) was created with only a USING clause and no explicit
-- WITH CHECK. Postgres's default in that case is to reuse the USING
-- expression as the WITH CHECK too — meaning it gets evaluated a
-- second time against the UPDATED row, not just the original one.
--
-- That was invisible before migration 13: reservations_approval_guard
-- never actually set status := 'approved', so a student's own update
-- always left status exactly where it started (usually 'pending'),
-- and the status condition in WITH CHECK always passed trivially.
--
-- Now that migration 13 lets that trigger genuinely move a
-- reservation into 'approved', the app's own re-fire update (touching
-- pickup_date right after reservation_items are inserted, specifically
-- to make the trigger re-evaluate once items exist) gets rejected by
-- this same policy: the resulting NEW row has status = 'approved',
-- which the inherited WITH CHECK reads as "this row already reached a
-- locked status" and blocks.
--
-- But that status value isn't something the student is choosing —
-- it's computed deterministically by the trigger from the
-- reservation's own data (item count, dates, who's holding it). The
-- "can this student even touch this row" gate belongs on the OLD row
-- (status before their edit), not on whatever the trigger decides
-- afterward. So this splits USING (old row: must still be in an
-- editable, non-terminal status) from an explicit WITH CHECK (new
-- row: ownership + not capstone only, no status re-check), restoring
-- the intended "once locked, a student can't initiate further edits"
-- behavior without blocking the trigger's own approve transition.
-- ============================================================

drop policy if exists reservations_update_own_editable_or_staff on public.reservations;

create policy reservations_update_own_editable_or_staff on public.reservations
  for update
  using (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (not is_capstone)
      and status not in ('approved', 'active', 'completed', 'denied', 'cancelled', 'waitlist_offered')
    )
  )
  with check (
    public.current_user_role() in ('staff','supervisor','admin')
    or (
      student_id = auth.uid()
      and (not is_capstone)
    )
  );
