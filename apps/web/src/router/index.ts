import { createRouter, createWebHistory } from 'vue-router'
import LoginView from '../views/LoginView.vue'
import AppShell from '../components/AppShell.vue'
import DashboardView from '../views/DashboardView.vue'
import BrowseEquipmentView from '../views/BrowseEquipmentView.vue'
import AdminAddItemView from '../views/AdminAddItemView.vue'
import EditItemsView from '../views/EditItemsView.vue'
import { useAuthStore } from '../stores/auth'

const INVENTORY_ROUTE_NAMES = new Set(['admin', 'admin-edit'])
const INVENTORY_ROLES = new Set(['staff', 'supervisor', 'admin'])

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: LoginView },
    {
      path: '/',
      component: AppShell,
      children: [
        { path: '', redirect: { name: 'dashboard' } },
        { path: 'dashboard', name: 'dashboard', component: DashboardView },
        { path: 'browse', name: 'browse', component: BrowseEquipmentView },
        { path: 'admin', name: 'admin', component: AdminAddItemView },
        { path: 'admin/items', name: 'admin-edit', component: EditItemsView },
      ],
    },
  ],
})

// auth.init() (see main.ts) always resolves before the router is
// installed, so auth.user is already settled by the first navigation —
// no need to await anything here.
router.beforeEach((to) => {
  const auth = useAuthStore()
  if (to.name !== 'login' && !auth.user) {
    return { name: 'login' }
  }
  if (to.name === 'login' && auth.user) {
    return { name: 'dashboard' }
  }
  // Route-level guard as defense in depth — the sidebar already hides
  // these links from unauthorized roles, but RLS is what actually stops
  // a write; this just keeps someone from landing on the page via a
  // typed URL and hitting a wall of insert errors instead of a clean
  // redirect. Staff, supervisor, and admin all get these screens — the
  // underlying RLS policies on item_models/item_units already allow all
  // three roles to write, so the UI now matches what the database permits.
  if (typeof to.name === 'string' && INVENTORY_ROUTE_NAMES.has(to.name) && !INVENTORY_ROLES.has(auth.role ?? '')) {
    return { name: 'dashboard' }
  }
})

export default router
