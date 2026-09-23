<script setup lang="ts">
import { ref, watch } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'

interface ItemModel {
  id: string
  name: string
  brand: string | null
  model: string | null
  min_tier: string
}

const auth = useAuthStore()
const items = ref<ItemModel[]>([])
const loading = ref(false)
const error = ref('')

async function loadCatalog() {
  loading.value = true
  error.value = ''
  const { data, error: fetchError } = await supabase
    .from('item_models')
    .select('id, name, brand, model, min_tier')
    .order('name')
  if (fetchError) {
    error.value = fetchError.message
  } else {
    items.value = data ?? []
  }
  loading.value = false
}

watch(
  () => auth.user,
  (user) => {
    if (user) loadCatalog()
    else items.value = []
  },
  { immediate: true }
)
</script>

<template>
  <main class="catalog">
    <header>
      <h1>Equipment Catalog</h1>
      <p v-if="auth.user">
        Signed in as {{ auth.user.email }}
        <span v-if="auth.role"> — role: {{ auth.role }}</span>
        <button @click="auth.signOut()">Sign out</button>
      </p>
      <p v-else><router-link to="/login">Sign in</router-link> to see the catalog — browsing requires an authenticated session per the RLS policy.</p>
    </header>

    <p v-if="loading">Loading equipment…</p>
    <p v-else-if="error" class="error">
      Couldn't load the catalog: {{ error }}
      <br />
      (Check that VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are set in .env.local, and that the
      schema migration has been pushed to your Supabase project.)
    </p>
    <p v-else-if="auth.user && items.length === 0">
      Connected successfully — there's just nothing in <code>item_models</code> yet to show.
    </p>
    <ul v-else-if="items.length > 0" class="items">
      <li v-for="item in items" :key="item.id">
        <strong>{{ item.name }}</strong>
        <span v-if="item.brand || item.model"> — {{ item.brand }} {{ item.model }}</span>
        <span class="tier">min tier: {{ item.min_tier }}</span>
      </li>
    </ul>
  </main>
</template>

<style scoped>
.catalog {
  max-width: 640px;
  margin: 2rem auto;
  font-family: system-ui, sans-serif;
  padding: 0 1rem;
}
.items {
  list-style: none;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.items li {
  border: 1px solid #ddd;
  border-radius: 6px;
  padding: 0.75rem;
  display: flex;
  justify-content: space-between;
}
.tier {
  color: #666;
  font-size: 0.85rem;
}
.error {
  color: #b3261e;
}
</style>
