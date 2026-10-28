// Maps the real schema's enums to the design system's visual tone
// classes (good / warn / crit / muted — see src/styles/components.css).
//
// The mockup this design was ported from only had three states
// (good/warn/crit). Our actual schema has more, so this is the one
// place that decides how each real enum value reads visually:
//   - item_units.condition: good | caution | damaged | missing
//   - fines.status:          warning | active | on_hold | resolved
//   - reservations.status:   see ReservationStatus below
//
// Components should import `toneFor*` helpers rather than hardcoding
// enum-to-class logic themselves, so if the mapping ever changes it
// changes in one place.

export type UnitCondition = 'good' | 'caution' | 'damaged' | 'missing'
export type Tone = 'good' | 'warn' | 'crit' | 'muted' | 'neutral' | 'accent' | 'violet'

export function toneForCondition(condition: UnitCondition): Tone {
  switch (condition) {
    case 'good':
      return 'good'
    case 'caution':
      return 'warn'
    case 'damaged':
      return 'crit'
    case 'missing':
      return 'muted'
  }
}

// Matches item_units_condition_guard()'s rank_map exactly (see the
// initial schema migration's business-rule triggers) — a higher number
// is a better condition. Used client-side to detect a real downgrade
// so the UI can require a note before saving, the same rule the
// database trigger enforces; keep these in sync if the scale changes.
export function conditionRank(condition: UnitCondition): number {
  switch (condition) {
    case 'missing':
      return -1
    case 'damaged':
      return 0
    case 'caution':
      return 1
    case 'good':
      return 2
  }
}

export function conditionLabel(condition: UnitCondition): string {
  switch (condition) {
    case 'good':
      return 'Good'
    case 'caution':
      return 'Caution'
    case 'damaged':
      return 'Damaged'
    case 'missing':
      return 'Missing'
  }
}

export type FineStatus = 'warning' | 'active' | 'on_hold' | 'resolved'

export function toneForFineStatus(status: FineStatus): Tone {
  switch (status) {
    case 'warning':
      return 'warn'
    case 'active':
      return 'crit'
    case 'on_hold':
      return 'muted'
    case 'resolved':
      return 'good'
  }
}

// Matches public.reservation_status exactly (see the initial schema
// migration) — do not add or rename values here without a matching
// migration, since this is a straight mirror of the DB enum.
export type ReservationStatus =
  | 'pending'
  | 'denied'
  | 'waitlisted'
  | 'waitlist_offered'
  | 'cancelled'
  | 'awaiting_appointment'
  | 'awaiting_schedule'
  | 'approved'
  | 'active'
  | 'completed'

export function toneForReservationStatus(status: ReservationStatus): Tone {
  switch (status) {
    case 'pending':
    case 'awaiting_appointment':
    case 'awaiting_schedule':
      return 'warn'
    case 'waitlisted':
    case 'waitlist_offered':
      return 'violet'
    case 'approved':
      return 'accent'
    case 'denied':
    case 'cancelled':
      return 'muted'
    case 'active':
      return 'accent'
    case 'completed':
      return 'good'
  }
}

export function reservationStatusLabel(status: ReservationStatus): string {
  switch (status) {
    case 'pending':
      return 'Pending approval'
    case 'denied':
      return 'Denied'
    case 'waitlisted':
      return 'Waitlisted'
    case 'waitlist_offered':
      return 'Waitlist offer'
    case 'cancelled':
      return 'Cancelled'
    case 'awaiting_appointment':
      return 'Awaiting appointment'
    case 'awaiting_schedule':
      return 'Awaiting schedule'
    case 'approved':
      return 'Approved'
    case 'active':
      return 'Checked out'
    case 'completed':
      return 'Completed'
  }
}

// Matches public.unit_status exactly (see migration
// 20261007110000_item_unit_lifecycle_status) — a separate axis from
// condition above. condition is a point-in-time quality read tied to
// checkout/return; status is "is this unit part of the working fleet
// right now." out_for_repair is the one temporary state (expected to
// flip back to active); retired/lost/stolen are all permanent, just
// different paper trails.
export type UnitStatus = 'active' | 'out_for_repair' | 'retired' | 'lost' | 'stolen'

export function toneForUnitStatus(status: UnitStatus): Tone {
  switch (status) {
    case 'active':
      return 'good'
    case 'out_for_repair':
      return 'warn'
    case 'retired':
      return 'muted'
    case 'lost':
    case 'stolen':
      return 'crit'
  }
}

export function unitStatusLabel(status: UnitStatus): string {
  switch (status) {
    case 'active':
      return 'Active'
    case 'out_for_repair':
      return 'Out for repair'
    case 'retired':
      return 'Retired'
    case 'lost':
      return 'Lost'
    case 'stolen':
      return 'Stolen'
  }
}
