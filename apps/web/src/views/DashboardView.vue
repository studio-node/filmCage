<script setup lang="ts">
import { computed, ref, watch } from 'vue'
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
// whether the new class's mapped tier actually takes effect.
interface PendingTierChange {
  user_id: string
  tier: 'beginner' | 'intermediate' | 'advanced' | null
  class_taken: string | null
  users: { full_name: string; email: string } | null
  course_tier_mappings: {
    course_name: string
    course_code: string | null
    tier: 'beginner' | 'intermediate' | 'advanced'
  } | null
}

const auth = useAuthStore()
const loading = ref(true)
const error = ref('')

const profile = ref<StudentProfile | null>(null)
const fines = ref<FineRow[]>([])
const reservations = ref<ReservationRow[]>([])
const notifications = ref<NotificationRow[]>([])

const pendingTierChanges = ref<PendingTierChange[]>([])
const loadingStaff = ref(false)
const staffError = ref('')
const tierActionBusyId = ref<string | null>(null)
const tierActionError = ref('')
const STAFF_PLUS_ROLES = ['staff', 'supervisor', 'admin']

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
}

async function loadStaffDashboard() {
  loadingStaff.value = true
  staffError.value = ''
  try {
    const { data, error } = await supabase
      .from('user_profiles')
      .select(
        'user_id, tier, class_taken, users!user_profiles_user_id_fkey(full_name, email), course_tier_mappings!user_profiles_class_taken_fkey(course_name, course_code, tier)'
      )
      .eq('needs_tier_reconfirmation', true)
    if (error) throw error
    pendingTierChanges.value = (data ?? []) as unknown as PendingTierChange[]
  } catch (e) {
    staffError.value = errorMessage(e, 'Could not load pending tier changes.')
  } finally {
    loadingStaff.value = false
  }
}

async function confirmTierChange(row: PendingTierChange) {
  const newTier = row.course_tier_mappings?.tier
  if (!newTier) return
  tierActionError.value = ''
  tierActionBusyId.value = row.user_id
  try {
    const { error } = await supabase
      .from('user_profiles')
      .update({ tier: newTier, needs_tier_reconfirmation: false })
      .eq('user_id', row.user_id)
    if (error) throw error
    pendingTierChanges.value = pendingTierChanges.value.filter((r) => r.user_id !== row.user_id)
  } catch (e) {
    tierActionError.value = errorMessage(e, 'Could not confirm this tier change.')
  } finally {
    tierActionBusyId.value = null
  }
}

async function dismissTierChange(row: PendingTierChange) {
  tierActionError.value = ''
  tierActionBusyId.value = row.user_id
  try {
    const { error } = await supabase
      .from('user_profiles')
      .update({ needs_tier_reconfirmation: false })
      .eq('user_id', row.user_id)
    if (error) throw error
    pendingTierChanges.value = pendingTierChanges.value.filter((r) => r.user_id !== row.user_id)
  } catch (e) {
    tierActionError.value = errorMessage(e, 'Could not dismiss this request.')
  } finally {
    tierActionBusyId.value = null
  }
}

// This dashboard is the student view — checkouts, fines, and
// reservations all scoped to the signed-in student. Staff/supervisor/
// admin get a lightweight placeholder for the rest (queue to approve,
// items overdue org-wide, etc. — a later phase), but now see real
// pending tier-change requests above it (see ProfileDrawer.vue —
// self-service class editing never moves tier itself, only flags the
// account here for review).
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
          The full staff/admin dashboard (approval queue, org-wide checkout status, analytics) is
          coming in a later build phase. For now, use Browse Equipment to see the live catalog.
        </p>
      </div>

      <div v-if="auth.role && ['staff', 'supervisor', 'admin'].includes(auth.role)" class="card">
        <div class="section-title" style="margin-bottom: 2px">Pending tier changes</div>
        <p class="field-hint" style="margin-bottom: 12px">
          Students who changed their class on their own profile — their tier stays put until you
          confirm or dismiss it here.
        </p>
        <p v-if="loadingStaff">Loading…</p>
        <p v-else-if="staffError" class="error-note">{{ staffError }}</p>
        <p v-else-if="pendingTierChanges.length === 0" class="empty-note">Nothing pending.</p>
        <div v-else style="display: flex; flex-direction: column; gap: 10px">
          <p v-if="tierActionError" class="error-note">{{ tierActionError }}</p>
          <div v-for="row in pendingTierChanges" :key="row.user_id" class="card-flat" style="display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap">
            <div>
              <div style="font-weight: 600">{{ row.users?.full_name ?? 'Unknown student' }}</div>
              <div class="field-hint">{{ row.users?.email }}</div>
              <div style="margin-top: 4px; font-size: 12.5px">
                Took
                <strong>{{ row.course_tier_mappings?.course_code ?? row.course_tier_mappings?.course_name ?? '—' }}</strong>
                — currently
                <span class="badge violet" style="text-transform: capitalize">{{ row.tier }} tier</span>
                → requests
                <span class="badge accent" style="text-transform: capitalize">{{ row.course_tier_mappings?.tier ?? '?' }} tier</span>
              </div>
            </div>
            <div style="display: flex; gap: 6px">
              <button
                class="btn ghost small"
                :disabled="tierActionBusyId === row.user_id"
                @click="dismissTierChange(row)"
              >
                Dismiss
              </button>
              <button
                class="btn primary small"
                :disabled="tierActionBusyId === row.user_id || !row.course_tier_mappings"
                @click="confirmTierChange(row)"
              >
                {{ tierActionBusyId === row.user_id ? 'Saving…' : `Confirm → ${row.course_tier_mappings?.tier ?? '?'}` }}
              </button>
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
</style>
