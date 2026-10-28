-- ============================================================
-- Group reservations: let an item's quantity be split across more
-- than one crew member, not just assigned as a whole (migration 23).
--
-- Suzanne's question (10/22): for a group reservation, if an item has
-- quantity > 1 (e.g. 3 lav mics), right now only ONE person can be
-- assigned the whole line -- there's no way to say "2 of these go to
-- Alice, 1 goes to Bob." She asked whether that's just a UI gap or a
-- real database limit. It's a real database limit:
-- `reservation_assignments` was defined (initial migration) with
-- `primary key (reservation_id, item_model_id)` and NO quantity
-- column at all -- there is nowhere to record a split even if the UI
-- wanted to show one. This migration is Option A from that
-- discussion: keep `reservation_items` exactly as it is (one
-- aggregate row per item model, holding the total quantity -- no
-- change needed there for inventory/approval-math purposes, which all
-- read reservation_items.quantity, never reservation_assignments),
-- and instead let `reservation_assignments` hold MULTIPLE rows per
-- item model, each carrying its own quantity, as long as they sum to
-- no more than the item's total. Per Suzanne: this isn't wired up to
-- anything yet, but it's expected to matter once Pickup/Return
-- (checkout) is built -- that's the natural place "who's actually
-- responsible for which units" gets used.
--
-- The alternative (Option B, not chosen) would have exploded every
-- quantity>1 item into N separate reservation_items rows -- rejected
-- because it would have touched the live-availability check, the
-- waitlist-split logic, and the item-count approval math, all of
-- which currently assume one row per item model per reservation, for
-- a UI-only outcome Option A gets more cheaply.
--
-- Two guard triggers come along with this, both following the
-- existing "a hard, physical-style constraint is a rejection, not a
-- requires_approval flag" pattern already used for the inventory
-- check (migration 20):
--   1. reservation_assignments_quantity_guard -- the sum of a given
--      item's assignment rows can never exceed that item's quantity
--      on reservation_items. Without this, nothing would stop
--      assigning 2 lav mics to Alice and 2 more to Bob on a
--      reservation that only has 3.
--   2. reservation_items_quantity_guard -- the reverse direction:
--      reservation_items.quantity can't be reduced below however much
--      is already split across assignees (ReservationDetailView.vue's
--      item-edit flow lets staff/students change quantity after
--      creation -- without this, shrinking a 3-mic line to 1 would
--      silently leave split assignments totaling 3 on a line that now
--      only has 1).
-- Found along the way, fixed in the same migration since it's
-- directly adjacent and cheap: reservation_assignments had no FK tie
-- to reservation_items at all, so deleting an item line (same
-- ReservationDetailView.vue flow) has always silently left its
-- assignment row(s) behind as orphaned junk, pointing at an item
-- model no longer on the reservation. Added a cleanup trigger so a
-- deleted item line's assignments go with it.
-- ============================================================

-- ---- 1. widen reservation_assignments to allow a split -----------------

alter table public.reservation_assignments
  drop constraint reservation_assignments_pkey;

alter table public.reservation_assignments
  add column id uuid not null default gen_random_uuid(),
  add column quantity int;

-- Backfill: every existing row represented the item's whole quantity
-- (that was the only option before this migration), so give it
-- reservation_items.quantity for the same (reservation_id,
-- item_model_id) pair. Falls back to 1 only for an orphaned row with
-- no matching reservation_items line at all (shouldn't exist, but
-- this is a backfill, not a place to raise an exception over it).
update public.reservation_assignments ra
set quantity = coalesce(
  (
    select ri.quantity
    from public.reservation_items ri
    where ri.reservation_id = ra.reservation_id
      and ri.item_model_id = ra.item_model_id
  ),
  1
);

alter table public.reservation_assignments
  alter column quantity set not null,
  add constraint reservation_assignments_quantity_positive check (quantity > 0);

alter table public.reservation_assignments
  add primary key (id);

-- One row per person per item per reservation -- a second edit to the
-- same person's split updates their existing row instead of creating
-- a duplicate.
alter table public.reservation_assignments
  add constraint reservation_assignments_unique_person
  unique (reservation_id, item_model_id, assigned_to_user_id);

-- ---- 2. hard rejection: a split can never exceed the item's quantity ----

create or replace function public.reservation_assignments_quantity_guard()
returns trigger
language plpgsql
as $$
declare
  v_item_qty int;
  v_already_assigned int;
begin
  select quantity into v_item_qty
    from public.reservation_items
    where reservation_id = new.reservation_id
      and item_model_id = new.item_model_id;

  if v_item_qty is null then
    raise exception 'Cannot assign an item that is not on this reservation.';
  end if;

  select coalesce(sum(quantity), 0) into v_already_assigned
    from public.reservation_assignments
    where reservation_id = new.reservation_id
      and item_model_id = new.item_model_id
      and id is distinct from new.id;

  if v_already_assigned + new.quantity > v_item_qty then
    raise exception
      'Cannot assign % of this item -- only % of the % total are still unassigned.',
      new.quantity, v_item_qty - v_already_assigned, v_item_qty;
  end if;

  return new;
end;
$$;

create trigger reservation_assignments_quantity_guard
  before insert or update of quantity, item_model_id, reservation_id
  on public.reservation_assignments
  for each row
  execute function public.reservation_assignments_quantity_guard();

-- ---- 3. the reverse direction: can't shrink below what's assigned ------

create or replace function public.reservation_items_quantity_guard()
returns trigger
language plpgsql
as $$
declare
  v_already_assigned int;
begin
  if new.quantity = old.quantity then
    return new;
  end if;

  select coalesce(sum(quantity), 0) into v_already_assigned
    from public.reservation_assignments
    where reservation_id = new.reservation_id
      and item_model_id = new.item_model_id;

  if new.quantity < v_already_assigned then
    raise exception
      'Cannot reduce quantity to % -- % is already split across crew members for this item. Adjust the assignments first.',
      new.quantity, v_already_assigned;
  end if;

  return new;
end;
$$;

create trigger reservation_items_quantity_guard
  before update of quantity on public.reservation_items
  for each row
  execute function public.reservation_items_quantity_guard();

-- ---- 4. found along the way: deleting an item line orphaned its --------
-- ---- assignment row(s) -- clean them up together instead ---------------

create or replace function public.reservation_items_delete_cleans_assignments()
returns trigger
language plpgsql
as $$
begin
  delete from public.reservation_assignments
  where reservation_id = old.reservation_id
    and item_model_id = old.item_model_id;
  return old;
end;
$$;

create trigger reservation_items_delete_cleans_assignments
  after delete on public.reservation_items
  for each row
  execute function public.reservation_items_delete_cleans_assignments();
