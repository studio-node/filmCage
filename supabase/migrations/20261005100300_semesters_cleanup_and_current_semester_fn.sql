-- ============================================================
-- semesters cleanup, confirmed 10/1-10/4:
--  - is_current was a manually-flipped flag that could drift from
--    reality; dropped in favor of computing "is this the current
--    semester" live from start_date/end_date. public.current_semester_id()
--    below replaces every place is_current was being read.
--  - created_by: dropped — "only 1 admin at a time" can touch
--    semesters (enforced by Admin-only RLS, see the prior migration),
--    so tracking who isn't needed.
--  - created_at: dropped — nothing ever needed "when was this
--    semester row entered," only its actual start_date/end_date.
-- ============================================================

drop index if exists public.semesters_one_current;

alter table public.semesters
  drop column is_current,
  drop column created_by,
  drop column created_at;

create or replace function public.current_semester_id()
returns uuid
language sql stable as $$
  select id from public.semesters
  where current_date between start_date and end_date
  limit 1;
$$;
