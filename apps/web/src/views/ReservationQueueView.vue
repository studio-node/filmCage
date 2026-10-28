<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { toneForReservationStatus, reservationStatusLabel, type ReservationStatus } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'

// 10/19 rebuild: the Pending Approval tab's own mechanics (inline
// approve/deny) are unchanged — the only thing added to it is hiding a
// plain staff member's own personal pending reservation from their OWN
// view of this tab (still fully visible/actionable to everyone else;
// the real enforcement that they can't approve/deny it regardless is
// the database trigger, not this filter). All Reservations is now
// split into Active/Upcoming/Past, every row opens the shared detail
// page (ReservationDetailView.vue), and an Edit button jumps straight
// into that page's edit mode.
//
// 10/21 client policy change: capstone reservations now go through the
// exact same approval math as a regular reservation (item-count/Friday/
// inventory/loan-window checks, the staff-on-someone-else bypass, the
// class_instructor exemption) — the only difference is a longer lead
// time (CAPSTONE_LEAD_TIME_DAYS, 7 days instead of 3). The old
// awaiting_appointment/awaiting_schedule two-step (meeting first, real
// date only after) is gone; the pre-pickup meeting is now a purely
// informational flag (capstone_appointment_date/appointment_completed)
// that staff can mark complete whenever, independent of status, and
// doesn't gate approval at all. The Approve button is styled
// differently for capstone rows so staff can see at a glance which
// approval process they're in.

const APPROVAL_ITEM_THRESHOLD = 20
const LEAD_TIME_DAYS = 3
const CAPSTONE_LEAD_TIME_DAYS = 7
const LOAN_WINDOW_DAYS = 3

interface ItemLine {
  quantity: number
  item_models: { name: string } | null
}
interface CrewRow {
  crew_role: string
  users: { full_name: string } | null
}
interface ReservationRow {
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
  denial_reason: string | null
  admin_notes: string | null
  created_at: string
  locations: { name: string } | null
  reservation_items: ItemLine[]
  reservation_crew: CrewRow[]
  student: { id: string; full_name: string | null; email: string | null; role: string } | null
}

const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const error = ref('')
const actionError = ref<Record<string, string>>({})
const busy = ref<Record<string, boolean>>({})
const reservations = ref<ReservationRow[]>([])
const activeTab = ref<'pending' | 'all'>('pending')
const denyingId = ref<string | null>(null)
const denyReason = ref('')
const confirmingCancelId = ref<string | null>(null)
const confirmingDeleteId = ref<string | null>(null)
const blockedCounts = ref<Record<string, { fines: number; reviews: number; occurrences: number }>>({})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const { data, error: err } = await supabase
      .from('reservations')
      .select(
        `id, reservation_name, status, is_capstone, is_group_reservation,
         capstone_appointment_date, appointment_completed,
         pickup_date, pickup_time, dropoff_date, dropoff_time,
         denial_reason, admin_notes, created_at,
         locations(name),
         reservation_items(quantity, item_models(name)),
         reservation_crew(crew_role, users(full_name)),
         student:users!reservations_student_id_fkey(id, full_name, email, role)`
      )
      .order('created_at', { ascending: false })
    if (err) throw err
    reservations.value = (data ?? []) as unknown as ReservationRow[]
  } catch (e) {
    error.value = errorMessage(e, 'Could not load reservations.')
  } finally {
    loading.value = false
  }
}
load()

// A plain `staff` actor can never approve/deny their own personal
// reservation (supervisor/admin can), so it's kept out of their OWN
// Pending Approval list — still fully visible to every other staff
// member, supervisor, or admin. This is UI cleanliness only; the
// database trigger is what actually blocks the approve/deny attempt
// regardless of whether this filter is bypassed.
const pendingRows = computed(() =>
  reservations.value.filter(
    (r) => r.status === 'pending' && !(auth.role === 'staff' && r.student?.id === auth.user?.id)
  )
)

// Bucketing for the All Reservations tab — confirmed 10/19: Active is
// literally status = 'active' (physically checked out right now, only
// ever flipped by the future Pickup/Return process — empty today is
// expected, not a bug); Past is completed/cancelled/denied OR any
// reservation whose drop-off date has already passed, whatever its
// status; Upcoming is everything left over.
const today = new Date().toISOString().slice(0, 10)
function bucket(r: ReservationRow): 'active' | 'upcoming' | 'past' {
  if (r.status === 'active') return 'active'
  const relevantDate = r.dropoff_date ?? r.pickup_date
  const datePassed = !!relevantDate && relevantDate < today
  if (r.status === 'completed' || r.status === 'cancelled' || r.status === 'denied' || datePassed) return 'past'
  return 'upcoming'
}
const activeRows = computed(() => reservations.value.filter((r) => bucket(r) === 'active'))
const upcomingRows = computed(() => reservations.value.filter((r) => bucket(r) === 'upcoming'))
const pastRows = computed(() => reservations.value.filter((r) => bucket(r) === 'past'))
const allSections = computed(() => [
  { key: 'active', label: 'Active', rows: activeRows.value },
  { key: 'upcoming', label: 'Upcoming', rows: upcomingRows.value },
  { key: 'past', label: 'Past', rows: pastRows.value },
])

function openDetail(r: ReservationRow) {
  router.push({ name: 'reservation-detail', params: { id: r.id } })
}
function openEdit(r: ReservationRow) {
  router.push({ name: 'reservation-detail', params: { id: r.id }, query: { edit: '1' } })
}

function itemSummary(r: ReservationRow) {
  return (
    r.reservation_items
      .map((l) => `${l.item_models?.name ?? 'Unknown item'}${l.quantity > 1 ? ` ×${l.quantity}` : ''}`)
      .join(', ') || 'No items'
  )
}
function itemCount(r: ReservationRow) {
  return r.reservation_items.reduce((sum, l) => sum + l.quantity, 0)
}
function formatDate(d: string | null) {
  if (!d) return '—'
  return new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}
function formatTime(t: string | null) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}
function scheduleLine(r: ReservationRow) {
  if (!r.pickup_date) return 'Not scheduled yet'
  return `${formatDate(r.pickup_date)} ${formatTime(r.pickup_time)} → ${formatDate(r.dropoff_date)} ${formatTime(r.dropoff_time)}`
}
// Capstone-only informational line — the pre-pickup meeting no longer
// gates status, so this is shown alongside the normal schedule line
// rather than instead of it.
function appointmentLine(r: ReservationRow) {
  return `Pre-pickup meeting: ${formatDate(r.capstone_appointment_date)} — ${r.appointment_completed ? 'Completed' : 'Not yet completed'}`
}
function crewLine(r: ReservationRow) {
  if (!r.is_group_reservation || r.reservation_crew.length === 0) return null
  return r.reservation_crew.map((c) => `${c.users?.full_name ?? 'Unknown'} (${c.crew_role})`).join(', ')
}

// Mirrors reservations_approval_guard()'s own rules — purely informational,
// so staff can see at a glance why something landed in Pending without
// reopening the trigger SQL. Doesn't attempt to re-derive the staff/
// instructor exemptions; a row that's here either came from a Friday
// date (no exemption, applies to everyone) or from a student holder.
function reasons(r: ReservationRow): string[] {
  const out: string[] = []
  if (itemCount(r) > APPROVAL_ITEM_THRESHOLD) out.push(`Over ${APPROVAL_ITEM_THRESHOLD} items`)
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

function setBusy(id: string, val: boolean) {
  busy.value = { ...busy.value, [id]: val }
}
function setActionError(id: string, msg: string) {
  actionError.value = { ...actionError.value, [id]: msg }
}

async function approve(r: ReservationRow) {
  setBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error: err } = await supabase
      .from('reservations')
      .update({ status: 'approved', approved_by: auth.user!.id, approved_at: new Date().toISOString() })
      .eq('id', r.id)
    if (err) throw err
    await load()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not approve this reservation.'))
  } finally {
    setBusy(r.id, false)
  }
}

function startDeny(r: ReservationRow) {
  denyingId.value = r.id
  denyReason.value = ''
}
function cancelDenyPrompt() {
  denyingId.value = null
  denyReason.value = ''
}
async function confirmDeny(r: ReservationRow) {
  if (!denyReason.value.trim()) return
  setBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error: err } = await supabase
      .from('reservations')
      .update({ status: 'denied', denial_reason: denyReason.value.trim() })
      .eq('id', r.id)
    if (err) throw err
    denyingId.value = null
    denyReason.value = ''
    await load()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not deny this reservation.'))
  } finally {
    setBusy(r.id, false)
  }
}

async function cancel(r: ReservationRow) {
  setBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error: err } = await supabase.from('reservations').update({ status: 'cancelled' }).eq('id', r.id)
    if (err) throw err
    confirmingCancelId.value = null
    await load()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not cancel this reservation.'))
  } finally {
    setBusy(r.id, false)
  }
}

// Pre-pickup meeting is now purely informational — marking it complete
// is staff-only (reservations_approval_guard pins appointment_completed
// back to its old value for any non-staff actor) but no longer gates
// approval/status in any way, and can be done at any status.
async function markAppointmentComplete(r: ReservationRow) {
  setBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error: err } = await supabase.from('reservations').update({ appointment_completed: true }).eq('id', r.id)
    if (err) throw err
    await load()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not mark the meeting complete.'))
  } finally {
    setBusy(r.id, false)
  }
}

// Checked up front so staff see *why* delete isn't available, rather
// than firing the delete and translating a raw foreign-key error.
// fines/condition_reviews/recurring_reservation_occurrences don't
// cascade on purpose (see migration 20261006090000) — real history
// that shouldn't vanish silently.
async function checkDeleteBlockers(r: ReservationRow) {
  const [fines, reviews, occurrences] = await Promise.all([
    supabase.from('fines').select('id', { count: 'exact', head: true }).eq('reservation_id', r.id),
    supabase.from('condition_reviews').select('id', { count: 'exact', head: true }).eq('reservation_id', r.id),
    supabase.from('recurring_reservation_occurrences').select('id', { count: 'exact', head: true }).eq('reservation_id', r.id),
  ])
  blockedCounts.value = {
    ...blockedCounts.value,
    [r.id]: {
      fines: fines.count ?? 0,
      reviews: reviews.count ?? 0,
      occurrences: occurrences.count ?? 0,
    },
  }
}
function deleteBlockedReason(r: ReservationRow): string | null {
  const counts = blockedCounts.value[r.id]
  if (!counts) return null
  const parts: string[] = []
  if (counts.fines > 0) parts.push(`${counts.fines} fine${counts.fines > 1 ? 's' : ''}`)
  if (counts.reviews > 0) parts.push(`${counts.reviews} condition review${counts.reviews > 1 ? 's' : ''}`)
  if (counts.occurrences > 0) parts.push('a recurring-reservation link')
  if (parts.length === 0) return null
  return `Has ${parts.join(', ')} attached — cancel instead to keep that history.`
}
async function startDelete(r: ReservationRow) {
  confirmingDeleteId.value = r.id
  await checkDeleteBlockers(r)
}
function cancelDeletePrompt() {
  confirmingDeleteId.value = null
}
async function confirmDelete(r: ReservationRow) {
  setBusy(r.id, true)
  setActionError(r.id, '')
  try {
    const { error: err } = await supabase.from('reservations').delete().eq('id', r.id)
    if (err) throw err
    confirmingDeleteId.value = null
    await load()
  } catch (e) {
    setActionError(r.id, errorMessage(e, 'Could not delete this reservation — it may have history attached that blocks deletion.'))
  } finally {
    setBusy(r.id, false)
  }
}

// Status locking for the All Reservations tab, confirmed 10/19: active/
// completed/cancelled are fully locked — no edit, cancel, or delete,
// view-only (the detail page's own click-through still works, it just
// won't offer any action button once there either).
const LOCKED_STATUSES = new Set(['active', 'completed', 'cancelled'])
function isLocked(r: ReservationRow) {
  return LOCKED_STATUSES.has(r.status)
}
function canEditRow(r: ReservationRow) {
  return !isLocked(r)
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Staff</span>
        <h1>Reservation Queue</h1>
        <p class="view-desc">Review pending requests, or manage any reservation.</p>
      </div>
    </div>

    <div class="tabs">
      <button class="tab" :class="{ active: activeTab === 'pending' }" @click="activeTab = 'pending'">
        Pending Approval <span v-if="pendingRows.length" class="badge-mini">{{ pendingRows.length }}</span>
      </button>
      <button class="tab" :class="{ active: activeTab === 'all' }" @click="activeTab = 'all'">All Reservations</button>
    </div>

    <p v-if="loading">Loading reservations…</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>

    <!-- ============ Pending Approval — unchanged from before ============ -->
    <template v-if="!loading && !error && activeTab === 'pending'">
      <p v-if="pendingRows.length === 0" class="empty-note">Nothing waiting on approval.</p>
      <div v-else style="display: flex; flex-direction: column; gap: 12px">
        <div v-for="r in pendingRows" :key="r.id" class="card">
          <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
            <div>
              <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
                <span class="badge accent" v-if="r.is_capstone">Capstone</span>
                <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
              </div>
              <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
              </div>
              <div style="font-size: 12.5px; color: var(--ink-2); margin-top: 2px">
                {{ r.student?.full_name ?? r.student?.email ?? 'Unknown student' }} · {{ scheduleLine(r) }}
              </div>
            </div>
            <span class="badge" :class="toneForReservationStatus(r.status)">{{ reservationStatusLabel(r.status) }}</span>
          </div>

          <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(r) }}</div>
          <div v-if="crewLine(r)" class="field-hint" style="margin-top: 4px">Crew: {{ crewLine(r) }}</div>

          <div v-if="reasons(r).length" class="field-hint" style="margin-top: 8px">Needs approval: {{ reasons(r).join(', ') }}</div>

          <div v-if="r.is_capstone" class="card-flat" style="margin-top: 10px; display: flex; flex-direction: column; gap: 8px">
            <div class="field-hint">{{ appointmentLine(r) }}</div>
            <button
              v-if="!r.appointment_completed"
              class="btn small"
              style="align-self: flex-start"
              :disabled="busy[r.id]"
              @click="markAppointmentComplete(r)"
            >
              {{ busy[r.id] ? 'Saving…' : 'Mark meeting complete' }}
            </button>
          </div>

          <p v-if="actionError[r.id]" class="error-note" style="margin-top: 8px">{{ actionError[r.id] }}</p>

          <div style="display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap">
            <button class="btn small" :class="r.is_capstone ? 'capstone' : 'primary'" :disabled="busy[r.id]" @click="approve(r)">
              {{ r.is_capstone ? 'Approve (Capstone)' : 'Approve' }}
            </button>
            <button class="btn ghost small" :disabled="busy[r.id]" @click="startDeny(r)">Deny</button>
            <button class="btn ghost small" :disabled="busy[r.id]" @click="openDetail(r)">View details</button>
          </div>
          <div v-if="denyingId === r.id" class="field" style="margin-top: 10px">
            <label>Reason for denial</label>
            <textarea v-model="denyReason" rows="2" placeholder="Shown to the student" />
            <div style="display: flex; gap: 8px; margin-top: 6px">
              <button class="btn primary small" :disabled="busy[r.id] || !denyReason.trim()" @click="confirmDeny(r)">
                Confirm deny
              </button>
              <button class="btn ghost small" @click="cancelDenyPrompt">Never mind</button>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- ============ All Reservations — Active / Upcoming / Past ============ -->
    <template v-if="!loading && !error && activeTab === 'all'">
      <div v-for="section in allSections" :key="section.key" style="margin-top: 18px">
        <h2 style="font-size: 14px; margin-bottom: 8px">
          {{ section.label }} <span class="badge-mini" v-if="section.rows.length">{{ section.rows.length }}</span>
        </h2>
        <p v-if="section.rows.length === 0" class="empty-note">
          {{ section.key === 'active' ? 'Nothing physically checked out right now.' : 'Nothing here.' }}
        </p>
        <div v-else style="display: flex; flex-direction: column; gap: 12px">
          <div v-for="r in section.rows" :key="r.id" class="card" style="cursor: pointer" @click="openDetail(r)">
            <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
              <div>
                <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
                  <span class="badge accent" v-if="r.is_capstone">Capstone</span>
                  <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
                </div>
                <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                  {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
                </div>
                <div style="font-size: 12.5px; color: var(--ink-2); margin-top: 2px">
                  {{ r.student?.full_name ?? r.student?.email ?? 'Unknown student' }} · {{ scheduleLine(r) }}
                </div>
              </div>
              <span class="badge" :class="toneForReservationStatus(r.status)">{{ reservationStatusLabel(r.status) }}</span>
            </div>

            <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(r) }}</div>
            <div v-if="crewLine(r)" class="field-hint" style="margin-top: 4px">Crew: {{ crewLine(r) }}</div>
            <div v-if="r.is_capstone" class="field-hint" style="margin-top: 4px">{{ appointmentLine(r) }}</div>
            <div v-if="r.status === 'denied' && r.denial_reason" class="lock-note" style="margin-top: 8px">
              Denied: {{ r.denial_reason }}
            </div>

            <div style="display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap" @click.stop>
              <button v-if="canEditRow(r)" class="btn small" :disabled="busy[r.id]" @click="openEdit(r)">Edit</button>
              <button
                v-if="!isLocked(r) && confirmingCancelId !== r.id"
                class="btn ghost small"
                :disabled="busy[r.id]"
                @click="confirmingCancelId = r.id"
              >
                Cancel reservation
              </button>
              <button v-if="!isLocked(r) && confirmingDeleteId !== r.id" class="btn ghost small" :disabled="busy[r.id]" @click="startDelete(r)">
                Delete…
              </button>
            </div>

            <p v-if="actionError[r.id]" class="error-note" style="margin-top: 8px">{{ actionError[r.id] }}</p>

            <div v-if="confirmingCancelId === r.id" class="field-hint" style="margin-top: 10px" @click.stop>
              Cancel this reservation? The student will see it as cancelled.
              <div style="display: flex; gap: 8px; margin-top: 6px">
                <button class="btn primary small" :disabled="busy[r.id]" @click="cancel(r)">Yes, cancel it</button>
                <button class="btn ghost small" @click="confirmingCancelId = null">Never mind</button>
              </div>
            </div>
            <div v-if="confirmingDeleteId === r.id" class="field-hint" style="margin-top: 10px" @click.stop>
              <template v-if="deleteBlockedReason(r)">
                <span class="lock-note">{{ deleteBlockedReason(r) }}</span>
                <div style="margin-top: 6px"><button class="btn ghost small" @click="cancelDeletePrompt">Close</button></div>
              </template>
              <template v-else>
                Permanently delete this reservation? This can't be undone.
                <div style="display: flex; gap: 8px; margin-top: 6px">
                  <button class="btn primary small" :disabled="busy[r.id]" @click="confirmDelete(r)">Yes, delete it</button>
                  <button class="btn ghost small" @click="cancelDeletePrompt">Never mind</button>
                </div>
              </template>
            </div>
          </div>
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
/* Capstone's own approval path gets a visually distinct Approve button
   (violet, matching the existing "Capstone"/"Group production" badge
   hues) so staff can tell at a glance which approval process a row is
   going through, per the client's explicit request. */
.btn.capstone {
  background: var(--violet);
  border-color: var(--violet);
  color: var(--accent-ink);
}
.btn.capstone:hover {
  opacity: 0.9;
}
</style>
