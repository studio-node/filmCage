<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { supabase } from '../lib/supabaseClient'

interface NavItem {
  key: string
  label: string
  routeName: string | null // null = not built yet
  roles: Array<'student' | 'staff' | 'supervisor' | 'admin' | 'professor'>
  icon: 'grid' | 'box' | 'calendar' | 'list' | 'truck' | 'chart' | 'shield'
}

const ALL_ROLES: NavItem['roles'] = ['student', 'staff', 'supervisor', 'admin', 'professor']

const NAV_ITEMS: NavItem[] = [
  { key: 'dashboard', label: 'Dashboard', routeName: 'dashboard', roles: ALL_ROLES, icon: 'grid' },
  { key: 'browse', label: 'Browse Equipment', routeName: 'browse', roles: ALL_ROLES, icon: 'box' },
  { key: 'reservations', label: 'My Reservations', routeName: null, roles: ALL_ROLES, icon: 'list' },
  { key: 'calendar', label: 'Calendar', routeName: null, roles: ALL_ROLES, icon: 'calendar' },
  { key: 'pickup', label: 'Pickup / Return', routeName: null, roles: ['staff', 'supervisor', 'admin'], icon: 'truck' },
  { key: 'analytics', label: 'Analytics', routeName: null, roles: ['staff', 'supervisor', 'admin'], icon: 'chart' },
  { key: 'admin', label: 'Admin', routeName: null, roles: ['admin'], icon: 'shield' },
]

const auth = useAuthStore()
const router = useRouter()
const sidebarOpen = ref(false)

const visibleNav = computed(() =>
  NAV_ITEMS.filter((item) => !auth.role || item.roles.includes(auth.role))
)

const initials = computed(() => {
  const name = auth.fullName || auth.user?.email || ''
  const parts = name.trim().split(/\s+/)
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase()
  return name.slice(0, 2).toUpperCase()
})

const unreadCount = ref(0)

async function loadUnreadCount() {
  if (!auth.user) return
  const { count } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', auth.user.id)
    .eq('is_read', false)
  unreadCount.value = count ?? 0
}
loadUnreadCount()

async function handleSignOut() {
  await auth.signOut()
  router.push({ name: 'login' })
}
</script>

<template>
  <div id="app">
    <header class="topbar">
      <button class="icon-btn nav-toggle-mobile" style="display: none" @click="sidebarOpen = !sidebarOpen" aria-label="Toggle navigation">
        ☰
      </button>
      <div class="brand">
        <span class="brand-mark">FC</span>
        <span>The Film Cage</span>
        <span class="brand-sub">Film Dept</span>
      </div>

      <div class="global-search">
        <span aria-hidden="true">🔍</span>
        <input type="text" placeholder="Search equipment… (coming soon)" disabled />
      </div>

      <div class="topbar-right">
        <button class="icon-btn" aria-label="Notifications" title="Notifications">
          🔔
          <span v-if="unreadCount > 0" class="dot"></span>
        </button>
        <span class="avatar" :title="auth.fullName || auth.user?.email || ''">{{ initials }}</span>
        <button class="btn ghost small" @click="handleSignOut">Sign out</button>
      </div>
    </header>

    <div class="shell">
      <aside class="sidebar" :class="{ open: sidebarOpen }">
        <nav class="nav-group">
          <div class="nav-group-label">Menu</div>
          <router-link
            v-for="item in visibleNav"
            :key="item.key"
            :to="item.routeName ? { name: item.routeName } : '#'"
            class="nav-item"
            :class="{ 'nav-item--disabled': !item.routeName }"
            @click="!item.routeName && $event.preventDefault()"
          >
            <span>{{ item.label }}</span>
            <span v-if="!item.routeName" class="badge-mini">soon</span>
          </router-link>
        </nav>
        <div class="sidebar-foot">
          The Film Cage — Utah Tech Film Dept equipment checkout.
        </div>
      </aside>

      <main class="content">
        <router-view />
      </main>
    </div>
  </div>
</template>

<style scoped>
.nav-item--disabled {
  cursor: default;
  opacity: 0.55;
}
.nav-item--disabled:hover {
  background: none;
  color: var(--ink-2);
}
</style>
