import { createRouter, createWebHistory } from 'vue-router'
import LoginView from '../views/LoginView.vue'
import AppShell from '../components/AppShell.vue'
import DashboardView from '../views/DashboardView.vue'
import BrowseEquipmentView from '../views/BrowseEquipmentView.vue'
import AdminAddItemView from '../views/AdminAddItemView.vue'
import { useAuthStore } from '../stores/auth'

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
  // this link from non-admins, but RLS is what actually stops a write;
  // this just keeps a non-admin from landing on the page via a typed
  // URL and hitting a wall of insert errors instead of a clean redirect.
  if (to.name === 'admin' && auth.role !== 'admin') {
    return { name: 'dashboard' }
  }
})

export default router
