<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { conditionLabel, conditionRank, type UnitCondition } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'
import IconBase from '../components/icons/IconBase.vue'

// Pickup checkout screen (migration 25's frontend half) -- "its own
// pass," return/check-in is a later one. One shared page, exactly
// like ReservationDetailView, with what's offered computed purely
// from {who's looking, the row itself}:
//
//   - The reservation's own student (regular) or a listed crew member
//     (group), before they've submitted their own half: the
//     interactive checklist. Regular defaults every line to its full
//     quantity but lets the person dial any line down -- click the
//     row to toggle it between 0 and full, or use the +/- stepper for
//     anything in between; a line at 0 just doesn't get submitted.
//     Crew is explicit free-choice of specific physical units, capped
//     by remaining quantity -- the same click-to-highlight interaction,
//     one level down (unit, not line).
//   - That same person after submitting: a read-only "you're in,
//     waiting on staff" state showing exactly what they claimed.
//   - Staff+: every session on this reservation that's been signed by
//     the person but not yet by staff, with the chance to adjust any
//     claimed unit's condition (mirrors Edit Items' own
//     downgrade-needs-a-note rule) before confirming with their own
//     initials -- no legal language on their side, just confirmation.
//
// Mobile-first throughout per Suzanne's explicit ask -- this is done
// standing at the cage counter on a phone, essentially always.
const STAFF_PLUS = new Set(['staff', 'supervisor', 'admin'])

interface ItemLine {
  item_model_id: string
  quantity: number
  item_models: { name: string } | null
}
interface CrewRow {
  user_id: string
  crew_role: string
  is_producer: boolean
  pickup_time_override: string | null
  users: { full_name: string | null } | null
}
interface ClaimedUnit {
  unit_id: string
  item_model_id: string
  checked_out_by: string
  checkout_session_id: string | null
  checked_out_at: string | null
  item_units: { unit_code: string; condition: UnitCondition; item_models: { name: string } | null } | null
  claimer: { full_name: string | null } | null
}
interface SessionRow {
  id: string
  phase: string
  person_user_id: string | null
  person_signature: string | null
  person_confirmed_at: string | null
  staff_user_id: string | null
  staff_signature: string | null
  staff_confirmed_at: string | null
  person: { full_name: string | null } | null
  staff: { full_name: string | null } | null
}
interface ReservationRow {
  id: string
  reservation_name: string
  student_id: string
  status: string
  is_group_reservation: boolean
  allow_individual_pickup_times: boolean
  pickup_date: string | null
  pickup_time: string | null
  locations: { name: string } | null
  student: { full_name: string | null } | null
  reservation_items: ItemLine[]
  reservation_crew: CrewRow[]
  reservation_units: ClaimedUnit[]
  checkout_sessions: SessionRow[]
}
interface AvailableUnit {
  item_model_id: string
  unit_id: string
  unit_code: string
  condition: UnitCondition
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const notFound = ref(false)
const error = ref('')
const row = ref<ReservationRow | null>(null)
const availableUnits = ref<AvailableUnit[]>([])

const RESERVATION_FIELDS = `id, reservation_name, student_id, status, is_group_reservation, allow_individual_pickup_times,
  pickup_date, pickup_time,
  locations(name),
  student:users!reservations_student_id_fkey(full_name),
  reservation_items(item_model_id, quantity, item_models(name)),
  reservation_crew(user_id, crew_role, is_producer, pickup_time_override, users!reservation_crew_user_id_fkey(full_name)),
  reservation_units(unit_id, item_model_id, checked_out_by, checkout_session_id, checked_out_at,
    item_units(unit_code, condition, item_models(name)),
    claimer:users!reservation_units_checked_out_by_fkey(full_name)),
  checkout_sessions(id, phase, person_user_id, person_signature, person_confirmed_at, staff_user_id, staff_signature, staff_confirmed_at,
    person:users!checkout_sessions_person_user_id_fkey(full_name),
    staff:users!checkout_sessions_staff_user_id_fkey(full_name))`

async function load() {
  loading.value = true
  error.value = ''
  notFound.value = false
  try {
    const id = route.params.id as string
    const { data, error: err } = await supabase
      .from('reservations')
      .select(RESERVATION_FIELDS)
      .eq('id', id)
      .eq('checkout_sessions.phase', 'pickup')
      .maybeSingle()
    if (err) throw err
    if (!data) {
      notFound.value = true
      return
    }
    row.value = data as unknown as ReservationRow

    if (row.value.is_group_reservation) {
      const { data: units, error: unitsErr } = await supabase.rpc('available_units_for_reservation', {
        p_reservation_id: id,
      })
      if (unitsErr) throw unitsErr
      availableUnits.value = (units ?? []) as AvailableUnit[]
    } else {
      availableUnits.value = []
    }
    // Selections don't survive a reload -- intentional, since the
    // available list itself may have just changed underneath them.
    Object.keys(selected).forEach((k) => delete selected[k])
    // Same for the regular-reservation quantity steppers -- default
    // every line back to its full remaining quantity on each load.
    Object.keys(pickupQty).forEach((k) => delete pickupQty[k])
    if (!row.value.is_group_reservation) {
      for (const line of row.value.reservation_items) {
        pickupQty[line.item_model_id] = line.quantity
      }
    }
  } catch (e) {
    error.value = errorMessage(e, 'Could not load this reservation.')
  } finally {
    loading.value = false
  }
}
load()

const isStaffPlus = computed(() => STAFF_PLUS.has(auth.role ?? ''))
const myCrewRow = computed(() => row.value?.reservation_crew.find((c) => c.user_id === auth.user?.id) ?? null)
const isDirector = computed(() => !!row.value && row.value.student_id === auth.user?.id)
const isParticipant = computed(() => isDirector.value || !!myCrewRow.value)

const myScheduledAt = computed(() => {
  if (!row.value?.pickup_date) return null
  let t = row.value.pickup_time
  if (row.value.is_group_reservation && row.value.allow_individual_pickup_times && myCrewRow.value?.pickup_time_override) {
    t = myCrewRow.value.pickup_time_override
  }
  if (!t) return null
  return new Date(`${row.value.pickup_date}T${t}`)
})
const windowOpensAt = computed(() => (myScheduledAt.value ? new Date(myScheduledAt.value.getTime() - 30 * 60000) : null))
const windowOpen = computed(() => (windowOpensAt.value ? Date.now() >= windowOpensAt.value.getTime() : false))
const reservationReady = computed(() => row.value?.status === 'approved' || row.value?.status === 'active')

const mySession = computed(() => row.value?.checkout_sessions.find((s) => s.person_user_id === auth.user?.id) ?? null)
const mySessionSubmitted = computed(() => !!mySession.value?.person_confirmed_at)
const myClaimedUnits = computed(() => row.value?.reservation_units.filter((u) => u.checked_out_by === auth.user?.id) ?? [])

function formatTime(t: string | null) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}
function formatDate(d: string | null) {
  if (!d) return '—'
  return new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}
const scheduleLabel = computed(() => {
  if (!myScheduledAt.value) return 'No pickup time scheduled yet.'
  return `Scheduled ${formatDate(row.value!.pickup_date)} at ${formatTime(
    myScheduledAt.value.toTimeString().slice(0, 5)
  )}`
})

// --- regular reservation: per-line quantity, 0..full -------------
// How many of this line the person is picking up RIGHT NOW. Starts
// at the line's full quantity (see load()); clicking the row toggles
// it between 0 and full as a quick default, the +/- stepper allows
// anything in between. Whatever's left at 0 when they submit gets
// dropped from the reservation server-side (submit_pickup's
// p_quantities) -- same end effect as the old cancel_unpicked_item,
// just folded into one control instead of a separate destructive
// button per line.
const pickupQty = reactive<Record<string, number>>({})

function qtyFor(modelId: string) {
  return pickupQty[modelId] ?? 0
}
function toggleLine(line: ItemLine) {
  pickupQty[line.item_model_id] = qtyFor(line.item_model_id) > 0 ? 0 : line.quantity
}
function stepQty(line: ItemLine, delta: number) {
  const next = qtyFor(line.item_model_id) + delta
  pickupQty[line.item_model_id] = Math.max(0, Math.min(line.quantity, next))
}

// --- crew reservation: free-choice unit selection ------------------
const selected = reactive<Record<string, boolean>>({})

const availableByModel = computed(() => {
  const map = new Map<string, AvailableUnit[]>()
  for (const u of availableUnits.value) {
    if (!map.has(u.item_model_id)) map.set(u.item_model_id, [])
    map.get(u.item_model_id)!.push(u)
  }
  return map
})
function alreadyClaimedCountForModel(modelId: string) {
  return row.value?.reservation_units.filter((u) => u.item_model_id === modelId).length ?? 0
}
function mySelectedCountForModel(modelId: string) {
  return availableUnits.value.filter((u) => u.item_model_id === modelId && selected[u.unit_id]).length
}
function remainingForModel(modelId: string) {
  const line = row.value?.reservation_items.find((l) => l.item_model_id === modelId)
  if (!line) return 0
  return line.quantity - alreadyClaimedCountForModel(modelId) - mySelectedCountForModel(modelId)
}
function unitDisabled(unit: AvailableUnit) {
  return !selected[unit.unit_id] && remainingForModel(unit.item_model_id) <= 0
}
function toggleUnit(unit: AvailableUnit) {
  if (unitDisabled(unit)) return
  selected[unit.unit_id] = !selected[unit.unit_id]
}
function claimedByOthersLine(modelId: string) {
  const others = row.value?.reservation_units.filter(
    (u) => u.item_model_id === modelId && u.checked_out_by !== auth.user?.id
  )
  if (!others || others.length === 0) return null
  return others.map((u) => `${u.item_units?.unit_code ?? 'unit'} (${u.claimer?.full_name ?? 'someone else'})`).join(', ')
}

// --- complete pickup: initials + legal acknowledgement modal -------
const showConfirmModal = ref(false)
const initials = ref('')
const submitting = ref(false)
const submitError = ref('')

const canSubmit = computed(() => {
  if (!row.value) return false
  if (row.value.is_group_reservation) return Object.values(selected).some((v) => v)
  return row.value.reservation_items.some((line) => qtyFor(line.item_model_id) > 0)
})

function openConfirmModal() {
  submitError.value = ''
  initials.value = ''
  showConfirmModal.value = true
}

async function doSubmit() {
  if (!row.value) return
  if (!initials.value.trim()) {
    submitError.value = 'Type your initials to confirm.'
    return
  }
  submitting.value = true
  submitError.value = ''
  try {
    const unitIds = row.value.is_group_reservation
      ? Object.keys(selected).filter((id) => selected[id])
      : null
    const quantities = row.value.is_group_reservation
      ? null
      : Object.fromEntries(row.value.reservation_items.map((line) => [line.item_model_id, qtyFor(line.item_model_id)]))
    const { error: err } = await supabase.rpc('submit_pickup', {
      p_reservation_id: row.value.id,
      p_unit_ids: unitIds,
      p_initials: initials.value.trim(),
      p_quantities: quantities,
    })
    if (err) throw err
    showConfirmModal.value = false
    initials.value = ''
    await load()
  } catch (e) {
    submitError.value = errorMessage(e, 'Could not complete pickup.')
  } finally {
    submitting.value = false
  }
}

// --- staff: confirm a submitted session, adjust condition ----------
const pendingSessions = computed(
  () => row.value?.checkout_sessions.filter((s) => s.person_confirmed_at && !s.staff_confirmed_at) ?? []
)
const confirmedSessions = computed(() => row.value?.checkout_sessions.filter((s) => s.staff_confirmed_at) ?? [])

const staffInitialsDraft = reactive<Record<string, string>>({})
const conditionDrafts = reactive<Record<string, { condition: UnitCondition; note: string }>>({})
const staffBusy = reactive<Record<string, boolean>>({})
const staffError = reactive<Record<string, string>>({})
const CONDITIONS: UnitCondition[] = ['good', 'caution', 'damaged', 'missing']

function unitsForSession(sessionId: string) {
  return row.value?.reservation_units.filter((u) => u.checkout_session_id === sessionId) ?? []
}
// Item name for a claimed unit: from the unit's own model, falling back to the reservation line.
function unitItemName(u: ClaimedUnit) {
  return (
    u.item_units?.item_models?.name ??
    row.value?.reservation_items.find((l) => l.item_model_id === u.item_model_id)?.item_models?.name ??
    'Unknown item'
  )
}
// A session's claimed units grouped under their item, so staff see "Canon C70 × 2" with each unit below.
function unitGroupsForSession(sessionId: string) {
  const groups = new Map<string, { itemModelId: string; name: string; units: ClaimedUnit[] }>()
  for (const u of unitsForSession(sessionId)) {
    let g = groups.get(u.item_model_id)
    if (!g) {
      g = { itemModelId: u.item_model_id, name: unitItemName(u), units: [] }
      groups.set(u.item_model_id, g)
    }
    g.units.push(u)
  }
  return [...groups.values()].sort((a, b) => a.name.localeCompare(b.name))
}
function draftFor(unit: ClaimedUnit) {
  if (!conditionDrafts[unit.unit_id]) {
    conditionDrafts[unit.unit_id] = { condition: unit.item_units?.condition ?? 'good', note: '' }
  }
  return conditionDrafts[unit.unit_id]
}
function isDowngrade(unit: ClaimedUnit) {
  const draft = draftFor(unit)
  return conditionRank(draft.condition) < conditionRank(unit.item_units?.condition ?? 'good')
}

async function confirmSession(session: SessionRow) {
  if (!row.value) return
  const staffInitials = (staffInitialsDraft[session.id] ?? '').trim()
  staffError[session.id] = ''
  if (!staffInitials) {
    staffError[session.id] = 'Type your initials to confirm.'
    return
  }
  for (const u of unitsForSession(session.id)) {
    const draft = draftFor(u)
    if (isDowngrade(u) && !draft.note.trim()) {
      staffError[session.id] = `Add a note before confirming — ${u.item_units?.unit_code ?? 'a unit'} is being set to "${conditionLabel(
        draft.condition
      )}".`
      return
    }
  }
  staffBusy[session.id] = true
  try {
    for (const u of unitsForSession(session.id)) {
      const draft = draftFor(u)
      const current = u.item_units?.condition ?? 'good'
      if (draft.condition !== current) {
        const { error: err } = await supabase
          .from('item_units')
          .update({ condition: draft.condition, condition_note: draft.note.trim() || null })
          .eq('id', u.unit_id)
        if (err) throw err
      }
    }
    const { error: err2 } = await supabase.rpc('staff_confirm_pickup', {
      p_session_id: session.id,
      p_staff_initials: staffInitials,
    })
    if (err2) throw err2
    await load()
  } catch (e) {
    staffError[session.id] = errorMessage(e, 'Could not confirm this checkout.')
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
        <span class="view-eyebrow">Pickup</span>
        <h1 v-if="row">{{ row.reservation_name }}</h1>
        <h1 v-else>Pickup</h1>
        <p v-if="row" class="view-desc">
          {{ row.student?.full_name ?? 'Unknown' }} · {{ row.locations?.name ?? '—' }} · {{ scheduleLabel }}
        </p>
      </div>
      <button class="btn ghost small" @click="goBack"><IconBase name="chevron-left" :size="14" /> Back to Pickup</button>
    </div>

    <p v-if="loading">Loading…</p>
    <p v-else-if="notFound" class="empty-note">This reservation isn't available to view here.</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>

    <template v-else-if="row">
      <!-- ===================== PERSON SIDE ===================== -->
      <div v-if="isParticipant" class="card">
        <h2 class="section-title">Your pickup</h2>

        <div v-if="mySessionSubmitted" style="margin-top: 10px; display: flex; flex-direction: column; gap: 10px">
          <div class="info-note">
            You've completed your pickup — waiting on staff to confirm.
          </div>
          <div v-for="u in myClaimedUnits" :key="u.unit_id" class="unit-line">
            <span style="font-weight: 600">{{ unitItemName(u) }}</span>
            <span class="field-hint">Unit #{{ u.item_units?.unit_code ?? '?' }}</span>
          </div>
        </div>

        <div v-else-if="!reservationReady" class="empty-note" style="margin-top: 10px">
          This reservation isn't ready for pickup right now.
        </div>

        <div v-else-if="!windowOpen" class="empty-note" style="margin-top: 10px">
          Pickup opens 30 minutes before your scheduled time ({{ scheduleLabel }}).
        </div>

        <div v-else style="margin-top: 10px; display: flex; flex-direction: column; gap: 10px">
          <!-- Regular: click a row to toggle it, stepper for partial quantity -->
          <template v-if="!row.is_group_reservation">
            <p class="field-hint">Select the items you're picking up, and how many.</p>
            <div
              v-for="line in row.reservation_items"
              :key="line.item_model_id"
              class="checklist-item"
              :class="{ checked: qtyFor(line.item_model_id) > 0 }"
              @click="toggleLine(line)"
            >
              <div class="check-circle" :class="{ on: qtyFor(line.item_model_id) > 0 }">
                <IconBase v-if="qtyFor(line.item_model_id) > 0" name="check" :size="13" />
              </div>
              <div style="flex: 1">
                <div style="font-weight: 600">{{ line.item_models?.name ?? 'Unknown item' }} × {{ line.quantity }}</div>
              </div>
              <div style="display: flex; align-items: center; gap: 8px" @click.stop>
                <button
                  class="btn ghost small"
                  :disabled="qtyFor(line.item_model_id) <= 0"
                  @click="stepQty(line, -1)"
                >
                  −
                </button>
                <span style="min-width: 1.5em; text-align: center; font-weight: 600">{{ qtyFor(line.item_model_id) }}</span>
                <button
                  class="btn ghost small"
                  :disabled="qtyFor(line.item_model_id) >= line.quantity"
                  @click="stepQty(line, 1)"
                >
                  +
                </button>
              </div>
            </div>
            <p v-if="row.reservation_items.length === 0" class="empty-note">
              Nothing left to pick up — everything was removed.
            </p>
          </template>

          <!-- Crew: explicit free-choice of specific physical units -->
          <template v-else>
            <p class="field-hint">
              Pick the specific units you're taking right now. Anything left unchecked stays available for
              someone else on this reservation to pick up later.
            </p>
            <div v-for="line in row.reservation_items" :key="line.item_model_id" style="display: flex; flex-direction: column; gap: 6px">
              <div class="kicker">
                {{ line.item_models?.name ?? 'Unknown item' }}
                <span v-if="claimedByOthersLine(line.item_model_id)" style="text-transform: none; font-weight: 500">
                  — already claimed: {{ claimedByOthersLine(line.item_model_id) }}
                </span>
              </div>
              <div
                v-for="unit in availableByModel.get(line.item_model_id) ?? []"
                :key="unit.unit_id"
                class="checklist-item"
                :class="{ checked: selected[unit.unit_id] }"
                :style="unitDisabled(unit) ? 'opacity: 0.45' : ''"
                @click="toggleUnit(unit)"
              >
                <div class="check-circle" :class="{ on: selected[unit.unit_id] }">
                  <IconBase v-if="selected[unit.unit_id]" name="check" :size="13" />
                </div>
                <div style="flex: 1">{{ unit.unit_code }}</div>
              </div>
              <p v-if="(availableByModel.get(line.item_model_id) ?? []).length === 0" class="field-hint">
                Nothing left available for this item right now.
              </p>
            </div>
          </template>

          <button class="btn primary" :disabled="!canSubmit" @click="openConfirmModal">Complete Pickup</button>
        </div>
      </div>

      <!-- ===================== STAFF SIDE ===================== -->
      <div v-if="isStaffPlus" class="card">
        <h2 class="section-title">Staff confirmation</h2>

        <p v-if="pendingSessions.length === 0 && confirmedSessions.length === 0" class="empty-note" style="margin-top: 10px">
          No one has submitted their pickup yet.
        </p>

        <div v-for="session in pendingSessions" :key="session.id" class="card-flat" style="margin-top: 10px; display: flex; flex-direction: column; gap: 10px">
          <div style="display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 6px">
            <strong>{{ session.person?.full_name ?? 'Unknown' }}</strong>
            <span class="field-hint">signed: {{ session.person_signature }}</span>
          </div>

          <div v-for="g in unitGroupsForSession(session.id)" :key="g.itemModelId">
          <div style="font-weight: 700; font-size: 13.5px">{{ g.name }} <span class="field-hint">× {{ g.units.length }}</span></div>
          <div v-for="u in g.units" :key="u.unit_id" class="unit-line" style="flex-direction: column; align-items: flex-start; gap: 6px">
            <div style="font-weight: 600">Unit #{{ u.item_units?.unit_code ?? '?' }}</div>
            <div class="cond-pill-row">
              <button
                v-for="c in CONDITIONS"
                :key="c"
                type="button"
                class="cond-pill"
                :class="[c, { on: draftFor(u).condition === c }]"
                @click="draftFor(u).condition = c"
              >
                {{ conditionLabel(c) }}
              </button>
            </div>
            <textarea
              v-if="isDowngrade(u)"
              v-model="draftFor(u).note"
              placeholder="Required note for a condition downgrade"
              style="width: 100%"
            ></textarea>
          </div>
          </div>

          <div class="field">
            <label>Your initials</label>
            <input v-model="staffInitialsDraft[session.id]" class="sig-input" placeholder="Initials" maxlength="8" />
          </div>
          <p v-if="staffError[session.id]" class="error-note">{{ staffError[session.id] }}</p>
          <button class="btn primary small" :disabled="staffBusy[session.id]" @click="confirmSession(session)">
            {{ staffBusy[session.id] ? 'Confirming…' : 'Confirm Pickup' }}
          </button>
        </div>

        <div v-for="session in confirmedSessions" :key="session.id" style="margin-top: 10px">
          <span class="badge good">
            {{ session.person?.full_name ?? 'Unknown' }} confirmed by {{ session.staff?.full_name ?? 'staff' }}
          </span>
        </div>
      </div>

      <p v-if="!isParticipant && !isStaffPlus" class="empty-note">You don't have access to this pickup.</p>
    </template>

    <!-- ===================== INITIALS + LEGAL MODAL ===================== -->
    <div v-if="showConfirmModal" class="modal-backdrop" @click.self="showConfirmModal = false">
      <div class="modal">
        <h2 class="section-title">Confirm pickup</h2>
        <p style="font-size: 12.5px; color: var(--ink-2); line-height: 1.5">
          By typing your initials below, you confirm that you are personally taking possession of the
          equipment checked above and that you are personally and financially responsible for each item for
          the full duration of this loan. This includes responsibility for loss, theft, and damage,
          regardless of cause, until every item has been returned to and confirmed by Film Cage staff. You
          agree to return everything by the scheduled drop-off time and to report any damage, loss, or theft
          immediately. Replacement or repair costs for lost, stolen, or damaged equipment may be charged to
          your account.
        </p>
        <div class="field">
          <label>Your initials</label>
          <input v-model="initials" class="sig-input" placeholder="Type your initials" maxlength="8" autofocus />
        </div>
        <p v-if="submitError" class="error-note">{{ submitError }}</p>
        <div style="display: flex; gap: 8px; justify-content: flex-end">
          <button class="btn ghost" :disabled="submitting" @click="showConfirmModal = false">Cancel</button>
          <button class="btn primary" :disabled="submitting || !initials.trim()" @click="doSubmit">
            {{ submitting ? 'Submitting…' : 'I agree — complete pickup' }}
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
</style>
