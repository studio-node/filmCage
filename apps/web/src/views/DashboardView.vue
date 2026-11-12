<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { errorMessage } from '../lib/errors'
import {
  toneForFineStatus,
  toneForReservationStatus,
  reservationStatusLabel,
  type ReservationStatus,
} from '../lib/conditionStatus'

interface StudentProfile {
  tier: string
  strike_count: number
  is_blocked: boolean
  checkout_suspended: boolean
  suspended_reason: string | null
}

interface FineRow {
  id: string
  fine_type: string
  status: 'warning' | 'active' | 'on_hold' | 'resolved'
  current_amount: number
}

interface ReservationRow {
  id: string
  reservation_name: string
  status: ReservationStatus
  pickup_date: string | null
  locations: { name: string } | null
}

interface NotificationRow {
  id: string
  title: string
  body: string | null
  is_read: boolean
  created_at: string
}

// A student flagged their own account for tier review (changed their
// class on the new profile drawer) — self-service editing never
// moves tier itself, only this flag, so staff decide from here
// whether the new class's mapped tier actually takes effect. Folded
// into the same "Needs your approval" list as reservations below (11/11
// pass) rather than its own separate card — same kind of item from a
// staff member's point of view, just a different shape.
interface TierChangeRow {
  user_id: string
  updated_at: string
  tier: 'beginner' | 'intermediate' | 'advanced' | null
  class_taken: string | null
  users: { full_name: string; email: string } | null
  course_tier_mappings: {
    course_name: string
    course_code: string | null
    tier: 'beginner' | 'intermediate' | 'advanced'
  } | null
}

// One row shape, fed by one query, used for BOTH "needs your approval"
// (status === 'pending') and "upcoming pickups & drop-offs" (any of
// pending/approved/active with a date set) — see appointmentEvents
// below. Mirrors ReservationQueueView.vue's own ReservationRow closely
// on purpose, since the approval half of this card reuses that same
// permission rule and the same reasons()/formatDate() logic.
interface DashboardReservationRow {
  id: string
  reservation_name: string
  status: ReservationStatus
  is_capstone: boolean
  is_group_reservation: boolean
  capstone_appointment_date: string | null
  appointment_completed: boolean
  pickup_date: string | null
  pickup_time: string | null
  dropoff_date: string | null
  dropoff_time: string | null
  created_at: string
  locations: { name: string } | null
  reservation_items: { quantity: number; item_models: { name: string } | null }[]
  student: { id: string; full_name: string | null; email: string | null } | null
}

type ApprovalItem =
  | { kind: 'reservation'; at: string; row: DashboardReservationRow }
  | { kind: 'tier_change'; at: string; row: TierChangeRow }

interface AppointmentEvent {
  type: 'pickup' | 'dropoff'
  date: string
  time: string | null
  reservation: DashboardReservationRow
}

const auth = useAuthStore()
const router = useRouter()
const loading = ref(true)
const error = ref('')

const profile = ref<StudentProfile | null>(null)
const fines = ref<FineRow[]>([])
const reservations = ref<ReservationRow[]>([])
const notifications = ref<NotificationRow[]>([])

const dashboardReservations = ref<DashboardReservationRow[]>([])
const tierChanges = ref<TierChangeRow[]>([])
const loadingStaff = ref(false)
const staffError = ref('')
const actionBusy = ref<Record<string, boolean>>({})
const actionErrors = ref<Record<string, string>>({})
const denyingId = ref<string | null>(null)
const denyReason = ref('')
const STAFF_PLUS_ROLES = ['staff', 'supervisor', 'admin']

const DASH_RESERVATION_FIELDS = `id, reservation_name, status, is_capstone, is_group_reservation,
  capstone_appointment_date, appointment_completed,
  pickup_date, pickup_time, dropoff_date, dropoff_time, created_at,
  locations(name),
  reservation_items(quantity, item_models(name)),
  student:users!reservations_student_id_fkey(id, full_name, email)`

const APPROVAL_ITEM_THRESHOLD = 20
const LEAD_TIME_DAYS = 3
const CAPSTONE_LEAD_TIME_DAYS = 7
const LOAN_WINDOW_DAYS = 3

// A plain `staff` actor can never approve/deny their OWN personal
// reservation — reservations_approval_guard() rejects it outright
// regardless of this filter (supervisor/admin CAN self-approve). This
// is the exact same permission rule ReservationQueueView.vue's own
// pendingRows already applies — kept in sync by hand since there's no
// shared composable for it yet; if that rule ever changes, change it
// in both places.
function canActOnReservation(r: DashboardReservationRow) {
  return !(auth.role === 'staff' && r.student?.id === auth.user?.id)
}

// Mirrors reservations_approval_guard()'s own rules — purely
// informational, same logic as ReservationQueueView.vue's reasons().
function reservationReasons(r: DashboardReservationRow): string[] {
  const out: string[] = []
  const itemCount = r.reservation_items.reduce((sum, l) => sum + l.quantity, 0)
  if (itemCount > APPROVAL_ITEM_THRESHOLD) out.push(`Over ${APPROVAL_ITEM_THRESHOLD} items`)
  const isFriday = (d: string | null) => d && new Date(d + 'T12:00:00').getDay() === 5
  if (isFriday(r.pickup_date)) out.push('Friday pickup')
  if (isFriday(r.dropoff_date)) out.push('Friday drop-off')
  if (r.pickup_date) {
    const leadTimeDays = r.is_capstone ? CAPSTONE_LEAD_TIME_DAYS : LEAD_TIME_DAYS
    const leadDays = (new Date(r.pickup_date + 'T12:00:00').getTime() - Date.now()) / 86400000
    if (leadDays < leadTimeDays) out.push(`Under ${leadTimeDays}-day lead time`)
  }
  if (r.pickup_date && r.dropoff_date) {
    const loanDays =
      (new Date(r.dropoff_date + 'T12:00:00').getTime() - new Date(r.pickup_date + 'T12:00:00').getTime()) / 86400000
    if (loanDays > LOAN_WINDOW_DAYS) out.push(`Over ${LOAN_WINDOW_DAYS}-day loan window`)
  }
  return out
}

function itemSummary(r: DashboardReservationRow) {
  return (
    r.reservation_items
      .map((l) => `${l.item_models?.name ?? 'Unknown item'}${l.quantity > 1 ? ` ×${l.quantity}` : ''}`)
      .join(', ') || 'No items'
  )
}

// The unified approvals list — reservations pending approval (filtered
// to only what the viewer's own role can act on) plus tier-reconfirmation
// requests, merged into one list and sorted oldest-first so the
// longest-waiting item floats to the top regardless of which kind it
// is. Replaces the old separate "Pending tier changes" card — Suzanne's
// ask (11/11): "no need to have a second separate tier change area."
const approvalItems = computed<ApprovalItem[]>(() => {
  const resItems: ApprovalItem[] = dashboardReservations.value
    .filter((r) => r.status === 'pending' && canActOnReservation(r))
    .map((r) => ({ kind: 'reservation' as const, at: r.created_at, row: r }))
  const tierItems: ApprovalItem[] = tierChanges.value.map((r) => ({
    kind: 'tier_change' as const,
    at: r.updated_at,
    row: r,
  }))
  return [...resItems, ...tierItems].sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime())
})

// Upcoming pickups & drop-offs — a flat, chronological list for now
// ("eventually a full calendar... for now just a list", per Suzanne).
// A reservation contributes a pickup event only while it's still
// pending/approved (once active, the pickup already happened — that
// date is history, not an upcoming appointment); it contributes a
// drop-off event at any of pending/approved/active, since the return
// is still ahead of it either way.
const todayStr = new Date().toISOString().slice(0, 10)

const appointmentEvents = computed<AppointmentEvent[]>(() => {
  const events: AppointmentEvent[] = []
  for (const r of dashboardReservations.value) {
    if ((r.status === 'pending' || r.status === 'approved') && r.pickup_date) {
      events.push({ type: 'pickup', date: r.pickup_date, time: r.pickup_time, reservation: r })
    }
    if (r.dropoff_date) {
      events.push({ type: 'dropoff', date: r.dropoff_date, time: r.dropoff_time, reservation: r })
    }
  }
  return events.sort((a, b) => {
    const byDate = a.date.localeCompare(b.date)
    if (byDate !== 0) return byDate
    return (a.time ?? '').localeCompare(b.time ?? '')
  })
})

interface AppointmentDayGroup {
  date: string
  label: string
  events: AppointmentEvent[]
}

function dayLabel(dateStr: string) {
  const diffDays = Math.round(
    (new Date(dateStr + 'T00:00:00').getTime() - new Date(todayStr + 'T00:00:00').getTime()) / 86400000
  )
  if (diffDays === 0) return 'Today'
  if (diffDays === 1) return 'Tomorrow'
  const label = new Date(dateStr + 'T00:00:00').toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  })
  return diffDays < 0 ? `${label} — overdue` : label
}

// appointmentEvents is already sorted ascending, so the Map below
// groups by day in the same ascending order (JS Maps preserve
// insertion order) — no separate sort needed here.
const appointmentGroups = computed<AppointmentDayGroup[]>(() => {
  const byDate = new Map<string, AppointmentEvent[]>()
  for (const e of appointmentEvents.value) {
    if (!byDate.has(e.date)) byDate.set(e.date, [])
    byDate.get(e.date)!.push(e)
  }
  return [...byDate.entries()].map(([date, events]) => ({ date, label: dayLabel(date), events }))
})

// --- Pickup widget (Pickup/Return tab, see PickupReturnView.vue) --
// A lightweight count, not the full fetch that view does -- same
// "30 minutes before the scheduled time, and I haven't already
// submitted my half" rule, just trimmed to what a count needs.
const readyForPickupCount = ref(0)
const pendingPickupConfirmCount = ref(0)
const pendingReturnCheckinCount = ref(0)

interface PickupProbeRow {
  id: string
  status: string
  is_group_reservation: boolean
  allow_individual_pickup_times: boolean
  pickup_date: string | null
  pickup_time: string | null
  reservation_crew: { user_id: string; pickup_time_override: string | null }[]
  checkout_sessions: { phase: string; person_user_id: string | null; person_confirmed_at: string | null; staff_confirmed_at: string | null }[]
}
const PICKUP_PROBE_FIELDS = `id, status, is_group_reservation, allow_individual_pickup_times, pickup_date, pickup_time,
  reservation_crew(user_id, pickup_time_override),
  checkout_sessions(phase, person_user_id, person_confirmed_at, staff_confirmed_at)`

function isReadyForMe(r: PickupProbeRow, userId: string) {
  const already = r.checkout_sessions.some((s) => s.phase === 'pickup' && s.person_user_id === userId && s.person_confirmed_at)
  if (already) return false
  const crewRow = r.reservation_crew.find((c) => c.user_id === userId)
  let t = r.pickup_time
  if (r.is_group_reservation && r.allow_individual_pickup_times && crewRow?.pickup_time_override) {
    t = crewRow.pickup_time_override
  }
  if (!r.pickup_date || !t) return false
  const scheduledAt = new Date(`${r.pickup_date}T${t}`)
  return Date.now() >= scheduledAt.getTime() - 30 * 60000
}

async function loadReadyForPickupCount(userId: string) {
  try {
    const [ownedRes, crewRes] = await Promise.all([
      supabase.from('reservations').select(PICKUP_PROBE_FIELDS).eq('student_id', userId).in('status', ['approved', 'active']),
      supabase.from('reservation_crew').select(`reservations(${PICKUP_PROBE_FIELDS})`).eq('user_id', userId),
    ])
    const owned = (ownedRes.data ?? []) as unknown as PickupProbeRow[]
    const seen = new Set(owned.map((r) => r.id))
    const asCrew: PickupProbeRow[] = []
    for (const row of (crewRes.data ?? []) as unknown as { reservations: PickupProbeRow | null }[]) {
      const r = row.reservations
      if (!r || seen.has(r.id) || (r.status !== 'approved' && r.status !== 'active')) continue
      seen.add(r.id)
      asCrew.push(r)
    }
    readyForPickupCount.value = [...owned, ...asCrew].filter((r) => isReadyForMe(r, userId)).length
  } catch {
    readyForPickupCount.value = 0
  }
}

async function loadPendingPickupConfirmCount() {
  try {
    const { data } = await supabase
      .from('reservations')
      .select(PICKUP_PROBE_FIELDS)
      .in('status', ['approved', 'active'])
    const rows = (data ?? []) as unknown as PickupProbeRow[]
    pendingPickupConfirmCount.value = rows.filter((r) =>
      r.checkout_sessions.some((s) => s.phase === 'pickup' && s.person_confirmed_at && !s.staff_confirmed_at)
    ).length
    pendingReturnCheckinCount.value = rows.filter((r) =>
      r.checkout_sessions.some((s) => s.phase === 'return' && s.person_confirmed_at && !s.staff_confirmed_at)
    ).length
  } catch {
    pendingPickupConfirmCount.value = 0
    pendingReturnCheckinCount.value = 0
  }
}

const outstandingTotal = computed(() =>
  fines.value.reduce((sum, f) => sum + Number(f.current_amount), 0)
)
const activeCount = computed(
  () => reservations.value.filter((r) => r.status === 'active').length
)
const pendingCount = computed(
  () =>
    reservations.value.filter((r) =>
      ['pending', 'awaiting_appointment', 'awaiting_schedule'].includes(r.status)
    ).length
)
// Reservation counts above are only accurate against the fetched page of
// recent reservations (see the query note below) — fine for a starter
// dashboard, but worth swapping for real count() queries once reservation
// history can grow past a handful of rows per student.

async function loadStudentDashboard(userId: string) {
  loading.value = true
  error.value = ''
  try {
    const [profileRes, finesRes, reservationsRes, notificationsRes] = await Promise.all([
      supabase
        .from('user_profiles')
        .select('tier, strike_count, is_blocked, checkout_suspended, suspended_reason')
        .eq('user_id', userId)
        .maybeSingle(),
      supabase
        .from('fines_with_amount')
        .select('id, fine_type, status, current_amount')
        .eq('student_id', userId)
        .in('status', ['warning', 'active']),
      supabase
        .from('reservations')
        .select('id, reservation_name, status, pickup_date, locations(name)')
        .eq('student_id', userId)
        .order('created_at', { ascending: false })
        .limit(8),
      supabase
        .from('notifications')
        .select('id, title, body, is_read, created_at')
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .limit(5),
    ])

    if (profileRes.error) throw profileRes.error
    if (finesRes.error) throw finesRes.error
    if (reservationsRes.error) throw reservationsRes.error
    if (notificationsRes.error) throw notificationsRes.error

    profile.value = profileRes.data as StudentProfile | null
    fines.value = (finesRes.data ?? []) as FineRow[]
    reservations.value = (reservationsRes.data ?? []) as unknown as ReservationRow[]
    notifications.value = (notificationsRes.data ?? []) as NotificationRow[]
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to load dashboard data'
  } finally {
    loading.value = false
  }
  // Not part of the Promise.all above -- a failure here shouldn't take
  // down the rest of the dashboard, so it's caught entirely inside
  // loadReadyForPickupCount itself.
  loadReadyForPickupCount(userId)
}

async function loadStaffDashboard() {
  loadingStaff.value = true
  staffError.value = ''
  try {
    const [resRes, tierRes] = await Promise.all([
      supabase
        .from('reservations')
        .select(DASH_RESERVATION_FIELDS)
        .in('status', ['pending', 'approved', 'active'])
        .order('created_at', { ascending: true }),
      supabase
        .from('user_profiles')
        .select(
          'user_id, updated_at, tier, class_taken, users!user_profiles_user_id_fkey(full_name, email), course_tier_mappings!user_profiles_class_taken_fkey(course_name, course_code, tier)'
        )
        .eq('needs_tier_reconfirmation', true),
    ])
    if (resRes.error) throw resRes.error
    if (tierRes.error) throw tierRes.error
    dashboardReservations.value = (resRes.data ?? []) as unknown as DashboardReservationRow[]
    tierChanges.value = (tierRes.data ?? []) as unknown as TierChangeRow[]
  } catch (e) {
    staffError.value = errorMessage(e, 'Could not load the staff dashboard.')
  } finally {
    loadingStaff.value = false
  }
  loadPendingPickupConfirmCount()
}

function setActionBusy(id: string, val: boolean) {
  actionBusy.value = { ...actionBusy.value, [id]: val }
}
function setActionError(id: string, msg: string) {
  actionErrors.value = { ...actionErrors.value, [id]: msg }
}

async function confirmTierChange(row: TierChangeRow) {
  const newTier = row.course_tier_mappings?.tier
  if (!newTier) return
  setActionError(row.user_id, '')
  setActionBusy(row.user_id, true)
  try {
    const { error } = await supabase
      .from('user_profiles')
      .update({ tier: newTier, needs_tier_reconfirmation: false })
      .eq('user_id', row.user_id)
    if (error) throw error
    tierChanges.value = tierChanges.value.filter((r) => r.user_id !== row.user_id)
  } catch (e) {
    setActionError(row.user_id, errorMessage(e, 'Could not confirm this tier change.'))
  } finally {
    setActionBusy(row.user_id, false)
  }
}

async function dismissTierChange(row: TierChangeRow) {
  setActionError(row.user_id, '')
  setActionBusy(row.user_id, true)
  try {
    const { error } = await supabase
      .from('user_profiles')
      .update({ needs_tier_reconfirmation: false })
      .eq('user_id', row.user_id)
    if (error) throw error
    tierChanges.value = tierChanges.value.filter((r) => r.user_id !== row.user_id)
  } catch (e) {
    setActionError(row.user_id, errorMessage(e, 'Could not dismiss this request.'))
  } finally {
    setActionBusy(row.user_id, false)
  }
}

// Reservation approve/deny/mark-meeting-complete — same RPC-free direct
// updates ReservationQueueView.vue uses (reservations_approval_guard
// does the real enforcement either way), just reachable from the
// dashboard's own compact card so staff don't have to jump to the full
// Queue for the common case. Refetches afterward rather than splicing
// locally, since an approve/deny also changes which appointment bucket
// the row falls into below.
async function approveReservation(r: DashboardReservationRow) {
  setActionBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error } = await supabase
      .from('reservations')
      .update({ status: 'approved', approved_by: auth.user!.id, approved_at: new Date().toISOString() })
      .eq('id', r.id)
    if (error) throw error
    await loadStaffDashboard()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not approve this reservation.'))
    setActionBusy(r.id, false)
  }
}

function startDenyReservation(r: DashboardReservationRow) {
  denyingId.value = r.id
  denyReason.value = ''
}
function cancelDenyReservation() {
  denyingId.value = null
  denyReason.value = ''
}
async function confirmDenyReservation(r: DashboardReservationRow) {
  if (!denyReason.value.trim()) return
  setActionBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error } = await supabase
      .from('reservations')
      .update({ status: 'denied', denial_reason: denyReason.value.trim() })
      .eq('id', r.id)
    if (error) throw error
    denyingId.value = null
    denyReason.value = ''
    await loadStaffDashboard()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not deny this reservation.'))
    setActionBusy(r.id, false)
  }
}

async function markAppointmentComplete(r: DashboardReservationRow) {
  setActionBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error } = await supabase.from('reservations').update({ appointment_completed: true }).eq('id', r.id)
    if (error) throw error
    await loadStaffDashboard()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not mark the meeting complete.'))
    setActionBusy(r.id, false)
  }
}

function openReservation(r: DashboardReservationRow) {
  router.push({ name: 'reservation-detail', params: { id: r.id } })
}

// This dashboard is the student view — checkouts, fines, and
// reservations all scoped to the signed-in student. Staff/supervisor/
// admin get a real approval queue (reservations + tier changes, merged
// and permission-filtered — see approvalItems above) and an upcoming
// pickups/drop-offs list (see appointmentGroups above). Org-wide
// checkout status beyond what's listed here, and analytics, are still
// a later build phase.
const isStudentView = computed(() => !auth.role || auth.role === 'student')

watch(
  () => [auth.user?.id, auth.role] as const,
  ([userId, role]) => {
    if (userId && isStudentView.value) {
      loadStudentDashboard(userId)
    } else {
      loading.value = false
      if (userId && role && STAFF_PLUS_ROLES.includes(role)) loadStaffDashboard()
    }
  },
  { immediate: true }
)

function formatDate(date: string | null) {
  if (!date) return '—'
  return new Date(date + 'T00:00:00').toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
  })
}

function formatTime(t: string | null) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}

function timeAgo(iso: string) {
  const diffMs = Date.now() - new Date(iso).getTime()
  const mins = Math.round(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hours = Math.round(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Dashboard</span>
        <h1>Welcome back{{ auth.fullName ? `, ${auth.fullName.split(' ')[0]}` : '' }}</h1>
      </div>
      <span v-if="isStudentView && profile" class="badge violet">{{ profile.tier }} tier</span>
      <span v-else-if="!isStudentView && auth.role" class="badge accent" style="text-transform: capitalize">{{
        auth.role
      }}</span>
    </div>

    <div v-if="!isStudentView" style="display: flex; flex-direction: column; gap: 22px">
      <div class="card">
        <div class="section-title" style="margin-bottom: 6px">
          {{
            auth.role === 'admin'
              ? 'Admin'
              : auth.role === 'supervisor'
                ? 'Supervisor'
                : auth.role === 'class_instructor'
                  ? 'Class Instructor'
                  : 'Staff'
          }}
          dashboard
        </div>
        <p style="color: var(--ink-2)">
          Org-wide analytics and a full calendar view are still coming in a later build phase. For
          now: everything below that needs your approval, and every upcoming pickup/drop-off, in
          one place.
        </p>
      </div>

      <div
        v-if="pendingPickupConfirmCount > 0"
        class="banner"
        style="background: var(--accent-soft); border: 1px solid var(--accent-soft-border); color: var(--accent-strong)"
      >
        <span>
          <strong
            >{{ pendingPickupConfirmCount }} checkout{{ pendingPickupConfirmCount === 1 ? '' : 's' }} waiting on your
            confirmation.</strong
          >
        </span>
        <router-link :to="{ name: 'pickup' }" class="btn primary small">Go to Pickup</router-link>
      </div>

      <div
        v-if="pendingReturnCheckinCount > 0"
        class="banner"
        style="background: var(--warn-soft); border: 1px solid var(--warn-border); color: var(--warn)"
      >
        <span>
          <strong
            >{{ pendingReturnCheckinCount }} return{{ pendingReturnCheckinCount === 1 ? '' : 's' }} waiting for staff
            check-in.</strong
          >
          A reservation isn't completed until its equipment is checked in.
        </span>
        <router-link :to="{ name: 'pickup' }" class="btn primary small">Go to Returns</router-link>
      </div>

      <!-- ============ Needs your approval — reservations + tier changes, merged, permission-filtered ============ -->
      <div class="card">
        <div class="section-title" style="margin-bottom: 2px">
          Needs your approval
          <span v-if="approvalItems.length" class="badge-mini">{{ approvalItems.length }}</span>
        </div>
        <p class="field-hint" style="margin-bottom: 12px">
          Reservations and tier-change requests you're able to act on — a plain staff account's own
          reservation is left off this list for everyone else to review, same as the Reservation
          Queue.
        </p>
        <p v-if="loadingStaff">Loading…</p>
        <p v-else-if="staffError" class="error-note">{{ staffError }}</p>
        <p v-else-if="approvalItems.length === 0" class="empty-note">Nothing waiting on approval.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 10px">
          <!-- Reservation approval item -->
          <div
            v-for="item in approvalItems"
            :key="`${item.kind}-${item.kind === 'reservation' ? item.row.id : item.row.user_id}`"
            class="card-flat"
          >
            <template v-if="item.kind === 'reservation'">
              <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
                <div>
                  <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
                    <span class="badge accent" v-if="item.row.is_capstone">Capstone</span>
                    <span class="badge violet" v-if="item.row.is_group_reservation">Group production</span>
                  </div>
                  <div class="staff-row-name" style="margin-top: 4px">
                    {{ item.row.student?.full_name ?? item.row.student?.email ?? 'Unknown student' }}
                  </div>
                  <div class="staff-row-sub">{{ item.row.reservation_name }} · {{ item.row.locations?.name ?? '—' }}</div>
                  <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 2px">
                    {{ formatDate(item.row.pickup_date) }} {{ formatTime(item.row.pickup_time) }} →
                    {{ formatDate(item.row.dropoff_date) }} {{ formatTime(item.row.dropoff_time) }}
                  </div>
                </div>
                <span class="badge" :class="toneForReservationStatus(item.row.status)">{{
                  reservationStatusLabel(item.row.status)
                }}</span>
              </div>

              <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(item.row) }}</div>
              <div v-if="reservationReasons(item.row).length" class="field-hint" style="margin-top: 8px">
                Needs approval: {{ reservationReasons(item.row).join(', ') }}
              </div>

              <div
                v-if="item.row.is_capstone"
                class="card-flat"
                style="margin-top: 10px; display: flex; flex-direction: column; gap: 8px"
              >
                <div class="field-hint">
                  Pre-pickup meeting: {{ formatDate(item.row.capstone_appointment_date) }} —
                  {{ item.row.appointment_completed ? 'Completed' : 'Not yet completed' }}
                </div>
                <button
                  v-if="!item.row.appointment_completed"
                  class="btn small"
                  style="align-self: flex-start"
                  :disabled="actionBusy[item.row.id]"
                  @click="markAppointmentComplete(item.row)"
                >
                  {{ actionBusy[item.row.id] ? 'Saving…' : 'Mark meeting complete' }}
                </button>
              </div>

              <p v-if="actionErrors[item.row.id]" class="error-note" style="margin-top: 8px">
                {{ actionErrors[item.row.id] }}
              </p>

              <div style="display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap">
                <button
                  class="btn small"
                  :class="item.row.is_capstone ? 'capstone' : 'primary'"
                  :disabled="actionBusy[item.row.id]"
                  @click="approveReservation(item.row)"
                >
                  {{ item.row.is_capstone ? 'Approve (Capstone)' : 'Approve' }}
                </button>
                <button class="btn ghost small" :disabled="actionBusy[item.row.id]" @click="startDenyReservation(item.row)">
                  Deny
                </button>
                <button class="btn ghost small" :disabled="actionBusy[item.row.id]" @click="openReservation(item.row)">
                  View details
                </button>
              </div>
              <div v-if="denyingId === item.row.id" class="field" style="margin-top: 10px">
                <label>Reason for denial</label>
                <textarea v-model="denyReason" rows="2" placeholder="Shown to the student" />
                <div style="display: flex; gap: 8px; margin-top: 6px">
                  <button
                    class="btn primary small"
                    :disabled="actionBusy[item.row.id] || !denyReason.trim()"
                    @click="confirmDenyReservation(item.row)"
                  >
                    Confirm deny
                  </button>
                  <button class="btn ghost small" @click="cancelDenyReservation">Never mind</button>
                </div>
              </div>
            </template>

            <!-- Tier-change approval item -->
            <template v-else>
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap">
                <div>
                  <div style="display: flex; gap: 8px; align-items: center">
                    <span class="badge muted">Tier change</span>
                  </div>
                  <div class="staff-row-name" style="margin-top: 4px">{{ item.row.users?.full_name ?? 'Unknown student' }}</div>
                  <div class="field-hint">{{ item.row.users?.email }}</div>
                  <div style="margin-top: 4px; font-size: 12.5px">
                    Took
                    <strong>{{
                      item.row.course_tier_mappings?.course_code ?? item.row.course_tier_mappings?.course_name ?? '—'
                    }}</strong>
                    — currently
                    <span class="badge violet" style="text-transform: capitalize">{{ item.row.tier }} tier</span>
                    → requests
                    <span class="badge accent" style="text-transform: capitalize">{{
                      item.row.course_tier_mappings?.tier ?? '?'
                    }} tier</span>
                  </div>
                  <p v-if="actionErrors[item.row.user_id]" class="error-note" style="margin-top: 6px">
                    {{ actionErrors[item.row.user_id] }}
                  </p>
                </div>
                <div style="display: flex; gap: 6px">
                  <button
                    class="btn ghost small"
                    :disabled="actionBusy[item.row.user_id]"
                    @click="dismissTierChange(item.row)"
                  >
                    Dismiss
                  </button>
                  <button
                    class="btn primary small"
                    :disabled="actionBusy[item.row.user_id] || !item.row.course_tier_mappings"
                    @click="confirmTierChange(item.row)"
                  >
                    {{
                      actionBusy[item.row.user_id] ? 'Saving…' : `Confirm → ${item.row.course_tier_mappings?.tier ?? '?'}`
                    }}
                  </button>
                </div>
              </div>
            </template>
          </div>
        </div>
      </div>

      <!-- ============ Upcoming pickups & drop-offs — a flat list for now ============ -->
      <div class="card">
        <div class="section-title" style="margin-bottom: 2px">Upcoming pickups & drop-offs</div>
        <p class="field-hint" style="margin-bottom: 12px">
          Every scheduled pickup and drop-off across pending, approved, and active reservations —
          grouped by day. A full calendar with different views is coming later; this is the list
          version for now.
        </p>
        <p v-if="loadingStaff">Loading…</p>
        <p v-else-if="staffError" class="error-note">{{ staffError }}</p>
        <p v-else-if="appointmentGroups.length === 0" class="empty-note">Nothing scheduled.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 16px">
          <div v-for="group in appointmentGroups" :key="group.date">
            <div style="font-weight: 700; font-size: 13px; margin-bottom: 6px">{{ group.label }}</div>
            <div style="display: flex; flex-direction: column; gap: 6px">
              <div
                v-for="(event, idx) in group.events"
                :key="`${group.date}-${event.type}-${event.reservation.id}-${idx}`"
                class="card-flat"
                style="display: flex; align-items: center; justify-content: space-between; gap: 10px; cursor: pointer; flex-wrap: wrap"
                @click="openReservation(event.reservation)"
              >
                <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap">
                  <span class="badge" :class="event.type === 'pickup' ? 'accent' : 'warn'">
                    {{ event.type === 'pickup' ? 'Pickup' : 'Return' }}
                  </span>
                  <span class="mono" style="font-size: 12.5px; color: var(--ink-2)">{{ formatTime(event.time) || '—' }}</span>
                  <div>
                    <div class="staff-row-name compact">
                      {{ event.reservation.student?.full_name ?? event.reservation.student?.email ?? 'Unknown student' }}
                    </div>
                    <div class="staff-row-sub" style="margin-top: 1px">
                      {{ event.reservation.reservation_name }} · {{ event.reservation.locations?.name ?? '—' }}
                    </div>
                  </div>
                  <span class="badge accent" v-if="event.reservation.is_capstone">Capstone</span>
                  <span class="badge violet" v-if="event.reservation.is_group_reservation">Group</span>
                </div>
                <span class="badge" :class="toneForReservationStatus(event.reservation.status)">{{
                  reservationStatusLabel(event.reservation.status)
                }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <p v-else-if="loading">Loading your dashboard…</p>
    <p v-else-if="error" class="error-note">Couldn't load dashboard data: {{ error }}</p>

    <template v-else>
      <div
        v-if="profile?.is_blocked || profile?.checkout_suspended"
        class="banner crit"
      >
        <span>
          <strong v-if="profile.is_blocked">Your account is blocked from checkouts.</strong>
          <strong v-else>Your checkout privileges are suspended.</strong>
          <span v-if="profile.suspended_reason"> — {{ profile.suspended_reason }}</span>
          Contact Cage staff to resolve this.
        </span>
      </div>

      <div v-if="outstandingTotal > 0" class="banner crit">
        <span>
          <strong>${{ outstandingTotal.toFixed(2) }} in outstanding fines.</strong>
          {{ fines.length }} fine{{ fines.length === 1 ? '' : 's' }} on your account.
        </span>
      </div>

      <div
        v-if="readyForPickupCount > 0"
        class="banner"
        style="background: var(--accent-soft); border: 1px solid var(--accent-soft-border); color: var(--accent-strong)"
      >
        <span>
          <strong>{{ readyForPickupCount }} reservation{{ readyForPickupCount === 1 ? '' : 's' }} ready for pickup.</strong>
          Your pickup window is open now.
        </span>
        <router-link :to="{ name: 'pickup' }" class="btn primary small">Go to Pickup</router-link>
      </div>

      <div class="stat-grid">
        <div class="stat-tile">
          <span class="stat-label">Currently checked out</span>
          <span class="stat-value num">{{ activeCount }}</span>
        </div>
        <div class="stat-tile">
          <span class="stat-label">Pending requests</span>
          <span class="stat-value num">{{ pendingCount }}</span>
        </div>
        <div class="stat-tile" :class="{ 'warn-tile': outstandingTotal > 0 }">
          <span class="stat-label">Outstanding fines</span>
          <span class="stat-value num">${{ outstandingTotal.toFixed(2) }}</span>
        </div>
      </div>

      <div class="two-col">
        <div class="card">
          <div class="section-title" style="margin-bottom: 12px">Recent reservations</div>
          <p v-if="reservations.length === 0" class="empty-note">
            No reservations yet — head to Browse Equipment to request gear.
          </p>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Reservation</th>
                  <th>Location</th>
                  <th>Pickup</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="r in reservations.slice(0, 5)" :key="r.id">
                  <td>{{ r.reservation_name }}</td>
                  <td>{{ r.locations?.name ?? '—' }}</td>
                  <td class="mono">{{ formatDate(r.pickup_date) }}</td>
                  <td>
                    <span class="badge" :class="toneForReservationStatus(r.status)">
                      {{ reservationStatusLabel(r.status) }}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="card">
          <div class="section-title" style="margin-bottom: 12px">Notifications</div>
          <p v-if="notifications.length === 0" class="empty-note">You're all caught up.</p>
          <div v-else style="display: flex; flex-direction: column; gap: 8px">
            <div
              v-for="n in notifications"
              :key="n.id"
              class="note-item"
              :style="!n.is_read ? 'border-color: var(--accent-soft-border); background: var(--accent-soft);' : ''"
            >
              <div style="display: flex; justify-content: space-between; gap: 8px; font-weight: 600">
                <span>{{ n.title }}</span>
                <span class="mono" style="color: var(--ink-3); font-weight: 500; font-size: 10.5px">{{
                  timeAgo(n.created_at)
                }}</span>
              </div>
              <p v-if="n.body" style="margin-top: 4px; color: var(--ink-2)">{{ n.body }}</p>
            </div>
          </div>
        </div>
      </div>

      <div v-if="fines.length > 0" class="card">
        <div class="section-title" style="margin-bottom: 12px">Fine detail</div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Type</th>
                <th>Status</th>
                <th>Amount</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="f in fines" :key="f.id">
                <td style="text-transform: capitalize">{{ f.fine_type.replace('_', ' ') }}</td>
                <td>
                  <span class="badge" :class="toneForFineStatus(f.status)">{{ f.status }}</span>
                </td>
                <td class="mono">${{ Number(f.current_amount).toFixed(2) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
textarea {
  width: 100%;
  resize: vertical;
}
/* Same capstone-approve styling as ReservationQueueView.vue, so the
   dashboard's compact approval card matches the full Queue exactly. */
.btn.capstone {
  background: var(--violet);
  border-color: var(--violet);
  color: var(--accent-ink);
}
.btn.capstone:hover {
  opacity: 0.9;
}
</style>
