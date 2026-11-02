-- ============================================================
-- Crew-member read access for reservation_units / checkout_sessions.
--
-- Found while building the Pickup screen (migration 25's companion
-- frontend pass): reservation_units_read_own_or_staff and
-- checkout_sessions_read_own_or_staff (9/24) only ever considered the
-- reservation's own student (the director) or Staff+ -- written back
-- when neither table had any real feature using them yet. A crew
-- member who isn't the director has always been able to read the
-- reservation itself (reservations_own_or_staff already covers
-- "named crew", per migration 18) but NOT reservation_units or
-- checkout_sessions on it, which breaks exactly the free-choice crew
-- pickup flow this pass builds: a crew member needs to see which
-- specific units are already claimed by someone else on the same
-- reservation (to correctly compute "still available to pick"), and
-- to see their own and others' checkout_sessions rows (to show who's
-- confirmed so far).
--
-- Added as new, additional policies rather than rewriting the
-- existing ones -- Postgres OR's multiple permissive policies
-- together, so this only ever widens read access, never narrows it.
-- ============================================================

create policy reservation_units_read_crew on public.reservation_units
  for select using (
    exists (
      select 1 from public.reservation_crew rc
      where rc.reservation_id = reservation_units.reservation_id and rc.user_id = auth.uid()
    )
  );

create policy checkout_sessions_read_crew on public.checkout_sessions
  for select using (
    exists (
      select 1 from public.reservation_crew rc
      where rc.reservation_id = checkout_sessions.reservation_id and rc.user_id = auth.uid()
    )
  );
