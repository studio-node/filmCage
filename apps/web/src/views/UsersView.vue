<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { errorMessage } from '../lib/errors'
import { roleLabel, one, formatMoney } from '../lib/format'
import FineList from '../components/FineList.vue'

// Staff+ Users page (11/18). Two tabs, same shell and query-param tab
// sync as Inventory Management:
//   - Users: everyone with an account, searchable/filterable; a row
//     opens that person's page (UserDetailView.vue).
//   - Fine Resolution: every fine across all users (FineList.vue).

type Tab = 'users' | 'fines'

interface ProfileBits {
  tier: string | null
  strike_count: number
  is_blocked: boolean
  checkout_suspended: boolean
  needs_tier_reconfirmation: boolean | null
}
interface UserRow {
  id: string
  full_name: string | null
  email: string
  role: string
  is_active: boolean
  user_profiles: ProfileBits | ProfileBits[] | null
}

const route = useRoute()
const router = useRouter()
const activeTab = ref<Tab>(route.query.tab === 'fines' ? 'fines' : 'users')
watch(activeTab, (tab) => {
  if (route.query.tab !== tab) router.replace({ query: { ...route.query, tab } })
})
watch(
  () => route.query.tab,
  (tab) => {
    const next: Tab = tab === 'fines' ? 'fines' : 'users'
    if (next !== activeTab.value) activeTab.value = next
  }
)

const loading = ref(true)
const error = ref('')
const users = ref<UserRow[]>([])
const owed = ref<Record<string, number>>({})
const search = ref('')
const roleFilter = ref<string>('all')
const flagFilter = ref<'all' | 'fines' | 'blocked' | 'inactive'>('all')

async function load() {
  loading.value = true
  error.value = ''
  try {
    const [usersRes, finesRes] = await Promise.all([
      supabase
        .from('users')
        .select(
          'id, full_name, email, role, is_active, user_profiles!user_profiles_user_id_fkey(tier, strike_count, is_blocked, checkout_suspended, needs_tier_reconfirmation)'
        )
        .order('full_name'),
      supabase.from('fines_with_amount').select('student_id, current_amount').neq('status', 'resolved'),
    ])
    if (usersRes.error) throw usersRes.error
    if (finesRes.error) throw finesRes.error
    users.value = (usersRes.data ?? []) as unknown as UserRow[]
    const totals: Record<string, number> = {}
    for (const f of (finesRes.data ?? []) as { student_id: string; current_amount: number }[]) {
      totals[f.student_id] = (totals[f.student_id] ?? 0) + Number(f.current_amount)
    }
    owed.value = totals
  } catch (e) {
    error.value = errorMessage(e, 'Could not load users.')
  } finally {
    loading.value = false
  }
}
load()

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  return users.value.filter((u) => {
    const p = one(u.user_profiles)
    if (roleFilter.value !== 'all' && u.role !== roleFilter.value) return false
    if (flagFilter.value === 'fines' && !owed.value[u.id]) return false
    if (flagFilter.value === 'blocked' && !(p?.is_blocked || p?.checkout_suspended)) return false
    if (flagFilter.value === 'inactive' && u.is_active) return false
    if (q && !`${u.full_name ?? ''} ${u.email}`.toLowerCase().includes(q)) return false
    return true
  })
})

function open(u: UserRow) {
  router.push({ name: 'user-detail', params: { id: u.id } })
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Staff+ tools</span>
        <h1>Users</h1>
        <p class="view-desc">Look up anyone with an account, see their reservations and fines, and resolve fines.</p>
      </div>
    </div>

    <div class="tabs">
      <button class="tab" :class="{ active: activeTab === 'users' }" @click="activeTab = 'users'">Users</button>
      <button class="tab" :class="{ active: activeTab === 'fines' }" @click="activeTab = 'fines'">Fine Resolution</button>
    </div>

    <template v-if="activeTab === 'users'">
      <div class="user-filters">
        <input v-model="search" type="search" placeholder="Search by name or email" aria-label="Search users" />
        <select v-model="roleFilter" aria-label="Filter by role">
          <option value="all">All roles</option>
          <option value="student">Students</option>
          <option value="class_instructor">Class instructors</option>
          <option value="staff">Staff</option>
          <option value="supervisor">Supervisors</option>
          <option value="admin">Admins</option>
        </select>
        <div class="chip-row">
          <button class="chip" :class="{ active: flagFilter === 'all' }" @click="flagFilter = 'all'">Everyone</button>
          <button class="chip" :class="{ active: flagFilter === 'fines' }" @click="flagFilter = 'fines'">Owes fines</button>
          <button class="chip" :class="{ active: flagFilter === 'blocked' }" @click="flagFilter = 'blocked'">Blocked / suspended</button>
          <button class="chip" :class="{ active: flagFilter === 'inactive' }" @click="flagFilter = 'inactive'">Deactivated</button>
        </div>
      </div>

      <p v-if="loading" class="empty-note">Loading users…</p>
      <p v-else-if="error" class="error-note">{{ error }}</p>
      <p v-else-if="filtered.length === 0" class="empty-note">No one matches.</p>

      <div v-else class="user-list">
        <button v-for="u in filtered" :key="u.id" class="card user-row" @click="open(u)">
          <div class="crew-avatar">{{ (u.full_name || u.email).slice(0, 1).toUpperCase() }}</div>
          <div style="flex: 1; min-width: 0; text-align: left">
            <div class="staff-row-name compact">{{ u.full_name || u.email }}</div>
            <div class="staff-row-sub">{{ u.email }}</div>
          </div>
          <div class="user-badges">
            <span class="badge neutral">{{ roleLabel(u.role) }}</span>
            <span v-if="one(u.user_profiles)?.tier" class="badge muted" style="text-transform: capitalize">
              {{ one(u.user_profiles)?.tier }}
            </span>
            <span v-if="!u.is_active" class="badge muted">Deactivated</span>
            <span v-if="one(u.user_profiles)?.is_blocked" class="badge crit">Blocked</span>
            <span v-else-if="one(u.user_profiles)?.checkout_suspended" class="badge warn">Suspended</span>
            <span v-if="(one(u.user_profiles)?.strike_count ?? 0) > 0" class="badge warn">
              {{ one(u.user_profiles)?.strike_count }} strike{{ one(u.user_profiles)?.strike_count === 1 ? '' : 's' }}
            </span>
            <span v-if="owed[u.id]" class="badge crit">Owes {{ formatMoney(owed[u.id]) }}</span>
          </div>
        </button>
      </div>
    </template>

    <FineList v-else @changed="load" />
  </div>
</template>

<style scoped>
.user-filters {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  align-items: center;
}
.user-filters input,
.user-filters select {
  padding: 8px 10px;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--surface);
  color: var(--ink);
  font: inherit;
  font-size: 13.5px;
}
.user-filters input {
  flex: 1;
  min-width: 220px;
}
.user-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.user-row {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  cursor: pointer;
  font: inherit;
  color: inherit;
  text-align: left;
}
.user-row:hover {
  border-color: var(--accent);
}
.user-badges {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  justify-content: flex-end;
}
@media (max-width: 640px) {
  .user-row {
    flex-wrap: wrap;
  }
  .user-badges {
    justify-content: flex-start;
    width: 100%;
  }
}
</style>
