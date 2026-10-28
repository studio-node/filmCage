-- ============================================================
-- reservations_approval_guard(): date-range exemption, confirmed
-- 10/4-10/5.
--
-- Friday pickup/dropoff still always forces approval — unconditional,
-- every role, regardless of who creates the reservation or who it's
-- for. It's a staffing constraint (someone has to physically be
-- there), not a trust judgment, so it's never exempted.
--
-- The <3-day lead-time check and the >3-day loan-window check are
-- now waived when EITHER the reservation holder isn't a student, OR
-- the actor creating/updating the row is Staff+ — covers self-service
-- by staff/supervisor/admin/class_instructor, and covers a staff
-- member building a reservation on behalf of anyone, including a
-- student. Rationale (Suzanne, 10/4): "the point of an admin or
-- staff being able to make a reservation is to bypass set rules on a
-- per case basis" — staff hand-building a reservation are already
-- exercising the judgment these checks exist to gate for.
-- ============================================================

create or replace function public.reservations_approval_guard()
returns trigger language plpgsql as $$
declare
  item_count int;
  loan_days int;
  requires_approval boolean := false;
  holder_role user_role;
  actor_is_staff boolean;
begin
  if new.is_capstone then
    if tg_op = 'INSERT' then
      new.status := 'pending';
    end if;
    return new;
  end if;

  select coalesce(sum(quantity), 0) into item_count
    from public.reservation_items where reservation_id = new.id;

  if item_count > 20 then
    requires_approval := true;
  end if;

  if new.pickup_date is not null and extract(isodow from new.pickup_date) = 5 then
    requires_approval := true; -- Friday pickup — always requires approval, no exceptions
  end if;
  if new.dropoff_date is not null and extract(isodow from new.dropoff_date) = 5 then
    requires_approval := true; -- Friday drop-off — always requires approval, no exceptions
  end if;

  select role into holder_role from public.users where id = new.student_id;
  actor_is_staff := public.current_user_role() in ('staff','supervisor','admin');

  if holder_role = 'student' and not actor_is_staff then
    if new.pickup_date is not null and new.pickup_date < current_date + 3 then
      requires_approval := true; -- under the 3-day minimum lead time
    end if;

    if new.pickup_date is not null and new.dropoff_date is not null then
      loan_days := new.dropoff_date - new.pickup_date;
      if loan_days > 3 then
        requires_approval := true; -- past the default 3-day loan window
      end if;
    end if;
  end if;

  if requires_approval and new.status not in
    ('denied', 'active', 'completed', 'cancelled', 'waitlist_offered')
  then
    new.status := 'pending';
  end if;

  return new;
end;
$$;

-- ============================================================
-- reservations_insert_own_or_staff: real bug found 10/4. The old
-- WITH CHECK only verified created_by = auth.uid() — it never
-- checked role, and never required student_id = auth.uid() for a
-- non-staff inserter, so any signed-in user (including a student)
-- could insert a reservation with student_id set to someone else's
-- account.
--
-- Fixed logic, confirmed 10/4-10/5:
--  - Staff+ can create a reservation for anyone, including a
--    currently blocked/suspended account — intentional override,
--    this is exactly the "per case basis" exception above, not a
--    bug to close.
--  - Self-service (student_id = auth.uid(), no staff involved) is
--    refused only when that account's own role is 'student' AND the
--    account is currently blocked/suspended. A blocked/suspended
--    staff/supervisor/admin/class_instructor can still create their
--    own reservation — no staff intervention required for
--    non-students to self-override.
-- ============================================================

drop policy if exists reservations_insert_own_or_staff on public.reservations;

create policy reservations_insert_own_or_staff on public.reservations
  for insert with check (
    (
      student_id = auth.uid()
      and (
        public.current_user_role() <> 'student'
        or not exists (
          select 1 from public.user_profiles up
          where up.user_id = auth.uid() and (up.is_blocked or up.checkout_suspended)
        )
      )
    )
    or public.current_user_role() in ('staff','supervisor','admin')
  );
