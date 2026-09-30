-- ============================================================
-- Follow-up to 20260930160000. Suzanne asked whether days_late could
-- also be computed instead of stored -- and for late_return fines,
-- yes: it's just (the day it was resolved, or today if still open)
-- minus the reservation's dropoff_date. Making it a live calculation
-- removes the last piece of this feature that depended on a daily
-- cron job (escalate_late_fines()) that was never actually wired up
-- to a scheduler -- so today, days_late has never once incremented
-- against the real project. Computing it live means there's no job to
-- forget to run: it's simply always correct.
--
-- But chasing that surfaced a real bug in 20260930160000: fines aren't
-- all late-return fees. fine_type also includes damage / missing /
-- other, and those have nothing to do with elapsed days -- a cracked
-- lens needs a dollar amount staff type in directly, not a per-day
-- schedule. The previous migration's view computed current_amount
-- from days_late for every fine regardless of type, which meant a
-- damage fine would always show $0.00 even after staff entered a real
-- amount. This migration brings back a real, staff-settable amount
-- column (renamed manual_amount, to keep it distinct from the view's
-- computed current_amount) and only overrides it with the day-based
-- formula when fine_type = 'late_return'.
--
-- Known simplification, carried over unchanged from the original
-- design: "stop counting" is keyed off fines.resolved_at, not the
-- item's actual return date (there's no return-date column to key off
-- of yet, and Pickup/Return isn't built). A fine put status = 'on_hold'
-- without being resolved will keep accruing live, same ambiguity the
-- original cron-based version had (it only paused on 'warning'/
-- 'active', but never actually ran in the first place). Worth
-- revisiting once Pickup/Return exists and there's a real return
-- timestamp to key off of instead.
-- ============================================================

alter table public.fines
  add column manual_amount numeric(10,2) not null default 0;

-- the 20260930160000 view still reads days_late; drop it before the
-- column, recreate it (with the new shape) further down.
drop view if exists public.fines_with_amount;

alter table public.fines
  drop column days_late;

drop function if exists public.escalate_late_fines();

create or replace view public.fines_with_amount as
select
  f.id,
  f.student_id,
  f.reservation_id,
  f.unit_id,
  f.fine_type,
  f.status,
  computed.days_late,
  case when f.fine_type = 'late_return' then public.fine_rate_for_day(computed.days_late) else null end as rate_per_day,
  case when f.fine_type = 'late_return' then public.fine_current_amount(computed.days_late) else f.manual_amount end as current_amount,
  f.manual_amount,
  f.escalation_note,
  f.created_at,
  f.resolved_at,
  f.resolved_by
from public.fines f
left join public.reservations r on r.id = f.reservation_id
left join lateral (
  select case
    when f.fine_type = 'late_return' and r.dropoff_date is not null
      then greatest(0, (coalesce(f.resolved_at::date, current_date) - r.dropoff_date))::int
    else null
  end as days_late
) computed on true;
