import { createApp } from 'vue'
import { createPinia, setActivePinia } from 'pinia'
import App from './App.vue'
import router from './router'
import './styles/main.css'
import { useAuthStore } from './stores/auth'

const app = createApp(App)

const pinia = createPinia()
setActivePinia(pinia)
app.use(pinia)

// Resolve the session before the first navigation runs, so the router
// guard (in ./router) never has to guess whether someone's signed in.
const auth = useAuthStore()
auth.init().finally(() => {
  app.use(router)
  app.mount('#app')
})
