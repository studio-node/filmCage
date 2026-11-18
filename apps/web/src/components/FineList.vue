<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { errorMessage } from '../lib/errors'
import { toneForFineStatus, type FineStatus } from '../lib/conditionStatus'
import { formatDate, formatMoney, FINE_TYPE_LABELS } from '../lib/format'

// The fine list used in two places:
//  - Users → Fine Resolution tab: every fine, any person (no userId)
//  - a person's own page: just their fines (userId set)
// Resolving goes through the resolve_fine() RPC (migration 32), which
// records how it was settled, what was collected, a required note, and
// who resolved it. A resolved fine is locked except for admin.

type Resolution = 'paid' | 'waived' | 'reduced'

interface FineRow {
  id: string
  student_id: string
  reservation_id: string | null
  fine_type: string
  status: FineStatus
  days_late: number | null
  current_amount: number
  created_at: string
  resolved_at: string | null
  resolved_by: string | null
  issued_by: string | null
  resolution_method: Resolution | null
  amount_paid: number | null
  resolution_note: string | null
  description: string | null
}

const props = withDefaults(defineProps<{ userId?: string | null; refreshKey?: number }>(), {
  userId: null,
  refreshKey: 0,
})
const emit = defineEmits<{ changed: [] }>()

const loading = ref(true)
const error = ref('')
const fines = ref<FineRow[]>([])
const names = ref<Record<string, string>>({})
const reservationNames = ref<Record<string, string>>({})
const filter = ref<'outstanding' | 'resolved' | 'all'>('outstanding')
const search = ref('')

const resolvingId = ref<string | null>(null)
const method = ref<Resolution>('paid')
const reducedAmount = ref<number | null>(null)
const note = ref('')
const busy = ref(false)
const actionError = ref('')

async function load() {
  loading.value = true
  error.value = ''
  try {
    let q = supabase.from('fines_with_amount').select('*').order('created_at', { ascending: false })
    if (props.userId) q = q.eq('student_id', props.userId)
    const { data, error: err } = await q
    if (err) throw err
    fines.value = (data ?? []) as FineRow[]

    const userIds = new Set<string>()
    const resIds = new Set<string>()
    for (const f of fines.value) {
      userIds.add(f.student_id)
      if (f.resolved_by) userIds.add(f.resolved_by)
      if (f.issued_by) userIds.add(f.issued_by)
      if (f.reservation_id) resIds.add(f.reservation_id)
    }
    const [usersRes, resRes] = await Promise.all([
      userIds.size
        ? supabase.from('users').select('id, full_name, email').in('id', [...userIds])
        : Promise.resolve({ data: [], error: null }),
      resIds.size
        ? supabase.from('reservations').select('id, reservation_name').in('id', [...resIds])
        : Promise.resolve({ data: [], error: null }),
    ])
    if (usersRes.error) throw usersRes.error
    if (resRes.error) throw resRes.error
    names.value = Object.fromEntries(
      ((usersRes.data ?? []) as { id: string; full_name: string | null; email: string }[]).map((u) => [
        u.id,
        u.full_name || u.email,
      ])
    )
    reservationNames.value = Object.fromEntries(
      ((resRes.data ?? []) as { id: string; reservation_name: string }[]).map((r) => [r.id, r.reservation_name])
    )
  } catch (e) {
    error.value = errorMessage(e, 'Could not load fines.')
  } finally {
    loading.value = false
  }
}
load()
watch(() => [props.userId, props.refreshKey], load)

const visible = computed(() => {
  const q = search.value.trim().toLowerCase()
  return fines.value.filter((f) => {
    if (filter.value === 'outstanding' && f.status === 'resolved') return false
    if (filter.value === 'resolved' && f.status !== 'resolved') return false
    if (q && !(names.value[f.student_id] ?? '').toLowerCase().includes(q)) return false
    return true
  })
})

const outstanding = computed(() => fines.value.filter((f) => f.status !== 'resolved'))
const outstandingTotal = computed(() => outstanding.value.reduce((s, f) => s + Number(f.current_amount), 0))

function statusLabel(s: FineStatus) {
  return { warning: 'Warning', active: 'Outstanding', on_hold: 'On hold', resolved: 'Resolved' }[s]
}
function methodLabel(m: Resolution | null) {
  return m === 'paid' ? 'Paid in full' : m === 'waived' ? 'Waived' : m === 'reduced' ? 'Reduced' : '—'
}

function startResolve(f: FineRow) {
  resolvingId.value = f.id
  method.value = 'paid'
  reducedAmount.value = null
  note.value = ''
  actionError.value = ''
}

async function confirmResolve(f: FineRow) {
  actionError.value = ''
  if (!note.value.trim()) {
    actionError.value = 'Add a note (for example: paid cash at the counter, or why it was waived).'
    return
  }
  if (method.value === 'reduced') {
    const amt = Number(reducedAmount.value)
    if (!amt || amt <= 0 || amt >= Number(f.current_amount)) {
      actionError.value = `Enter an amount above $0 and below ${formatMoney(f.current_amount)}.`
      return
    }
  }
  busy.value = true
  try {
    const { error: err } = await supabase.rpc('resolve_fine', {
      p_fine_id: f.id,
      p_method: method.value,
      p_amount_paid: method.value === 'reduced' ? Number(reducedAmount.value) : null,
      p_note: note.value.trim(),
    })
    if (err) throw err
    resolvingId.value = null
    await load()
    emit('changed')
  } catch (e) {
    actionError.value = errorMessage(e, 'Could not resolve this fine.')
  } finally {
    busy.value = false
  }
}

defineExpose({ reload: load })
</script>

<template>
  <div style="display: flex; flex-direction: column; gap: 12px">
    <div style="display: flex; gap: 10px; align-items: center; flex-wrap: wrap; justify-content: space-between">
      <div class="chip-row">
        <button class="chip" :class="{ active: filter === 'outstanding' }" @click="filter = 'outstanding'">
          Outstanding ({{ outstanding.length }})
        </button>
        <button class="chip" :class="{ active: filter === 'resolved' }" @click="filter = 'resolved'">Resolved</button>
        <button class="chip" :class="{ active: filter === 'all' }" @click="filter = 'all'">All</button>
      </div>
      <div style="display: flex; gap: 10px; align-items: center">
        <span class="field-hint">Outstanding total: <strong>{{ formatMoney(outstandingTotal) }}</strong></span>
        <input
          v-if="!userId"
          v-model="search"
          class="fine-search"
          type="search"
          placeholder="Filter by name"
          aria-label="Filter fines by name"
        />
      </div>
    </div>

    <p v-if="loading" class="empty-note">Loading fines…</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>
    <p v-else-if="visible.length === 0" class="empty-note">
      {{ filter === 'outstanding' ? 'No outstanding fines.' : 'No fines here.' }}
    </p>

    <div v-for="f in visible" v-else :key="f.id" class="card">
      <div style="display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; flex-wrap: wrap">
        <div>
          <router-link
            v-if="!userId"
            class="staff-row-name"
            :to="{ name: 'user-detail', params: { id: f.student_id } }"
          >
            {{ names[f.student_id] ?? 'Unknown person' }}
          </router-link>
          <div :class="userId ? 'staff-row-name' : 'staff-row-sub'">
            {{ FINE_TYPE_LABELS[f.fine_type] ?? f.fine_type }} · {{ formatMoney(f.current_amount) }}
            <template v-if="f.fine_type === 'late_return' && f.days_late !== null">
              ({{ f.days_late }} day{{ f.days_late === 1 ? '' : 's' }} late)
            </template>
          </div>
          <div class="field-hint" style="margin-top: 2px">
            Added {{ formatDate(f.created_at) }}<template v-if="f.issued_by"> by {{ names[f.issued_by] ?? 'staff' }}</template>
            <template v-if="f.reservation_id">
              ·
              <router-link :to="{ name: 'reservation-detail', params: { id: f.reservation_id } }">
                {{ reservationNames[f.reservation_id] ?? 'Reservation' }}
              </router-link>
            </template>
          </div>
          <div v-if="f.description" style="font-size: 13px; margin-top: 6px">{{ f.description }}</div>
        </div>
        <span class="badge" :class="toneForFineStatus(f.status)">{{ statusLabel(f.status) }}</span>
      </div>

      <div v-if="f.status === 'resolved'" class="card-flat" style="margin-top: 10px; font-size: 13px">
        <strong>{{ methodLabel(f.resolution_method) }}</strong>
        <template v-if="f.amount_paid !== null"> · {{ formatMoney(f.amount_paid) }} collected</template>
        · {{ formatDate(f.resolved_at) }}<template v-if="f.resolved_by"> by {{ names[f.resolved_by] ?? 'staff' }}</template>
        <div v-if="f.resolution_note" class="field-hint" style="margin-top: 4px">{{ f.resolution_note }}</div>
      </div>

      <template v-else>
        <div v-if="resolvingId !== f.id" style="margin-top: 10px">
          <button class="btn small primary" @click="startResolve(f)">Resolve…</button>
        </div>
        <div v-else class="card-flat" style="margin-top: 10px; display: flex; flex-direction: column; gap: 10px">
          <div class="chip-row">
            <button class="chip" :class="{ active: method === 'paid' }" @click="method = 'paid'">
              Paid in full ({{ formatMoney(f.current_amount) }})
            </button>
            <button class="chip" :class="{ active: method === 'reduced' }" @click="method = 'reduced'">Reduced amount</button>
            <button class="chip" :class="{ active: method === 'waived' }" @click="method = 'waived'">Waived</button>
          </div>
          <div v-if="method === 'reduced'" class="field" style="max-width: 200px">
            <label>Amount collected ($)</label>
            <input v-model.number="reducedAmount" type="number" min="0.01" step="0.01" />
          </div>
          <div class="field">
            <label>Note (required)</label>
            <textarea v-model="note" rows="2" placeholder="e.g. Paid cash at the counter / Waived: first offense" />
          </div>
          <p v-if="actionError" class="error-note">{{ actionError }}</p>
          <div style="display: flex; gap: 8px">
            <button class="btn small primary" :disabled="busy" @click="confirmResolve(f)">
              {{ busy ? 'Saving…' : 'Mark resolved' }}
            </button>
            <button class="btn small ghost" :disabled="busy" @click="resolvingId = null">Cancel</button>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.fine-search {
  padding: 7px 10px;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--surface);
  color: var(--ink);
  font: inherit;
  font-size: 13px;
}
textarea {
  width: 100%;
  resize: vertical;
}
</style>
