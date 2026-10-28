<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { toneForReservationStatus, reservationStatusLabel, type ReservationStatus } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'

// 10/19 rebuild: this view applies to everyone — student, staff,
// supervisor, admin — exactly as if they were a student, "as the my
// reservation screen" for their own stuff. Default tab now shows
// Active + Upcoming together in two sections (same bucket rules as
// ReservationQueueView's All Reservations tab); a second tab holds
// Past. Every row is clickable through to the shared detail page
// (ReservationDetailView.vue), with an Edit button that jumps
// straight into its edit mode. Crew-member rows (someone else's group
// reservation you're just named on) aren't part of this feature, just
// folded into the new section layout.
//
// 10/21 client policy change: capstone reservations are now created
// with a real tentative pickup/drop-off date up front (same as any
// other reservation, just a longer lead time) and go through the exact
// same approval path, so they no longer get a dedicated self-scheduling
// mini-form here or a special exclusion from the Edit button. The
// pre-pickup meeting (capstone_appointment_date/appointment_completed)
// is now purely informational for the student too — shown on the card,
// marked complete only by staff.

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
  student_id: string
  reservation_name: string
  status: ReservationStatus
  is_capstone: boolean
  is_group_reservation: boolean
  allow_individual_pickup_times: boolean
  approved_by: string | null
  capstone_appointment_date: string | null
  appointment_completed: boolean
  pickup_date: string | null
  pickup_time: string | null
  dropoff_date: string | null
  dropoff_time: string | null
  denial_reason: string | null
  created_at: string
  locations: { name: string } | null
  reservation_items: ItemLine[]
  reservation_crew: CrewRow[]
  // Populated only for a reservation the viewer is named crew on but
  // didn't create themselves (reservations_read_crew_member +
  // reservation_has_crew_member, migration 18) -- lets them set their
  // own pickup/drop-off time here instead of just seeing the
  // director's shared one above.
  myCrewRowId?: string
  myCrewRole?: string
}
interface CrewSelfRow {
  id: string
  crew_role: string
  pickup_time_override: string | null
  dropoff_time_override: string | null
  reservations: ReservationRow
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const error = ref('')
const reservations = ref<ReservationRow[]>([])
const activeTab = ref<'current' | 'past'>('current')

// Shared across both queries below so a reservation looks the same
// whether it's listed because the viewer created it, or because
// they're named crew on someone else's.
const RESERVATION_FIELDS = `id, student_id, reservation_name, status, is_capstone, is_group_reservation,
         allow_individual_pickup_times, approved_by, capstone_appointment_date, appointment_completed,
         pickup_date, pickup_time, dropoff_date, dropoff_time,
         denial_reason, created_at,
         locations(name),
         reservation_items(quantity, item_models(name)),
         reservation_crew(crew_role, users(full_name))`

// Per-row draft state for a crew member's own pickup/drop-off time,
// keyed by reservation id. Populated from whatever's already saved
// each time load() runs, kept separate from ReservationRow itself so
// typing in the inputs doesn't fight with a later refetch.
const myTimeDrafts = reactive<Record<string, { pickup: string; dropoff: string }>>({})

async function load() {
  if (!auth.user) return
  loading.value = true
  error.value = ''
  try {
    const [ownedRes, crewRes] = await Promise.all([
      supabase
        .from('reservations')
        .select(RESERVATION_FIELDS)
        .eq('student_id', auth.user.id)
        .order('created_at', { ascending: false }),
      supabase
        .from('reservation_crew')
        .select(`id, crew_role, pickup_time_override, dropoff_time_override, reservations(${RESERVATION_FIELDS})`)
        .eq('user_id', auth.user.id),
    ])
    if (ownedRes.error) throw ownedRes.error
    if (crewRes.error) throw crewRes.error

    const owned = (ownedRes.data ?? []) as unknown as ReservationRow[]
    const seenIds = new Set(owned.map((r) => r.id))
    const asCrew: ReservationRow[] = []
    for (const row of (crewRes.data ?? []) as unknown as CrewSelfRow[]) {
      const r = row.reservations
      // A director's own "Director" crew row shows up in this query
      // too (they're crew on their own reservation) -- already
      // covered by `owned` above, so skip it here rather than
      // listing the same reservation twice.
      if (!r || seenIds.has(r.id)) continue
      seenIds.add(r.id)
      asCrew.push({ ...r, myCrewRowId: row.id, myCrewRole: row.crew_role })
      myTimeDrafts[r.id] = { pickup: row.pickup_time_override ?? '', dropoff: row.dropoff_time_override ?? '' }
    }

    reservations.value = [...owned, ...asCrew].sort((a, b) => (a.created_at < b.created_at ? 1 : -1))
  } catch (e) {
    error.value = errorMessage(e, 'Could not load your reservations.')
  } finally {
    loading.value = false
  }
}
load()

// Same bucket rules as ReservationQueueView's All Reservations tab:
// Active is literally status = 'active'; Past is completed/cancelled/
// denied OR a drop-off date that's already gone by, whatever the
// status; everything else is Upcoming.
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
const currentSections = computed(() => [
  { key: 'active', label: 'Active', rows: activeRows.value },
  { key: 'upcoming', label: 'Upcoming', rows: upcomingRows.value },
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
  if (!r.pickup_date) return 'Pickup/return not scheduled yet'
  return `${formatDate(r.pickup_date)} ${formatTime(r.pickup_time)} → ${formatDate(r.dropoff_date)} ${formatTime(r.dropoff_time)}`
}
// Capstone-only informational line — the pre-pickup meeting no longer
// gates status, so this is shown alongside the normal schedule line
// rather than instead of it.
function appointmentLine(r: ReservationRow) {
  return `Pre-pickup meeting: ${formatDate(r.capstone_appointment_date)} — ${r.appointment_completed ? 'Completed' : 'Not yet completed'}`
}
function directorAndCrew(r: ReservationRow) {
  if (!r.is_group_reservation || r.reservation_crew.length === 0) return null
  return r.reservation_crew.map((c) => `${c.users?.full_name ?? 'Unknown'} (${c.crew_role})`).join(', ')
}

// A reservation's own holder can cancel it right up until it's
// actually happened or been closed out — even once approved, per
// reservations_self_cancel + reservations_student_cancel_guard — but
// confirmed 10/19 that this is now scoped to Upcoming specifically:
// not Active, not Past. Never offered to a crew member viewing
// someone else's group reservation.
function cancellable(r: ReservationRow) {
  return !r.myCrewRowId && bucket(r) === 'upcoming'
}

// Self-edit rule, identical to ReservationDetailView.vue's own
// selfEditable(): full checks always apply to your own edits
// regardless of role, and once a reservation that needed real review
// has been manually approved (approved_by set), editing disappears
// for good — "once approval is given, no one will have the ability to
// edit... through the my reservation screen." A denied one stays
// self-editable (it re-enters approval). Capstone is treated
// identically to a regular reservation here now — no special case.
function editable(r: ReservationRow) {
  if (r.myCrewRowId) return false
  if (r.status === 'active' || r.status === 'completed' || r.status === 'cancelled') return false
  if (r.status === 'approved') return r.approved_by == null
  if (r.status === 'waitlist_offered') return false
  return true
}

const confirmingCancelId = ref<string | null>(null)
const busy = ref<Record<string, boolean>>({})
const actionError = ref<Record<string, string>>({})

async function saveMyPickupTime(r: ReservationRow) {
  if (!r.myCrewRowId) return
  busy.value = { ...busy.value, [r.id]: true }
  actionError.value = { ...actionError.value, [r.id]: '' }
  try {
    const draft = myTimeDrafts[r.id] ?? { pickup: '', dropoff: '' }
    const { error: err } = await supabase
      .from('reservation_crew')
      .update({
        pickup_time_override: draft.pickup || null,
        dropoff_time_override: draft.dropoff || null,
      })
      .eq('id', r.myCrewRowId)
    if (err) throw err
    await load()
  } catch (e) {
    actionError.value = { ...actionError.value, [r.id]: errorMessage(e, 'Could not save your pickup/drop-off time.') }
  } finally {
    busy.value = { ...busy.value, [r.id]: false }
  }
}

async function cancelReservation(r: ReservationRow) {
  busy.value = { ...busy.value, [r.id]: true }
  actionError.value = { ...actionError.value, [r.id]: '' }
  try {
    const { error: err } = await supabase.from('reservations').update({ status: 'cancelled' }).eq('id', r.id)
    if (err) throw err
    confirmingCancelId.value = null
    await load()
  } catch (e) {
    actionError.value = { ...actionError.value, [r.id]: errorMessage(e, 'Could not cancel this reservation.') }
  } finally {
    busy.value = { ...busy.value, [r.id]: false }
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Requests</span>
        <h1>My Reservations</h1>
        <p class="view-desc">Active and upcoming bookings, or everything in the past.</p>
      </div>
      <router-link :to="{ name: 'new-reservation' }" class="btn primary">+ New reservation</router-link>
    </div>

    <div v-if="route.query.submitted" class="banner" style="background: var(--good-soft); border: 1px solid var(--good-border); color: var(--good)">
      <span>Reservation submitted — see it under Active/Upcoming below.</span>
    </div>

    <div class="tabs">
      <button class="tab" :class="{ active: activeTab === 'current' }" @click="activeTab = 'current'">Active &amp; Upcoming</button>
      <button class="tab" :class="{ active: activeTab === 'past' }" @click="activeTab = 'past'">Past</button>
    </div>

    <p v-if="loading">Loading your reservations…</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>

    <template v-if="!loading && !error">
      <!-- row partial reused by both tabs below via the v-for; kept
           as a single block of markup rather than extracted into a
           component, matching this file's existing style -->
      <template v-if="activeTab === 'current'">
        <div v-for="section in currentSections" :key="section.key" style="margin-top: 14px">
          <h2 style="font-size: 14px; margin-bottom: 8px">
            {{ section.label }} <span class="badge-mini" v-if="section.rows.length">{{ section.rows.length }}</span>
          </h2>
          <p v-if="section.rows.length === 0" class="empty-note">Nothing here.</p>
          <div v-else style="display: flex; flex-direction: column; gap: 12px">
            <div v-for="r in section.rows" :key="r.id" class="card" style="cursor: pointer" @click="openDetail(r)">
              <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
                <div>
                  <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
                    <span class="badge accent" v-if="r.is_capstone">Capstone</span>
                    <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
                    <span class="badge" v-if="r.myCrewRowId">You're crew ({{ r.myCrewRole }})</span>
                  </div>
                  <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                    {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
                  </div>
                  <div style="font-size: 12.5px; color: var(--ink-2); margin-top: 2px">{{ scheduleLine(r) }}</div>
                </div>
                <span class="badge" :class="toneForReservationStatus(r.status)">{{ reservationStatusLabel(r.status) }}</span>
              </div>
              <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(r) }}</div>
              <div v-if="directorAndCrew(r)" class="field-hint" style="margin-top: 4px">Crew: {{ directorAndCrew(r) }}</div>
              <div v-if="r.is_capstone" class="field-hint" style="margin-top: 4px">{{ appointmentLine(r) }}</div>

              <div v-if="r.myCrewRowId && !r.allow_individual_pickup_times" class="field-hint" style="margin-top: 8px">
                The organizer is responsible for pickup and drop-off on this one.
              </div>
              <div v-else-if="r.myCrewRowId" class="card-flat" style="margin-top: 8px; display: flex; flex-direction: column; gap: 8px" @click.stop>
                <div class="field-hint">
                  Set your own pickup/drop-off time, or leave either blank to fall back to the shared time above.
                </div>
                <div class="field-row">
                  <div class="field">
                    <label>Your pickup time</label>
                    <input v-model="myTimeDrafts[r.id].pickup" type="time" />
                  </div>
                  <div class="field">
                    <label>Your drop-off time</label>
                    <input v-model="myTimeDrafts[r.id].dropoff" type="time" />
                  </div>
                </div>
                <button class="btn small" style="align-self: flex-start" :disabled="busy[r.id]" @click="saveMyPickupTime(r)">
                  {{ busy[r.id] ? 'Saving…' : 'Save my time' }}
                </button>
              </div>
              <div v-if="r.status === 'denied' && r.denial_reason" class="lock-note" style="margin-top: 8px">
                Denied: {{ r.denial_reason }}
              </div>
              <div v-else-if="r.status === 'waitlisted'" class="field-hint" style="margin-top: 8px">
                You'll be notified automatically if a unit frees up.
              </div>
              <div v-else-if="r.status === 'waitlist_offered'" class="info-note" style="margin-top: 8px">
                A unit is available — check your notifications to confirm or decline before the offer
                expires.
              </div>
              <div v-else-if="r.status === 'approved' && r.approved_by" class="field-hint" style="margin-top: 8px">
                Manually approved — a staff member, supervisor, or admin can make further changes if needed.
              </div>

              <p v-if="actionError[r.id]" class="error-note" style="margin-top: 8px">{{ actionError[r.id] }}</p>

              <div style="display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap" @click.stop>
                <button v-if="editable(r)" class="btn small" :disabled="busy[r.id]" @click="openEdit(r)">Edit</button>
                <button v-if="cancellable(r) && confirmingCancelId !== r.id" class="btn ghost small" :disabled="busy[r.id]" @click="confirmingCancelId = r.id">
                  Cancel reservation
                </button>
              </div>
              <div v-if="confirmingCancelId === r.id" class="field-hint" style="margin-top: 10px" @click.stop>
                Cancel this reservation? This can't be undone.
                <div style="display: flex; gap: 8px; margin-top: 6px">
                  <button class="btn primary small" :disabled="busy[r.id]" @click="cancelReservation(r)">Yes, cancel it</button>
                  <button class="btn ghost small" @click="confirmingCancelId = null">Never mind</button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </template>

      <template v-else>
        <p v-if="pastRows.length === 0" class="empty-note">Nothing here yet.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 12px; margin-top: 14px">
          <div v-for="r in pastRows" :key="r.id" class="card" style="cursor: pointer" @click="openDetail(r)">
            <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
              <div>
                <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
                  <span class="badge accent" v-if="r.is_capstone">Capstone</span>
                  <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
                  <span class="badge" v-if="r.myCrewRowId">You're crew ({{ r.myCrewRole }})</span>
                </div>
                <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                  {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
                </div>
                <div style="font-size: 12.5px; color: var(--ink-2); margin-top: 2px">{{ scheduleLine(r) }}</div>
              </div>
              <span class="badge" :class="toneForReservationStatus(r.status)">{{ reservationStatusLabel(r.status) }}</span>
            </div>
            <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(r) }}</div>
            <div v-if="directorAndCrew(r)" class="field-hint" style="margin-top: 4px">Crew: {{ directorAndCrew(r) }}</div>
            <div v-if="r.is_capstone" class="field-hint" style="margin-top: 4px">{{ appointmentLine(r) }}</div>
            <div v-if="r.status === 'denied' && r.denial_reason" class="lock-note" style="margin-top: 8px">
              Denied: {{ r.denial_reason }}
            </div>
          </div>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
