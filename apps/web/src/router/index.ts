import { createRouter, createWebHistory } from 'vue-router'
import LoginView from '../views/LoginView.vue'
import CatalogView from '../views/CatalogView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/catalog' },
    { path: '/login', name: 'login', component: LoginView },
    { path: '/catalog', name: 'catalog', component: CatalogView },
  ],
})

export default router
