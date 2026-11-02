import { createRouter, createWebHashHistory } from 'vue-router'
import LoginView from '../views/LoginView.vue'
import AppShell from '../components/AppShell.vue'
import DashboardView from '../views/DashboardView.vue'
import BrowseEquipmentView from '../views/BrowseEquipmentView.vue'
import NewReservationView from '../views/NewReservationView.vue'
import MyReservationsView from '../views/MyReservationsView.vue'
import ReservationQueueView from '../views/ReservationQueueView.vue'
import ReservationDetailView from '../views/ReservationDetailView.vue'
import AdminAddItemView from '../views/AdminAddItemView.vue'
import EditItemsView from '../views/EditItemsView.vue'
import PickupReturnView from '../views/PickupReturnView.vue'
import PickupCheckoutView from '../views/PickupCheckoutView.vue'
import { useAuthStore } from '../stores/auth'

const INVENTORY_ROUTE_NAMES = new Set(['admin', 'admin-edit'])
const INVENTORY_ROLES = new Set(['staff', 'supervisor', 'admin'])
const STAFF_ROUTE_NAMES = new Set(['reservation-queue'])
const STAFF_ROLES = new Set(['staff', 'supervisor', 'admin'])

const router = createRouter({
  // Hash routing: GitHub Pages has no server-side rewrites, so a refresh on a
  // clean URL like /reservations would 404. Hash URLs (/#/reservations) always work.
  history: createWebHashHistory(import.meta.env.BASE_URL),
  routes: [
    { path: '/login', name: 'login', component: LoginView },
    {
      path: '/',
      component: AppShell,
      children: [
        { path: '', redirect: { name: 'dashboard' } },
        { path: 'dashboard', name: 'dashboard', component: DashboardView },
        { path: 'browse', name: 'browse', component: BrowseEquipmentView },
        { path: 'new-reservation', name: 'new-reservation', component: NewReservationView },
        { path: 'reservations', name: 'reservations', component: MyReservationsView },
        { path: 'reservations/:id', name: 'reservation-detail', component: ReservationDetailView },
        { path: 'reservation-queue', name: 'reservation-queue', component: ReservationQueueView },
        // Everyone gets these two -- pickup is done by the student/crew
        // themselves, mirrored by staff on the same per-reservation
        // screen, so there's no role gate here the way there is for
        // the Reservation Queue above.
        { path: 'pickup', name: 'pickup', component: PickupReturnView },
        { path: 'pickup/:id', name: 'pickup-checkout', component: PickupCheckoutView },
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
  // Same defense-in-depth pattern for the Reservation Queue — the RLS
  // update/delete policies on reservations are already staff+-only, so
  // a student hitting this URL directly would just get a wall of RLS
  // errors instead of a clean redirect.
  if (typeof to.name === 'string' && STAFF_ROUTE_NAMES.has(to.name) && !STAFF_ROLES.has(auth.role ?? '')) {
    return { name: 'dashboard' }
  }
})

export default router
