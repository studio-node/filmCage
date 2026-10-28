<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore, type CatalogItem } from '../stores/catalog'
import { supabase } from '../lib/supabaseClient'
import ProfileDrawer from './ProfileDrawer.vue'

interface NavItem {
  key: string
  label: string
  routeName: string | null // null = not built yet
  roles: Array<'student' | 'staff' | 'supervisor' | 'admin' | 'class_instructor'>
  icon: 'grid' | 'box' | 'calendar' | 'list' | 'inbox' | 'truck' | 'chart' | 'shield'
}

const ALL_ROLES: NavItem['roles'] = ['student', 'staff', 'supervisor', 'admin', 'class_instructor']

const NAV_ITEMS: NavItem[] = [
  { key: 'dashboard', label: 'Dashboard', routeName: 'dashboard', roles: ALL_ROLES, icon: 'grid' },
  { key: 'browse', label: 'Browse Equipment', routeName: 'browse', roles: ALL_ROLES, icon: 'box' },
  { key: 'calendar', label: 'New Reservation', routeName: 'new-reservation', roles: ALL_ROLES, icon: 'calendar' },
  { key: 'reservations', label: 'My Reservations', routeName: 'reservations', roles: ALL_ROLES, icon: 'list' },
  { key: 'reservation-queue', label: 'Reservation Queue', routeName: 'reservation-queue', roles: ['staff', 'supervisor', 'admin'], icon: 'inbox' },
  { key: 'pickup', label: 'Pickup / Return', routeName: null, roles: ['staff', 'supervisor', 'admin'], icon: 'truck' },
  { key: 'analytics', label: 'Analytics', routeName: null, roles: ['staff', 'supervisor', 'admin'], icon: 'chart' },
  { key: 'admin', label: 'Add Items', routeName: 'admin', roles: ['staff', 'supervisor', 'admin'], icon: 'shield' },
  { key: 'admin-edit', label: 'Edit Items', routeName: 'admin-edit', roles: ['staff', 'supervisor', 'admin'], icon: 'shield' },
]

const auth = useAuthStore()
const catalog = useCatalogStore()
const router = useRouter()
const route = useRoute()
const sidebarOpen = ref(false)
const profileOpen = ref(false)

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

// --- global equipment search --------------------------------------
// The search box up here and the one on the Browse Equipment page
// both read/write catalog.query, so typing in either one filters the
// same underlying list — there's really just one search, shown in
// two places, same as the mockup's single global search state.
const showSuggestions = ref(false)
const highlighted = ref(-1)

const suggestions = computed(() => catalog.search(catalog.query, 8))

function focusSearch() {
  catalog.ensureLoaded()
  showSuggestions.value = true
}
function onSearchInput() {
  showSuggestions.value = true
  highlighted.value = -1
  if (catalog.query.trim() && route.name !== 'browse') {
    router.push({ name: 'browse' })
  }
}
// A plain window.setTimeout, same pattern as the crew-search
// autocomplete in NewReservationView.vue — delaying the hide lets a
// mousedown on a suggestion register before blur would otherwise
// yank the dropdown away.
function hideSuggestionsSoon() {
  setTimeout(() => {
    showSuggestions.value = false
  }, 150)
}
function goToBrowse() {
  showSuggestions.value = false
  if (route.name !== 'browse') router.push({ name: 'browse' })
}
function pickSuggestion(item: CatalogItem) {
  showSuggestions.value = false
  highlighted.value = -1
  catalog.query = item.name
  catalog.pendingOpenItemId = item.id
  if (route.name !== 'browse') router.push({ name: 'browse' })
}
function clearSearch() {
  catalog.query = ''
  showSuggestions.value = false
}
function moveHighlight(delta: number) {
  if (!showSuggestions.value) {
    showSuggestions.value = true
    return
  }
  const max = suggestions.value.length
  if (max === 0) return
  highlighted.value = (highlighted.value + delta + max) % max
}
function confirmHighlighted() {
  const picked = highlighted.value >= 0 ? suggestions.value[highlighted.value] : undefined
  if (picked) {
    pickSuggestion(picked.item)
  } else {
    goToBrowse()
  }
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

      <div class="global-search autocomplete-wrap">
        <span aria-hidden="true">🔍</span>
        <input
          v-model="catalog.query"
          type="text"
          placeholder="Search equipment, kits, locations…"
          @input="onSearchInput"
          @focus="focusSearch"
          @blur="hideSuggestionsSoon"
          @keydown.down.prevent="moveHighlight(1)"
          @keydown.up.prevent="moveHighlight(-1)"
          @keydown.enter.prevent="confirmHighlighted"
          @keydown.esc="showSuggestions = false"
        />
        <button
          v-if="catalog.query"
          type="button"
          class="icon-btn"
          style="width: 22px; height: 22px; border: none; background: none"
          aria-label="Clear search"
          @mousedown.prevent="clearSearch"
        >
          ✕
        </button>
        <div v-if="showSuggestions && catalog.query.trim()" class="autocomplete-list">
          <div
            v-for="(r, i) in suggestions"
            :key="r.item.id"
            class="autocomplete-item"
            :class="{ 'autocomplete-item--active': i === highlighted }"
            @mousedown.prevent="pickSuggestion(r.item)"
          >
            <strong>{{ r.item.name }}</strong>
            <span v-if="r.item.brand || r.item.model" style="color: var(--ink-3)">
              — {{ r.item.brand }} {{ r.item.model }}
            </span>
          </div>
          <div v-if="suggestions.length === 0" class="autocomplete-item" style="cursor: default; color: var(--ink-3)">
            No equipment matches "{{ catalog.query.trim() }}" — showing the full catalog filter instead.
          </div>
        </div>
      </div>

      <div class="topbar-right">
        <button class="icon-btn" aria-label="Notifications" title="Notifications">
          🔔
          <span v-if="unreadCount > 0" class="dot"></span>
        </button>
        <button
          class="avatar"
          type="button"
          style="cursor: pointer"
          :title="`${auth.fullName || auth.user?.email || ''} — edit profile`"
          aria-label="Your profile"
          @click="profileOpen = true"
        >
          {{ initials }}
        </button>
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

    <ProfileDrawer :open="profileOpen" @close="profileOpen = false" />
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
.autocomplete-item--active {
  background: var(--accent-soft);
}
</style>
