<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { errorMessage } from '../lib/errors'

// The "Pickup / Return" tab -- discoverable from the sidebar and
// (separately) the Dashboard. Return/check-in isn't built yet (its
// own later pass -- see the rules doc), so this pass only ever lists
// reservations ready for PICKUP; the page is still named for both
// since that's the nav slot it already occupies.
//
// Two sections, shown to whoever's actually relevant to them:
//   - "Ready for you to pick up": the viewer's own (or crew) reservations
//     inside the 30-minute pickup window, not yet submitted by them.
//   - "Awaiting your confirmation" (staff+ only): every checkout
//     session anyone has submitted that staff hasn't signed off on yet.
// Clicking any row opens the shared PickupCheckoutView for that reservation.
const STAFF_PLUS = new Set(['staff', 'supervisor', 'admin'])

interface ItemLine {
  item_model_id: string
  quantity: number
  item_models: { name: string } | null
}
interface CrewRow {
  user_id: string
  pickup_time_override: string | null
  users: { full_name: string | null } | null
}
interface SessionRow {
  id: string
  person_user_id: string | null
  person_confirmed_at: string | null
  staff_confirmed_at: string | null
  person: { full_name: string | null } | null
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
  checkout_sessions: SessionRow[]
}

const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const error = ref('')
const myRows = ref<ReservationRow[]>([])
const staffRows = ref<ReservationRow[]>([])

const isStaffPlus = computed(() => STAFF_PLUS.has(auth.role ?? ''))

const FIELDS = `id, reservation_name, student_id, status, is_group_reservation, allow_individual_pickup_times,
  pickup_date, pickup_time,
  locations(name),
  student:users!reservations_student_id_fkey(full_name),
  reservation_items(item_model_id, quantity, item_models(name)),
  reservation_crew(user_id, pickup_time_override, users!reservation_crew_user_id_fkey(full_name)),
  checkout_sessions(id, person_user_id, person_confirmed_at, staff_confirmed_at, person:users!checkout_sessions_person_user_id_fkey(full_name))`

async function load() {
  if (!auth.user) return
  loading.value = true
  error.value = ''
  try {
    const [ownedRes, crewRes] = await Promise.all([
      supabase
        .from('reservations')
        .select(FIELDS)
        .eq('student_id', auth.user.id)
        .in('status', ['approved', 'active'])
        .eq('checkout_sessions.phase', 'pickup'),
      // No .eq() filter on the nested checkout_sessions embed here --
      // deep dot-path filters (reservation_crew -> reservations ->
      // checkout_sessions) aren't worth the risk to get right, and
      // 'pickup' is the only phase that exists until Return is built,
      // so there's nothing to filter out yet in practice.
      supabase
        .from('reservation_crew')
        .select(`reservations(${FIELDS})`)
        .eq('user_id', auth.user.id),
    ])
    if (ownedRes.error) throw ownedRes.error
    if (crewRes.error) throw crewRes.error

    const owned = (ownedRes.data ?? []) as unknown as ReservationRow[]
    const seen = new Set(owned.map((r) => r.id))
    const asCrew: ReservationRow[] = []
    for (const row of (crewRes.data ?? []) as unknown as { reservations: ReservationRow | null }[]) {
      const r = row.reservations
      // Not filtered server-side (reservation_crew has no embed-status
      // filter here, same reasoning as MyReservationsView) -- only
      // approved/active reservations matter for pickup, so drop the
      // rest client-side, same as the dedupe below.
      if (!r || seen.has(r.id) || (r.status !== 'approved' && r.status !== 'active')) continue
      seen.add(r.id)
      asCrew.push(r)
    }
    const mine = [...owned, ...asCrew]

    // Only keep ones where the viewer's own 30-minute window is open
    // and they haven't already submitted their half -- this list is
    // "what can I act on right now," not a general status board.
    myRows.value = mine.filter((r) => {
      const already = r.checkout_sessions.some((s) => s.person_user_id === auth.user!.id && s.person_confirmed_at)
      if (already) return false
      const crewRow = r.reservation_crew.find((c) => c.user_id === auth.user!.id)
      let t = r.pickup_time
      if (r.is_group_reservation && r.allow_individual_pickup_times && crewRow?.pickup_time_override) {
        t = crewRow.pickup_time_override
      }
      if (!r.pickup_date || !t) return false
      const scheduledAt = new Date(`${r.pickup_date}T${t}`)
      return Date.now() >= scheduledAt.getTime() - 30 * 60000
    })

    if (isStaffPlus.value) {
      const { data, error: staffErr } = await supabase
        .from('reservations')
        .select(FIELDS)
        .in('status', ['approved', 'active'])
        .eq('checkout_sessions.phase', 'pickup')
        .not('checkout_sessions.person_confirmed_at', 'is', null)
        .is('checkout_sessions.staff_confirmed_at', null)
      if (staffErr) throw staffErr
      staffRows.value = ((data ?? []) as unknown as ReservationRow[]).filter((r) =>
        r.checkout_sessions.some((s) => s.person_confirmed_at && !s.staff_confirmed_at)
      )
    }
  } catch (e) {
    error.value = errorMessage(e, 'Could not load pickups.')
  } finally {
    loading.value = false
  }
}
load()

function itemSummary(r: ReservationRow) {
  return (
    r.reservation_items.map((l) => `${l.item_models?.name ?? 'Unknown item'} ×${l.quantity}`).join(', ') ||
    'No items'
  )
}
function openRow(r: ReservationRow) {
  router.push({ name: 'pickup-checkout', params: { id: r.id } })
}
function pendingNames(r: ReservationRow) {
  return r.checkout_sessions
    .filter((s) => s.person_confirmed_at && !s.staff_confirmed_at)
    .map((s) => s.person?.full_name ?? 'Unknown')
    .join(', ')
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Checkout</span>
        <h1>Pickup / Return</h1>
        <p class="view-desc">Return/check-in is coming in the next pass — this covers pickup for now.</p>
      </div>
    </div>

    <p v-if="loading">Loading…</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>

    <template v-else>
      <div>
        <h2 style="font-size: 14px; margin-bottom: 8px">
          Ready for you to pick up <span class="badge-mini" v-if="myRows.length">{{ myRows.length }}</span>
        </h2>
        <p v-if="myRows.length === 0" class="empty-note">Nothing open for pickup right now.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 12px">
          <div v-for="r in myRows" :key="r.id" class="card" style="cursor: pointer" @click="openRow(r)">
            <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
              <div>
                <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
                <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                  {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
                </div>
              </div>
              <span class="badge accent">Ready for pickup</span>
            </div>
            <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">{{ itemSummary(r) }}</div>
          </div>
        </div>
      </div>

      <div v-if="isStaffPlus">
        <h2 style="font-size: 14px; margin-bottom: 8px; margin-top: 10px">
          Awaiting your confirmation <span class="badge-mini" v-if="staffRows.length">{{ staffRows.length }}</span>
        </h2>
        <p v-if="staffRows.length === 0" class="empty-note">Nothing waiting on staff right now.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 12px">
          <div v-for="r in staffRows" :key="r.id" class="card" style="cursor: pointer" @click="openRow(r)">
            <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
              <div>
                <span class="badge violet" v-if="r.is_group_reservation">Group production</span>
                <div style="font-weight: 700; font-size: 14.5px; margin-top: 4px">
                  {{ r.reservation_name }} · {{ r.locations?.name ?? '—' }}
                </div>
              </div>
              <span class="badge warn">Needs confirmation</span>
            </div>
            <div style="font-size: 12.5px; color: var(--ink-3); margin-top: 8px">Submitted: {{ pendingNames(r) }}</div>
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
</style>
