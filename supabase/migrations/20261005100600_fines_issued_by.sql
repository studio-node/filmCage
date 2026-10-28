-- ============================================================
-- fines.issued_by: nothing currently tracks who *issued* a fine,
-- only resolved_by (who resolved it). Confirmed 10/4: a staff-decided
-- dollar charge is exactly the "accountable transaction" the rest of
-- this review says should be tracked.
--
-- Nullable, same shape as resolved_by — populated by the app from the
-- signed-in session at insert, same convention as every other
-- created_by-style column in this schema (no DB-level default here
-- either). The only case issued_by should ever be null is a
-- late-return fine with no staff author (not something any current
-- trigger generates yet — escalate_late_fines() was removed in
-- 20260930170000 and only ever escalated an existing fine's
-- days_late, never created one from nothing — but the column is
-- nullable now so that future system-generated path has somewhere to
-- land). Enforced with a CHECK mirroring student_notes'
-- strike_reason_required: only a late_return fine can have a null
-- issuer. No system/service account for this — a null issued_by
-- always means "late fee" since that's the only path that can
-- produce one; the frontend displays coalesce(staff_name, 'Late
-- Fees') wherever the issuer would show.
-- ============================================================

alter table public.fines
  add column issued_by uuid references public.users(id);

alter table public.fines
  add constraint fines_issued_by_required check (
    issued_by is not null or fine_type = 'late_return'
  );
