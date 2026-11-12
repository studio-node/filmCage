<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { conditionLabel, conditionRank, type UnitCondition } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'
import IconBase from '../components/icons/IconBase.vue'

// Return / check-in screen (migration 31's frontend half). Same
// two-sided shape as Pickup, one shared page computed from {who's
// looking, the row itself}:
//
//   - The person who checked equipment out: hands it back. A regular
//     reservation returns everything they hold at once; a crew member
//     picks which of their OWN units they're returning this visit.
//     Initials required. Returning before the drop-off date is just
//     returning early -- same flow.
//   - Staff+: every return someone has submitted but staff hasn't
//     checked in yet. Staff records a condition for every unit (Good /
//     Caution / Damaged / Missing, note required for anything but
//     Good -- plain staff can only keep or lower a unit's condition,
//     same rule as Edit Items), can add the late-return fine right
//     there if it's overdue, and confirms with their initials. The
//     reservation completes once nothing checked out is left on it --
//     that's the ONLY way a reservation reaches Completed now.
const STAFF_PLUS = new Set(['staff', 'supervisor', 'admin'])
const CONDITIONS: UnitCondition[] = ['good', 'caution', 'damaged', 'missing']

interface UnitRow {
  unit_id: string
  item_model_id: string
  checked_out_by: string
  checkout_session_id: string | null
  return_session_id: string | null
  item_units: { unit_code: string; condition: UnitCondition; item_models: { name: string } | null } | null
  claimer: { full_name: string | null } | null
}
interface SessionRow {
  id: string
  phase: 'pickup' | 'return'
  person_user_id: string | null
  person_signature: string | null
  person_confirmed_at: string | null
  staff_user_id: string | null
  staff_confirmed_at: string | null
  person: { full_name: string | null } | null
  staff: { full_name: string | null } | null
}
interface ReturnedRow {
  unit_id: string
  condition_at_return: UnitCondition
  note: string | null
  created_at: string
  return_session_id: string | null
  item_units: { unit_code: string; item_models: { name: string } | null } | null
}
interface ReservationRow {
  id: string
  reservation_name: string
  student_id: string
  status: string
  is_group_reservation: boolean
  pickup_date: string | null
  dropoff_date: string | null
  dropoff_time: string | null
  locations: { name: string } | null
  student: { full_name: string | null } | null
  reservation_crew: { user_id: string }[]
  reservation_units: UnitRow[]
  checkout_sessions: SessionRow[]
  return_item_statuses: ReturnedRow[]
}

const FIELDS = `id, reservation_name, student_id, status, is_group_reservation, pickup_date, dropoff_date, dropoff_time,
  locations(name),
  student:users!reservations_student_id_fkey(full_name),
  reservation_crew(user_id),
  reservation_units(unit_id, item_model_id, checked_out_by, checkout_session_id, return_session_id,
    item_units(unit_code, condition, item_models(name)),
    claimer:users!reservation_units_checked_out_by_fkey(full_name)),
  checkout_sessions(id, phase, person_user_id, person_signature, person_confirmed_at, staff_user_id, staff_confirmed_at,
    person:users!checkout_sessions_person_user_id_fkey(full_name),
    staff:users!checkout_sessions_staff_user_id_fkey(full_name)),
  return_item_statuses(unit_id, condition_at_return, note, created_at, return_session_id,
    item_units(unit_code, item_models(name)))`

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const notFound = ref(false)
const error = ref('')
const row = ref<ReservationRow | null>(null)
const flash = ref('')

const me = computed(() => auth.user?.id ?? '')
const isStaffPlus = computed(() => STAFF_PLUS.has(auth.role ?? ''))
const canUpgrade = computed(() => auth.role === 'supervisor' || auth.role === 'admin')

async function load() {
  loading.value = true
  error.value = ''
  notFound.value = false
  try {
    const { data, error: err } = await supabase
      .from('reservations')
      .select(FIELDS)
      .eq('id', route.params.id as string)
      .maybeSingle()
    if (err) throw err
    if (!data) {
      notFound.value = true
      return
    }
    row.value = data as unknown as ReservationRow
    for (const k of Object.keys(selected)) delete selected[k]
    for (const u of myHeldUnits.value) selected[u.unit_id] = true
  } catch (e) {
    error.value = errorMessage(e, 'Could not load this reservation.')
  } finally {
    loading.value = false
  }
}
load()

// ---- shared helpers --------------------------------------------------------
const todayStr = (() => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
})()
const isOverdue = computed(() => !!row.value?.dropoff_date && row.value.dropoff_date < todayStr)
const daysLate = computed(() => {
  if (!isOverdue.value || !row.value?.dropoff_date) return 0
  const a = new Date(row.value.dropoff_date + 'T12:00:00').getTime()
  const b = new Date(todayStr + 'T12:00:00').getTime()
  return Math.round((b - a) / 86400000)
})
const isEarly = computed(() => !!row.value?.dropoff_date && row.value.dropoff_date > todayStr)

function formatDate(d: string | null) {
  if (!d) return '—'
  return new Date(d + 'T12:00:00').toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })
}
function formatTime(t: string | null) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const h12 = h % 12 === 0 ? 12 : h % 12
  return `${h12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`
}
const dropoffLabel = computed(() => {
  if (!row.value?.dropoff_date) return 'No drop-off date'
  return `Due ${formatDate(row.value.dropoff_date)}${row.value.dropoff_time ? ' at ' + formatTime(row.value.dropoff_time) : ''}`
})
function unitName(u: { item_units: { item_models: { name: string } | null } | null }) {
  return u.item_units?.item_models?.name ?? 'Unknown item'
}
function groupByItem<T extends { item_units: { item_models: { name: string } | null } | null }>(units: T[]) {
  const groups = new Map<string, T[]>()
  for (const u of units) {
    const name = unitName(u)
    if (!groups.has(name)) groups.set(name, [])
    groups.get(name)!.push(u)
  }
  return [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([name, list]) => ({ name, units: list }))
}

// ---- person side -----------------------------------------------------------
const confirmedPickupIds = computed(
  () => new Set((row.value?.checkout_sessions ?? []).filter((s) => s.phase === 'pickup' && s.staff_confirmed_at).map((s) => s.id))
)
const myHeldUnits = computed(() =>
  (row.value?.reservation_units ?? []).filter(
    (u) =>
      u.checked_out_by === me.value &&
      !u.return_session_id &&
      !!u.checkout_session_id &&
      confirmedPickupIds.value.has(u.checkout_session_id)
  )
)
const myPendingReturn = computed(
  () =>
    row.value?.checkout_sessions.find(
      (s) => s.phase === 'return' && s.person_user_id === me.value && s.person_confirmed_at && !s.staff_confirmed_at
    ) ?? null
)
const myPendingUnits = computed(() =>
  myPendingReturn.value ? (row.value?.reservation_units ?? []).filter((u) => u.return_session_id === myPendingReturn.value!.id) : []
)
const myReturned = computed(() => {
  const mine = new Set(
    (row.value?.checkout_sessions ?? []).filter((s) => s.phase === 'return' && s.person_user_id === me.value).map((s) => s.id)
  )
  return (row.value?.return_item_statuses ?? []).filter((r) => r.return_session_id && mine.has(r.return_session_id))
})
const isParticipant = computed(
  () =>
    !!row.value &&
    (row.value.student_id === me.value ||
      row.value.reservation_crew.some((c) => c.user_id === me.value) ||
      row.value.reservation_units.some((u) => u.checked_out_by === me.value))
)

const selected = reactive<Record<string, boolean>>({})
const selectedIds = computed(() => myHeldUnits.value.filter((u) => selected[u.unit_id]).map((u) => u.unit_id))
const canSubmit = computed(() => (row.value?.is_group_reservation ? selectedIds.value.length > 0 : myHeldUnits.value.length > 0))
function toggleUnit(id: string) {
  if (!row.value?.is_group_reservation) return
  selected[id] = !selected[id]
}

const showConfirmModal = ref(false)
const initials = ref('')
const submitting = ref(false)
const submitError = ref('')

async function doSubmit() {
  if (!row.value) return
  submitError.value = ''
  if (!initials.value.trim()) {
    submitError.value = 'Type your initials to continue.'
    return
  }
  submitting.value = true
  try {
    const { error: err } = await supabase.rpc('submit_return', {
      p_reservation_id: row.value.id,
      p_unit_ids: row.value.is_group_reservation ? selectedIds.value : null,
      p_initials: initials.value.trim(),
    })
    if (err) throw err
    showConfirmModal.value = false
    initials.value = ''
    flash.value = 'Return submitted. Hand the equipment to Film Cage staff so they can check each item in.'
    await load()
  } catch (e) {
    submitError.value = errorMessage(e, 'Could not submit this return.')
  } finally {
    submitting.value = false
  }
}

// ---- staff side ------------------------------------------------------------
const pendingReturns = computed(
  () =>
    (row.value?.checkout_sessions ?? [])
      .filter((s) => s.phase === 'return' && s.person_confirmed_at && !s.staff_confirmed_at)
      .sort((a, b) => (a.person_confirmed_at ?? '').localeCompare(b.person_confirmed_at ?? ''))
)
function unitsForSession(sessionId: string) {
  return (row.value?.reservation_units ?? []).filter((u) => u.return_session_id === sessionId)
}
// Units still out with someone and not yet in any return -- so staff
// can see who still has what.
const stillOut = computed(() =>
  (row.value?.reservation_units ?? []).filter((u) => !u.return_session_id && u.checkout_session_id && confirmedPickupIds.value.has(u.checkout_session_id))
)

const conditionDrafts = reactive<Record<string, { condition: UnitCondition; note: string }>>({})
function draftFor(u: UnitRow) {
  if (!conditionDrafts[u.unit_id]) {
    conditionDrafts[u.unit_id] = { condition: u.item_units?.condition ?? 'good', note: '' }
  }
  return conditionDrafts[u.unit_id]
}
function pillDisabled(u: UnitRow, c: UnitCondition) {
  // plain staff can keep or lower a condition, never raise it
  if (canUpgrade.value) return false
  return conditionRank(c) > conditionRank(u.item_units?.condition ?? 'good')
}
const staffInitials = reactive<Record<string, string>>({})
const lateFine = reactive<Record<string, boolean>>({})
const staffBusy = reactive<Record<string, boolean>>({})
const staffError = reactive<Record<string, string>>({})

function lateFineFor(sessionId: string) {
  if (lateFine[sessionId] === undefined) lateFine[sessionId] = true
  return lateFine[sessionId]
}

async function checkIn(session: SessionRow) {
  staffError[session.id] = ''
  const units = unitsForSession(session.id)
  const results: Record<string, { condition: UnitCondition; note: string }> = {}
  for (const u of units) {
    const d = draftFor(u)
    if (d.condition !== 'good' && !d.note.trim()) {
      staffError[session.id] = `Add a note for ${unitName(u)} #${u.item_units?.unit_code ?? '?'} — anything other than Good needs one.`
      return
    }
    results[u.unit_id] = { condition: d.condition, note: d.note.trim() }
  }
  if (!(staffInitials[session.id] ?? '').trim()) {
    staffError[session.id] = 'Your initials are required to check this return in.'
    return
  }
  staffBusy[session.id] = true
  try {
    const { data, error: err } = await supabase.rpc('staff_confirm_return', {
      p_session_id: session.id,
      p_staff_initials: staffInitials[session.id].trim(),
      p_unit_results: results,
      p_create_late_fine: isOverdue.value && lateFineFor(session.id),
    })
    if (err) throw err
    const out = (data ?? {}) as { completed?: boolean; fine_created?: boolean }
    const who = session.person?.full_name ?? 'This person'
    flash.value =
      `${who}'s return is checked in.` +
      (out.fine_created ? ' A late-return fine was added to their account.' : '') +
      (out.completed ? ' Everything is back — this reservation is now completed.' : '')
    await load()
  } catch (e) {
    staffError[session.id] = errorMessage(e, 'Could not check in this return.')
  } finally {
    staffBusy[session.id] = false
  }
}

function goBack() {
  router.push({ name: 'pickup' })
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Return</span>
        <h1 v-if="row">{{ row.reservation_name }}</h1>
        <h1 v-else>Return</h1>
        <p v-if="row" class="view-desc">
          {{ row.student?.full_name ?? 'Unknown' }} · {{ row.locations?.name ?? '—' }} · {{ dropoffLabel }}
        </p>
      </div>
      <button class="btn ghost small" @click="goBack"><IconBase name="chevron-left" :size="14" /> Back to Pickup / Return</button>
    </div>

    <p v-if="loading">Loading…</p>
    <p v-else-if="notFound" class="empty-note">This reservation isn't available to view here.</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>

    <template v-else-if="row">
      <div v-if="flash" class="info-note">{{ flash }}</div>
      <div v-if="row.status === 'completed'" class="banner" style="background: var(--good-soft); border: 1px solid var(--good-border); color: var(--good)">
        <span><strong>All equipment has been checked in.</strong> This reservation is completed.</span>
      </div>
      <p v-else-if="row.status !== 'active'" class="empty-note">This reservation hasn't been picked up, so there's nothing to return yet.</p>

      <!-- ===================== PERSON SIDE ===================== -->
      <div v-if="isParticipant && row.status === 'active'" class="card">
        <h2 class="section-title">Your return</h2>

        <template v-if="myPendingReturn">
          <div class="info-note" style="margin-top: 10px">
            You've submitted your return — waiting on Film Cage staff to check each item in. Until they do, the equipment is
            still your responsibility.
          </div>
          <div v-for="u in myPendingUnits" :key="u.unit_id" class="unit-line">
            <span style="font-weight: 600">{{ unitName(u) }}</span>
            <span class="field-hint">Unit #{{ u.item_units?.unit_code ?? '?' }}</span>
          </div>
        </template>

        <template v-else-if="myHeldUnits.length">
          <div v-if="isOverdue" class="banner crit" style="margin-top: 10px">
            <span>This equipment was due back {{ formatDate(row.dropoff_date) }} — {{ daysLate }} day{{ daysLate === 1 ? '' : 's' }} late. A late fee may apply.</span>
          </div>
          <p v-else-if="isEarly" class="field-hint" style="margin-top: 10px">
            You're returning early — it isn't due until {{ formatDate(row.dropoff_date) }}. That's fine; staff will check it in the same way.
          </p>

          <p class="field-hint" style="margin-top: 10px">
            <template v-if="row.is_group_reservation">
              Pick the units you're handing back now. You can only return equipment you checked out yourself; anything you
              keep can be returned on a later visit.
            </template>
            <template v-else>
              Bring back everything below. Staff will check the condition of each item; anything not handed back gets marked
              missing.
            </template>
          </p>

          <div v-for="g in groupByItem(myHeldUnits)" :key="g.name" style="display: flex; flex-direction: column; gap: 6px; margin-top: 8px">
            <div class="kicker">{{ g.name }} × {{ g.units.length }}</div>
            <div
              v-for="u in g.units"
              :key="u.unit_id"
              class="checklist-item"
              :class="{ checked: !row.is_group_reservation || selected[u.unit_id] }"
              :style="row.is_group_reservation ? 'cursor: pointer' : 'cursor: default'"
              @click="toggleUnit(u.unit_id)"
            >
              <div class="check-circle" :class="{ on: !row.is_group_reservation || selected[u.unit_id] }">
                <IconBase v-if="!row.is_group_reservation || selected[u.unit_id]" name="check" :size="13" />
              </div>
              <div style="flex: 1">Unit #{{ u.item_units?.unit_code ?? '?' }}</div>
            </div>
          </div>

          <button class="btn primary" style="width: 100%; margin-top: 12px" :disabled="!canSubmit" @click="showConfirmModal = true">
            Return equipment
          </button>
        </template>

        <p v-else class="empty-note" style="margin-top: 10px">You don't have any equipment checked out on this reservation.</p>

        <template v-if="myReturned.length">
          <hr class="divider" />
          <div class="kicker" style="margin-bottom: 6px">Already checked in</div>
          <div v-for="r in myReturned" :key="r.unit_id + r.created_at" class="unit-line">
            <span style="font-weight: 600">{{ unitName(r) }}</span>
            <span class="field-hint">Unit #{{ r.item_units?.unit_code ?? '?' }} · {{ conditionLabel(r.condition_at_return) }}</span>
          </div>
        </template>
      </div>

      <!-- ===================== STAFF SIDE ===================== -->
      <div v-if="isStaffPlus && row.status === 'active'" class="card">
        <h2 class="section-title">Staff check-in</h2>
        <p v-if="pendingReturns.length === 0" class="empty-note" style="margin-top: 10px">
          Nothing waiting to be checked in. Each person submits their own return first, then it shows up here.
        </p>

        <div v-for="session in pendingReturns" :key="session.id" class="card-flat" style="margin-top: 10px; display: flex; flex-direction: column; gap: 10px">
          <div style="display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 6px">
            <strong>{{ session.person?.full_name ?? 'Unknown' }}</strong>
            <span class="field-hint">signed: {{ session.person_signature }}</span>
          </div>

          <div v-if="isOverdue" class="banner crit">
            <span>Overdue — due {{ formatDate(row.dropoff_date) }}, {{ daysLate }} day{{ daysLate === 1 ? '' : 's' }} late.</span>
          </div>
          <div v-else-if="isEarly" class="field-hint">Early return — not due until {{ formatDate(row.dropoff_date) }}.</div>

          <div v-for="g in groupByItem(unitsForSession(session.id))" :key="g.name">
            <div style="font-weight: 700; font-size: 13.5px">{{ g.name }} <span class="field-hint">× {{ g.units.length }}</span></div>
            <div v-for="u in g.units" :key="u.unit_id" class="unit-line" style="flex-direction: column; align-items: flex-start; gap: 6px">
              <div style="font-weight: 600">
                Unit #{{ u.item_units?.unit_code ?? '?' }}
                <span class="field-hint" style="font-weight: 400">· was {{ conditionLabel(u.item_units?.condition ?? 'good') }}</span>
              </div>
              <div class="cond-pill-row">
                <button
                  v-for="c in CONDITIONS"
                  :key="c"
                  type="button"
                  class="cond-pill"
                  :class="[c, { on: draftFor(u).condition === c }]"
                  :disabled="pillDisabled(u, c)"
                  :title="pillDisabled(u, c) ? 'Only a supervisor or admin can raise a unit\'s condition' : ''"
                  @click="draftFor(u).condition = c"
                >
                  {{ conditionLabel(c) }}
                </button>
              </div>
              <textarea
                v-if="draftFor(u).condition !== 'good'"
                v-model="draftFor(u).note"
                :placeholder="draftFor(u).condition === 'missing' ? 'Required: what happened / not handed back' : 'Required: describe the condition'"
                style="width: 100%"
              ></textarea>
            </div>
          </div>

          <label v-if="isOverdue" style="display: flex; gap: 8px; align-items: flex-start; font-size: 12.5px">
            <input type="checkbox" :checked="lateFineFor(session.id)" @change="lateFine[session.id] = ($event.target as HTMLInputElement).checked" />
            <span>
              Add a late-return fine to {{ session.person?.full_name ?? 'this person' }}'s account ({{ daysLate }}
              day{{ daysLate === 1 ? '' : 's' }} late). The amount follows the standard late-fee schedule.
            </span>
          </label>

          <div class="field">
            <label>Your initials</label>
            <input v-model="staffInitials[session.id]" class="sig-input" placeholder="Initials" maxlength="8" />
          </div>
          <p v-if="staffError[session.id]" class="error-note">{{ staffError[session.id] }}</p>
          <button class="btn primary small" :disabled="staffBusy[session.id]" @click="checkIn(session)">
            {{ staffBusy[session.id] ? 'Checking in…' : 'Check in return' }}
          </button>
        </div>

        <template v-if="stillOut.length">
          <hr class="divider" />
          <div class="kicker" style="margin-bottom: 6px">Still checked out</div>
          <div v-for="u in stillOut" :key="u.unit_id" class="unit-line">
            <span style="font-weight: 600">{{ unitName(u) }}</span>
            <span class="field-hint">Unit #{{ u.item_units?.unit_code ?? '?' }} · {{ u.claimer?.full_name ?? 'Unknown' }}</span>
          </div>
        </template>
      </div>

      <!-- ===================== HISTORY (staff) ===================== -->
      <div v-if="isStaffPlus && row.return_item_statuses.length" class="card">
        <h2 class="section-title">Checked in</h2>
        <div v-for="r in row.return_item_statuses" :key="r.unit_id + r.created_at" class="unit-line" style="flex-wrap: wrap">
          <span style="font-weight: 600">{{ unitName(r) }}</span>
          <span class="field-hint">Unit #{{ r.item_units?.unit_code ?? '?' }} · {{ conditionLabel(r.condition_at_return) }}</span>
          <span v-if="r.note" class="field-hint" style="width: 100%">{{ r.note }}</span>
        </div>
      </div>

      <p v-if="!isParticipant && !isStaffPlus" class="empty-note">You don't have access to this return.</p>
    </template>

    <!-- ===================== INITIALS MODAL ===================== -->
    <div v-if="showConfirmModal" class="modal-backdrop" @click.self="showConfirmModal = false">
      <div class="modal">
        <h2 class="section-title">Confirm return</h2>
        <p style="font-size: 12.5px; color: var(--ink-2); line-height: 1.5">
          By typing your initials below, you confirm you are handing the equipment listed back to The Film Cage. It remains your
          responsibility until Film Cage staff check each item in. Any item staff find damaged or missing may result in repair or
          replacement charges, and a late return may result in a late fee.
        </p>
        <div class="field">
          <label>Your initials</label>
          <input v-model="initials" class="sig-input" placeholder="Type your initials" maxlength="8" autofocus />
        </div>
        <p v-if="submitError" class="error-note">{{ submitError }}</p>
        <div style="display: flex; gap: 8px; justify-content: flex-end">
          <button class="btn ghost" :disabled="submitting" @click="showConfirmModal = false">Cancel</button>
          <button class="btn primary" :disabled="submitting || !initials.trim()" @click="doSubmit">
            {{ submitting ? 'Submitting…' : 'I agree — return equipment' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
.cond-pill:disabled {
  opacity: 0.35;
  cursor: not-allowed;
}
</style>
