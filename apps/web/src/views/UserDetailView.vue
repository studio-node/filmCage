<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { errorMessage } from '../lib/errors'
import { toneForReservationStatus, reservationStatusLabel, type ReservationStatus } from '../lib/conditionStatus'
import { formatDate, formatTime, roleLabel, one, ROLE_LABELS } from '../lib/format'
import { sendPasswordResetEmail } from '../lib/passwordReset'
import FineList from '../components/FineList.vue'
import IconBase from '../components/icons/IconBase.vue'

// One person's page, opened from Users. Who can do what:
//   - Admin only: name, email, password, role, class/tier, deactivate.
//     (Email/password/deactivate go through admin_* RPCs, migration 32,
//     because they have to touch Supabase Auth.)
//   - Staff+: block, suspend checkout, notes/strikes, issue + resolve
//     fines. Unblocking stays admin-only (user_profiles_unblock_guard).
//   - Everyone here (staff+) sees all of it read-only.
// A reservation row opens the shared Reservation Detail page, which has
// the full staff+ approve/deny/edit/cancel/delete tools.

type Tier = 'beginner' | 'intermediate' | 'advanced'
interface Profile {
  tier: Tier | null
  class_taken: string | null
  needs_tier_reconfirmation: boolean | null
  strike_count: number
  is_blocked: boolean
  blocked_at: string | null
  blocked_by: string | null
  checkout_suspended: boolean
  suspended_at: string | null
  suspended_reason: string | null
}
interface UserRecord {
  id: string
  full_name: string | null
  email: string
  role: string
  is_active: boolean
  created_at: string
  user_profiles: Profile | Profile[] | null
}
interface Course {
  id: string
  course_name: string
  course_code: string | null
  tier: Tier
}
interface Note {
  id: string
  note_text: string
  is_strike: boolean
  strike_reason: string | null
  created_at: string
  author_id: string
}
interface ResRow {
  id: string
  reservation_name: string
  status: ReservationStatus
  is_capstone: boolean
  is_group_reservation: boolean
  pickup_date: string | null
  pickup_time: string | null
  dropoff_date: string | null
  dropoff_time: string | null
  locations: { name: string } | null
  reservation_items: { quantity: number; item_models: { name: string } | null }[]
  student: { full_name: string | null } | null
  crewRole?: string
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const isAdmin = computed(() => auth.role === 'admin')
const userId = computed(() => String(route.params.id))
const isSelf = computed(() => auth.user?.id === userId.value)

const loading = ref(true)
const loadError = ref('')
const user = ref<UserRecord | null>(null)
const profile = computed(() => one(user.value?.user_profiles))
const courses = ref<Course[]>([])
const notes = ref<Note[]>([])
const names = ref<Record<string, string>>({})
const reservations = ref<ResRow[]>([])
const fineRefresh = ref(0)

// per-section UI state
const msg = ref<Record<string, string>>({})
const err = ref<Record<string, string>>({})
const busy = ref<Record<string, boolean>>({})
function clearMsg(key: string) {
  msg.value[key] = ''
  err.value[key] = ''
}

// drafts
const nameDraft = ref('')
const emailDraft = ref('')
const roleDraft = ref('student')
const classDraft = ref<string | null>(null)
const tierDraft = ref<Tier>('beginner')
const passwordDraft = ref('')
const suspendReason = ref('')
const resetStrikesOnUnblock = ref(true)
const confirming = ref<'' | 'deactivate' | 'block' | 'unblock'>('')
const reservationsOpen = ref(false)

const SELECT_RES = `id, reservation_name, status, is_capstone, is_group_reservation,
  pickup_date, pickup_time, dropoff_date, dropoff_time,
  locations(name), reservation_items(quantity, item_models(name)),
  student:users!reservations_student_id_fkey(full_name)`

async function load() {
  loading.value = true
  loadError.value = ''
  try {
    const id = userId.value
    const [userRes, courseRes, notesRes, ownRes, crewRes] = await Promise.all([
      supabase
        .from('users')
        .select(
          `id, full_name, email, role, is_active, created_at,
           user_profiles!user_profiles_user_id_fkey(tier, class_taken, needs_tier_reconfirmation, strike_count, is_blocked, blocked_at, blocked_by,
                         checkout_suspended, suspended_at, suspended_reason)`
        )
        .eq('id', id)
        .maybeSingle(),
      supabase
        .from('course_tier_mappings')
        .select('id, course_name, course_code, tier')
        .eq('is_active', true)
        .order('display_order'),
      supabase
        .from('student_notes')
        .select('id, note_text, is_strike, strike_reason, created_at, author_id')
        .eq('student_id', id)
        .order('created_at', { ascending: false }),
      supabase.from('reservations').select(SELECT_RES).eq('student_id', id).order('pickup_date', { ascending: false }),
      supabase.from('reservation_crew').select(`crew_role, reservations!reservation_crew_reservation_id_fkey(${SELECT_RES})`).eq('user_id', id),
    ])
    for (const r of [userRes, courseRes, notesRes, ownRes, crewRes]) if (r.error) throw r.error
    if (!userRes.data) {
      loadError.value = 'That user doesn’t exist.'
      return
    }
    user.value = userRes.data as unknown as UserRecord
    courses.value = (courseRes.data ?? []) as Course[]
    notes.value = (notesRes.data ?? []) as Note[]

    const own = (ownRes.data ?? []) as unknown as ResRow[]
    const ownIds = new Set(own.map((r) => r.id))
    const crew: ResRow[] = []
    for (const c of (crewRes.data ?? []) as unknown as { crew_role: string; reservations: ResRow | ResRow[] | null }[]) {
      const r = one(c.reservations)
      if (r && !ownIds.has(r.id)) crew.push({ ...r, crewRole: c.crew_role })
    }
    reservations.value = [...own, ...crew]

    // names for note authors / blocker
    const ids = new Set(notes.value.map((n) => n.author_id))
    const p = one(user.value.user_profiles)
    if (p?.blocked_by) ids.add(p.blocked_by)
    if (ids.size) {
      const { data } = await supabase.from('users').select('id, full_name, email').in('id', [...ids])
      names.value = Object.fromEntries(
        ((data ?? []) as { id: string; full_name: string | null; email: string }[]).map((u) => [u.id, u.full_name || u.email])
      )
    }

    nameDraft.value = user.value.full_name ?? ''
    emailDraft.value = user.value.email
    roleDraft.value = user.value.role
    classDraft.value = p?.class_taken ?? null
    tierDraft.value = (p?.tier ?? 'beginner') as Tier
  } catch (e) {
    loadError.value = errorMessage(e, 'Could not load this user.')
  } finally {
    loading.value = false
  }
}
load()
watch(userId, load)

// ---------------- admin: account ----------------
async function run(key: string, fn: () => Promise<void>, okText: string) {
  clearMsg(key)
  busy.value[key] = true
  try {
    await fn()
    msg.value[key] = okText
  } catch (e) {
    err.value[key] = errorMessage(e, 'Something went wrong.')
  } finally {
    busy.value[key] = false
  }
}

function saveAccount() {
  return run(
    'account',
    async () => {
      const { error } = await supabase.rpc('admin_update_user_account', {
        p_user_id: userId.value,
        p_full_name: nameDraft.value,
        p_email: emailDraft.value,
      })
      if (error) throw error
      await load()
      if (isSelf.value) await auth.loadProfile()
    },
    'Saved.'
  )
}

function saveRole() {
  return run(
    'role',
    async () => {
      const { error } = await supabase.from('users').update({ role: roleDraft.value }).eq('id', userId.value)
      if (error) throw error
      await load()
    },
    'Role updated.'
  )
}

function pickClass(id: string | null) {
  classDraft.value = id
  const c = courses.value.find((x) => x.id === id)
  if (c) tierDraft.value = c.tier
}
function saveTier() {
  return run(
    'tier',
    async () => {
      const { error } = await supabase
        .from('user_profiles')
        .update({ class_taken: classDraft.value, tier: tierDraft.value, needs_tier_reconfirmation: false })
        .eq('user_id', userId.value)
      if (error) throw error
      await load()
    },
    'Class and tier saved.'
  )
}

function setPassword() {
  if (passwordDraft.value.length < 8) {
    err.value.password = 'Password must be at least 8 characters.'
    return
  }
  return run(
    'password',
    async () => {
      const { error } = await supabase.rpc('admin_set_user_password', {
        p_user_id: userId.value,
        p_password: passwordDraft.value,
      })
      if (error) throw error
      passwordDraft.value = ''
    },
    'Password set. Give it to them privately; they can change it from their profile.'
  )
}
function sendReset() {
  return run(
    'password',
    async () => {
      if (!user.value) return
      await sendPasswordResetEmail(user.value.email)
    },
    `Reset email sent to ${user.value?.email}.`
  )
}

function setActive(active: boolean) {
  return run(
    'active',
    async () => {
      const { error } = await supabase.rpc('admin_set_user_active', { p_user_id: userId.value, p_active: active })
      if (error) throw error
      confirming.value = ''
      await load()
    },
    active ? 'Account reactivated.' : 'Account deactivated. They can no longer sign in.'
  )
}

// ---------------- staff+: status ----------------
function updateProfile(key: string, patch: Record<string, unknown>, okText: string) {
  return run(
    key,
    async () => {
      const { error } = await supabase.from('user_profiles').update(patch).eq('user_id', userId.value)
      if (error) throw error
      confirming.value = ''
      suspendReason.value = ''
      await load()
    },
    okText
  )
}
function block() {
  return updateProfile('status', { is_blocked: true }, 'Account blocked.')
}
function unblock() {
  const patch: Record<string, unknown> = { is_blocked: false }
  if (resetStrikesOnUnblock.value) patch.strike_count = 0
  return updateProfile('status', patch, 'Account unblocked.')
}
function suspend() {
  if (!suspendReason.value.trim()) {
    err.value.status = 'Add a reason for the suspension.'
    return
  }
  return updateProfile('status', { checkout_suspended: true, suspended_reason: suspendReason.value.trim() }, 'Checkout suspended.')
}
function liftSuspension() {
  return updateProfile('status', { checkout_suspended: false }, 'Suspension lifted.')
}

// ---------------- staff+: notes & strikes ----------------
const noteText = ref('')
const noteIsStrike = ref(false)
const strikeReason = ref<'damage' | 'late_return' | 'behavioral'>('late_return')
function addNote() {
  if (!noteText.value.trim()) {
    err.value.notes = 'Write the note first.'
    return
  }
  return run(
    'notes',
    async () => {
      const { error } = await supabase.from('student_notes').insert({
        student_id: userId.value,
        author_id: auth.user?.id,
        note_text: noteText.value.trim(),
        is_strike: noteIsStrike.value,
        strike_reason: noteIsStrike.value ? strikeReason.value : null,
      })
      if (error) throw error
      noteText.value = ''
      noteIsStrike.value = false
      await load()
    },
    'Note added.'
  )
}

// ---------------- staff+: issue a fine ----------------
const issuing = ref(false)
const fineType = ref<'damage' | 'missing' | 'other'>('damage')
const fineAmount = ref<number | null>(null)
const fineDescription = ref('')
const fineReservation = ref<string | null>(null)
function issueFine() {
  if (!fineAmount.value || fineAmount.value <= 0) {
    err.value.fine = 'Enter an amount above $0.'
    return
  }
  if (!fineDescription.value.trim()) {
    err.value.fine = 'Describe what the fine is for.'
    return
  }
  return run(
    'fine',
    async () => {
      const { error } = await supabase.rpc('issue_fine', {
        p_student_id: userId.value,
        p_fine_type: fineType.value,
        p_amount: fineAmount.value,
        p_description: fineDescription.value.trim(),
        p_reservation_id: fineReservation.value,
        p_unit_id: null,
      })
      if (error) throw error
      issuing.value = false
      fineAmount.value = null
      fineDescription.value = ''
      fineReservation.value = null
      fineRefresh.value++
    },
    'Fine added. They’ve been notified.'
  )
}

// ---------------- reservations ----------------
const today = new Date().toISOString().slice(0, 10)
function bucket(r: ResRow): 'active' | 'upcoming' | 'past' {
  if (r.status === 'active') return 'active'
  const relevantDate = r.dropoff_date ?? r.pickup_date
  const datePassed = !!relevantDate && relevantDate < today
  if (r.status === 'completed' || r.status === 'cancelled' || r.status === 'denied' || datePassed) return 'past'
  return 'upcoming'
}
const sections = computed(() => {
  const byDate = (a: ResRow, b: ResRow) => (a.pickup_date ?? '').localeCompare(b.pickup_date ?? '')
  return [
    { key: 'active', label: 'Active (checked out now)', rows: reservations.value.filter((r) => bucket(r) === 'active').sort(byDate) },
    { key: 'upcoming', label: 'Upcoming', rows: reservations.value.filter((r) => bucket(r) === 'upcoming').sort(byDate) },
    { key: 'past', label: 'Past', rows: reservations.value.filter((r) => bucket(r) === 'past').sort((a, b) => byDate(b, a)) },
  ]
})
function itemSummary(r: ResRow) {
  return (
    r.reservation_items
      .map((l) => `${l.item_models?.name ?? 'Unknown item'}${l.quantity > 1 ? ` ×${l.quantity}` : ''}`)
      .join(', ') || 'No items'
  )
}
function scheduleLine(r: ResRow) {
  if (!r.pickup_date) return 'Not scheduled yet'
  return `${formatDate(r.pickup_date)} ${formatTime(r.pickup_time)} → ${formatDate(r.dropoff_date)} ${formatTime(r.dropoff_time)}`
}
function openReservation(r: ResRow) {
  router.push({ name: 'reservation-detail', params: { id: r.id } })
}

const STRIKE_LABELS: Record<string, string> = { damage: 'Damage', late_return: 'Late return', behavioral: 'Behavioral' }
function courseLabel(c: Course) {
  return c.course_code ? `${c.course_code} — ${c.course_name}` : c.course_name
}
const currentCourse = computed(() => courses.value.find((c) => c.id === profile.value?.class_taken) ?? null)
</script>

<template>
  <div class="view">
    <router-link :to="{ name: 'users' }" class="back-link">
      <IconBase name="chevron-left" :size="15" /> All users
    </router-link>

    <p v-if="loading" class="empty-note">Loading…</p>
    <p v-else-if="loadError" class="error-note">{{ loadError }}</p>

    <template v-else-if="user">
      <!-- ============ Header ============ -->
      <div class="card user-head">
        <div class="crew-avatar big">{{ (user.full_name || user.email).slice(0, 1).toUpperCase() }}</div>
        <div style="flex: 1; min-width: 0">
          <h1 style="margin: 0">{{ user.full_name || user.email }}</h1>
          <div class="staff-row-sub">{{ user.email }} · member since {{ formatDate(user.created_at) }}</div>
          <div class="chip-row" style="margin-top: 8px">
            <span class="badge neutral">{{ roleLabel(user.role) }}</span>
            <span v-if="profile?.tier" class="badge muted" style="text-transform: capitalize">{{ profile.tier }} tier</span>
            <span v-if="!user.is_active" class="badge muted">Deactivated</span>
            <span v-if="profile?.is_blocked" class="badge crit">Blocked</span>
            <span v-if="profile?.checkout_suspended" class="badge warn">Checkout suspended</span>
            <span v-if="(profile?.strike_count ?? 0) > 0" class="badge warn">
              {{ profile?.strike_count }} strike{{ profile?.strike_count === 1 ? '' : 's' }}
            </span>
            <span v-if="profile?.needs_tier_reconfirmation" class="badge accent">Tier change requested</span>
          </div>
        </div>
      </div>

      <!-- ============ Account (admin edits) ============ -->
      <section class="card section">
        <h2 class="section-title">Account</h2>
        <p v-if="!isAdmin" class="lock-note">Only an admin can change account details.</p>

        <div class="field-row">
          <div class="field">
            <label>Full name</label>
            <input v-model="nameDraft" :disabled="!isAdmin" />
          </div>
          <div class="field">
            <label>Email (used to sign in)</label>
            <input v-model="emailDraft" type="email" :disabled="!isAdmin" />
          </div>
        </div>
        <div v-if="isAdmin" class="row-actions">
          <button
            class="btn small primary"
            :disabled="busy.account || (nameDraft === (user.full_name ?? '') && emailDraft === user.email)"
            @click="saveAccount"
          >
            {{ busy.account ? 'Saving…' : 'Save name & email' }}
          </button>
          <span v-if="emailDraft.trim().toLowerCase() !== user.email.toLowerCase()" class="field-hint">
            They’ll sign in with the new email from now on.
          </span>
        </div>
        <p v-if="msg.account" class="info-note">{{ msg.account }}</p>
        <p v-if="err.account" class="error-note">{{ err.account }}</p>

        <div class="divider" />

        <div class="field-row">
          <div class="field">
            <label>Role</label>
            <select v-model="roleDraft" :disabled="!isAdmin || isSelf">
              <option v-for="(label, value) in ROLE_LABELS" :key="value" :value="value">{{ label }}</option>
            </select>
            <span v-if="isAdmin && isSelf" class="field-hint">You can’t change your own role.</span>
          </div>
          <div v-if="isAdmin && !isSelf" class="field" style="justify-content: flex-end">
            <button class="btn small" :disabled="busy.role || roleDraft === user.role" @click="saveRole">
              {{ busy.role ? 'Saving…' : 'Change role' }}
            </button>
          </div>
        </div>
        <p v-if="msg.role" class="info-note">{{ msg.role }}</p>
        <p v-if="err.role" class="error-note">{{ err.role }}</p>

        <template v-if="user.role === 'student'">
          <div class="divider" />
          <div class="field-row">
            <div class="field">
              <label>Class taken</label>
              <select :value="classDraft ?? ''" :disabled="!isAdmin" @change="pickClass(($event.target as HTMLSelectElement).value || null)">
                <option value="">— None —</option>
                <option v-for="c in courses" :key="c.id" :value="c.id">{{ courseLabel(c) }} ({{ c.tier }})</option>
              </select>
            </div>
            <div class="field">
              <label>Tier</label>
              <select v-model="tierDraft" :disabled="!isAdmin">
                <option value="beginner">Beginner</option>
                <option value="intermediate">Intermediate</option>
                <option value="advanced">Advanced</option>
              </select>
            </div>
          </div>
          <p v-if="profile?.needs_tier_reconfirmation" class="field-hint">
            They picked {{ currentCourse ? courseLabel(currentCourse) : 'a new class' }} and are waiting for a tier
            review. Saving here confirms it (it can also be confirmed from the Dashboard).
          </p>
          <div v-if="isAdmin" class="row-actions">
            <button
              class="btn small"
              :disabled="busy.tier || (classDraft === (profile?.class_taken ?? null) && tierDraft === profile?.tier && !profile?.needs_tier_reconfirmation)"
              @click="saveTier"
            >
              {{ busy.tier ? 'Saving…' : 'Save class & tier' }}
            </button>
          </div>
          <p v-if="msg.tier" class="info-note">{{ msg.tier }}</p>
          <p v-if="err.tier" class="error-note">{{ err.tier }}</p>
        </template>

        <template v-if="isAdmin">
          <div class="divider" />
          <div class="field">
            <label>Password</label>
            <span class="field-hint">
              Passwords are stored encrypted, so no one can look one up. Set a new temporary one, or email them a
              reset link.
            </span>
          </div>
          <div class="row-actions">
            <input
              v-model="passwordDraft"
              type="text"
              class="inline-input"
              placeholder="New password (8+ characters)"
              autocomplete="off"
            />
            <button class="btn small" :disabled="busy.password || !passwordDraft" @click="setPassword">Set password</button>
            <button class="btn small ghost" :disabled="busy.password" @click="sendReset">Send reset email</button>
          </div>
          <p v-if="msg.password" class="info-note">{{ msg.password }}</p>
          <p v-if="err.password" class="error-note">{{ err.password }}</p>

          <div class="divider" />
          <div class="row-actions">
            <template v-if="user.is_active">
              <button v-if="confirming !== 'deactivate'" class="btn small danger" :disabled="isSelf" @click="confirming = 'deactivate'">
                Deactivate account…
              </button>
              <template v-else>
                <span class="field-hint">They won’t be able to sign in. Their history stays. Deactivate?</span>
                <button class="btn small danger" :disabled="busy.active" @click="setActive(false)">Yes, deactivate</button>
                <button class="btn small ghost" @click="confirming = ''">Never mind</button>
              </template>
              <span v-if="isSelf" class="field-hint">You can’t deactivate your own account.</span>
            </template>
            <button v-else class="btn small primary" :disabled="busy.active" @click="setActive(true)">Reactivate account</button>
          </div>
          <p v-if="msg.active" class="info-note">{{ msg.active }}</p>
          <p v-if="err.active" class="error-note">{{ err.active }}</p>
        </template>
      </section>

      <!-- ============ Account status (staff+) ============ -->
      <section class="card section">
        <h2 class="section-title">Checkout status</h2>
        <p class="field-hint">
          Blocked or suspended accounts can’t make their own reservations. Three strikes blocks an account
          automatically. Only an admin can unblock.
        </p>

        <div class="status-block">
          <div>
            <strong>Block</strong>
            <div class="field-hint">
              <template v-if="profile?.is_blocked">
                Blocked {{ formatDate(profile.blocked_at) }}<template v-if="profile.blocked_by"> by {{ names[profile.blocked_by] ?? 'staff' }}</template>
              </template>
              <template v-else>Not blocked</template>
            </div>
          </div>
          <div class="row-actions">
            <template v-if="!profile?.is_blocked">
              <button v-if="confirming !== 'block'" class="btn small danger" @click="confirming = 'block'">Block account…</button>
              <template v-else>
                <button class="btn small danger" :disabled="busy.status" @click="block">Yes, block</button>
                <button class="btn small ghost" @click="confirming = ''">Never mind</button>
              </template>
            </template>
            <template v-else-if="isAdmin">
              <label class="check-label"><input v-model="resetStrikesOnUnblock" type="checkbox" /> Reset strikes to 0</label>
              <button class="btn small primary" :disabled="busy.status" @click="unblock">Unblock</button>
            </template>
            <span v-else class="field-hint">Ask an admin to unblock.</span>
          </div>
        </div>
        <p v-if="profile?.is_blocked && isAdmin && !resetStrikesOnUnblock && (profile?.strike_count ?? 0) >= 2" class="field-hint">
          With {{ profile?.strike_count }} strikes kept, the next strike will block them again.
        </p>

        <div class="status-block">
          <div style="flex: 1">
            <strong>Checkout suspension</strong>
            <div class="field-hint">
              <template v-if="profile?.checkout_suspended">
                Suspended {{ formatDate(profile.suspended_at) }}: {{ profile.suspended_reason }}
              </template>
              <template v-else>Not suspended</template>
            </div>
          </div>
          <div class="row-actions">
            <template v-if="profile?.checkout_suspended">
              <button class="btn small primary" :disabled="busy.status" @click="liftSuspension">Lift suspension</button>
            </template>
            <template v-else>
              <input v-model="suspendReason" class="inline-input" placeholder="Reason (e.g. unpaid fine)" />
              <button class="btn small" :disabled="busy.status" @click="suspend">Suspend checkout</button>
            </template>
          </div>
        </div>
        <p v-if="msg.status" class="info-note">{{ msg.status }}</p>
        <p v-if="err.status" class="error-note">{{ err.status }}</p>
      </section>

      <!-- ============ Reservations (collapsible) ============ -->
      <section class="card section">
        <button class="collapse-head" :aria-expanded="reservationsOpen" @click="reservationsOpen = !reservationsOpen">
          <h2 class="section-title" style="margin: 0">Reservations</h2>
          <span class="field-hint">
            {{ sections[0].rows.length }} active · {{ sections[1].rows.length }} upcoming · {{ sections[2].rows.length }} past
          </span>
          <IconBase name="chevron-right" :size="16" class="collapse-icon" :class="{ open: reservationsOpen }" />
        </button>

        <template v-if="reservationsOpen">
          <div v-for="s in sections" :key="s.key" style="margin-top: 14px">
            <h3 class="sub-title">{{ s.label }} <span class="badge-mini" v-if="s.rows.length">{{ s.rows.length }}</span></h3>
            <p v-if="s.rows.length === 0" class="empty-note">None.</p>
            <div v-else style="display: flex; flex-direction: column; gap: 8px">
              <button v-for="r in s.rows" :key="r.id" class="card-flat res-row" @click="openReservation(r)">
                <div style="flex: 1; min-width: 0; text-align: left">
                  <div class="chip-row" style="gap: 6px">
                    <span class="staff-row-name compact">{{ r.reservation_name }}</span>
                    <span v-if="r.crewRole" class="badge violet">Crew: {{ r.crewRole }}</span>
                    <span v-else-if="r.is_group_reservation" class="badge violet">Group</span>
                    <span v-if="r.is_capstone" class="badge accent">Capstone</span>
                  </div>
                  <div class="staff-row-sub">
                    {{ scheduleLine(r) }} · {{ r.locations?.name ?? '—' }}
                    <template v-if="r.crewRole && r.student"> · held by {{ r.student.full_name }}</template>
                  </div>
                  <div class="field-hint">{{ itemSummary(r) }}</div>
                </div>
                <span class="badge" :class="toneForReservationStatus(r.status)">{{ reservationStatusLabel(r.status) }}</span>
              </button>
            </div>
          </div>
        </template>
      </section>

      <!-- ============ Fines ============ -->
      <section class="card section">
        <div style="display: flex; justify-content: space-between; align-items: center; gap: 10px; flex-wrap: wrap">
          <h2 class="section-title" style="margin: 0">Fines</h2>
          <button v-if="!issuing" class="btn small" @click="issuing = true; clearMsg('fine')">Add a fine…</button>
        </div>
        <p v-if="msg.fine" class="info-note">{{ msg.fine }}</p>

        <div v-if="issuing" class="card-flat" style="display: flex; flex-direction: column; gap: 10px; margin-top: 10px">
          <div class="field-row">
            <div class="field">
              <label>Type</label>
              <select v-model="fineType">
                <option value="damage">Damage</option>
                <option value="missing">Missing equipment</option>
                <option value="other">Other</option>
              </select>
            </div>
            <div class="field">
              <label>Amount ($)</label>
              <input v-model.number="fineAmount" type="number" min="0.01" step="0.01" />
            </div>
          </div>
          <div class="field">
            <label>Reservation (optional)</label>
            <select v-model="fineReservation">
              <option :value="null">— Not tied to a reservation —</option>
              <option v-for="r in reservations" :key="r.id" :value="r.id">
                {{ r.reservation_name }} ({{ formatDate(r.pickup_date) }})
              </option>
            </select>
          </div>
          <div class="field">
            <label>What is it for?</label>
            <textarea v-model="fineDescription" rows="2" placeholder="e.g. Cracked lens hood on Sony ZV-E10 #4" />
          </div>
          <span class="field-hint">Late-return fines are added at return check-in, so they aren’t listed here.</span>
          <p v-if="err.fine" class="error-note">{{ err.fine }}</p>
          <div class="row-actions">
            <button class="btn small primary" :disabled="busy.fine" @click="issueFine">{{ busy.fine ? 'Adding…' : 'Add fine' }}</button>
            <button class="btn small ghost" @click="issuing = false">Cancel</button>
          </div>
        </div>

        <div style="margin-top: 12px">
          <FineList :user-id="user.id" :refresh-key="fineRefresh" />
        </div>
      </section>

      <!-- ============ Notes & strikes ============ -->
      <section class="card section">
        <h2 class="section-title">Staff notes & strikes</h2>
        <div class="field">
          <textarea v-model="noteText" rows="2" placeholder="Add a note…" />
        </div>
        <div class="row-actions">
          <label class="check-label"><input v-model="noteIsStrike" type="checkbox" /> Count as a strike</label>
          <select v-if="noteIsStrike" v-model="strikeReason" class="inline-input" aria-label="Strike reason">
            <option value="late_return">Late return</option>
            <option value="damage">Damage</option>
            <option value="behavioral">Behavioral</option>
          </select>
          <button class="btn small primary" :disabled="busy.notes" @click="addNote">
            {{ busy.notes ? 'Adding…' : noteIsStrike ? 'Add strike' : 'Add note' }}
          </button>
        </div>
        <p v-if="noteIsStrike && (profile?.strike_count ?? 0) >= 2 && !profile?.is_blocked" class="field-hint" style="color: var(--crit)">
          This will be strike {{ (profile?.strike_count ?? 0) + 1 }}, which blocks the account automatically.
        </p>
        <p v-if="msg.notes" class="info-note">{{ msg.notes }}</p>
        <p v-if="err.notes" class="error-note">{{ err.notes }}</p>

        <p v-if="notes.length === 0" class="empty-note" style="margin-top: 10px">No notes yet.</p>
        <div v-for="n in notes" :key="n.id" class="note-item">
          <div class="chip-row" style="gap: 6px">
            <span v-if="n.is_strike" class="strike-tag">Strike · {{ STRIKE_LABELS[n.strike_reason ?? ''] ?? n.strike_reason }}</span>
            <span class="field-hint">{{ formatDate(n.created_at) }} · {{ names[n.author_id] ?? 'Staff' }}</span>
          </div>
          <div style="margin-top: 4px; white-space: pre-wrap">{{ n.note_text }}</div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.back-link {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 13px;
  color: var(--ink-3);
  text-decoration: none;
}
.back-link:hover {
  color: var(--accent);
}
.user-head {
  display: flex;
  gap: 14px;
  align-items: center;
}
.crew-avatar.big {
  width: 52px;
  height: 52px;
  font-size: 20px;
}
.section {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.row-actions {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
}
.inline-input {
  padding: 7px 10px;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--surface);
  color: var(--ink);
  font: inherit;
  font-size: 13px;
  min-width: 220px;
}
.status-block {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  padding: 10px 0;
  border-top: 1px solid var(--border);
}
.check-label {
  display: inline-flex;
  gap: 6px;
  align-items: center;
  font-size: 13px;
}
.collapse-head {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  color: inherit;
  font: inherit;
  text-align: left;
}
.collapse-head .field-hint {
  flex: 1;
}
.collapse-icon {
  transition: transform 0.15s;
}
.collapse-icon.open {
  transform: rotate(90deg);
}
.sub-title {
  font-size: 13.5px;
  margin: 0 0 8px;
}
.res-row {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  width: 100%;
  cursor: pointer;
  font: inherit;
  color: inherit;
  border: 1px solid var(--border);
}
.res-row:hover {
  border-color: var(--accent);
}
textarea {
  width: 100%;
  resize: vertical;
}
</style>
