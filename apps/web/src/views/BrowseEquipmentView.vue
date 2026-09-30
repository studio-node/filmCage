<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { useCartStore } from '../stores/cart'
import { toneForCondition, conditionLabel, type UnitCondition } from '../lib/conditionStatus'

interface Category {
  id: string
  name: string
  kind: 'direct' | 'general'
  display_order: number
}
interface Location {
  id: string
  name: string
}
interface ItemModel {
  id: string
  name: string
  brand: string | null
  model: string | null
  description: string | null
  purchase_price: number | null
  location_id: string
  direct_category_id: string | null
  general_category_id: string | null
  min_tier: 'beginner' | 'intermediate' | 'advanced'
}
interface UnitRow {
  id: string
  item_model_id: string
  unit_code: string
  condition: UnitCondition
  condition_note: string | null
  current_reservation_id: string | null
}

const TIER_RANK: Record<string, number> = { beginner: 0, intermediate: 1, advanced: 2 }
const AVAILABLE_CONDITIONS: UnitCondition[] = ['good', 'caution']

const auth = useAuthStore()
const cart = useCartStore()

const loading = ref(true)
const error = ref('')

const categories = ref<Category[]>([])
const locations = ref<Location[]>([])
const items = ref<ItemModel[]>([])
const unitsByModel = ref<Map<string, UnitRow[]>>(new Map())
const studentTier = ref<string | null>(null)

const directCategories = computed(() => categories.value.filter((c) => c.kind === 'direct'))
const generalCategories = computed(() => categories.value.filter((c) => c.kind === 'general'))

const categoryById = computed(() => new Map(categories.value.map((c) => [c.id, c])))
const locationById = computed(() => new Map(locations.value.map((l) => [l.id, l])))

// --- filters --------------------------------------------------------
const search = ref('')
const selectedDirect = reactive(new Set<string>())
const selectedGeneral = reactive(new Set<string>())
const selectedLocations = reactive(new Set<string>())

function toggle(set: Set<string>, id: string) {
  if (set.has(id)) set.delete(id)
  else set.add(id)
}

async function loadCatalog() {
  loading.value = true
  error.value = ''
  try {
    const [catRes, locRes, modelRes, unitRes] = await Promise.all([
      supabase.from('categories').select('id, name, kind, display_order').order('display_order'),
      supabase.from('locations').select('id, name').order('name'),
      supabase
        .from('item_models')
        .select(
          'id, name, brand, model, description, purchase_price, location_id, direct_category_id, general_category_id, min_tier'
        )
        .eq('is_active', true)
        .order('name'),
      supabase
        .from('item_units_with_status')
        .select('id, item_model_id, unit_code, condition, condition_note, current_reservation_id'),
    ])
    if (catRes.error) throw catRes.error
    if (locRes.error) throw locRes.error
    if (modelRes.error) throw modelRes.error
    if (unitRes.error) throw unitRes.error

    categories.value = catRes.data ?? []
    locations.value = locRes.data ?? []
    items.value = (modelRes.data ?? []) as ItemModel[]

    const grouped = new Map<string, UnitRow[]>()
    for (const u of (unitRes.data ?? []) as UnitRow[]) {
      const list = grouped.get(u.item_model_id) ?? []
      list.push(u)
      grouped.set(u.item_model_id, list)
    }
    unitsByModel.value = grouped

    if (auth.role === 'student' && auth.user) {
      const { data: profile } = await supabase
        .from('student_profiles')
        .select('tier')
        .eq('user_id', auth.user.id)
        .maybeSingle()
      studentTier.value = profile?.tier ?? null
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to load the catalog'
  } finally {
    loading.value = false
  }
}

watch(
  () => auth.user?.id,
  (userId) => {
    if (userId) loadCatalog()
  },
  { immediate: true }
)

function availability(modelId: string) {
  const units = unitsByModel.value.get(modelId) ?? []
  const available = units.filter(
    (u) => u.current_reservation_id === null && AVAILABLE_CONDITIONS.includes(u.condition)
  ).length
  return { total: units.length, available, units }
}

function availabilityTone(modelId: string): 'good' | 'warn' | 'crit' {
  const { total, available } = availability(modelId)
  if (available === 0) return 'crit'
  if (available < total) return 'warn'
  return 'good'
}

function isLocked(item: ItemModel) {
  if (auth.role !== 'student' || !studentTier.value) return false
  return TIER_RANK[studentTier.value] < TIER_RANK[item.min_tier]
}

const filteredItems = computed(() => {
  const q = search.value.trim().toLowerCase()
  return items.value.filter((item) => {
    if (selectedDirect.size > 0 && !(item.direct_category_id && selectedDirect.has(item.direct_category_id)))
      return false
    if (
      selectedGeneral.size > 0 &&
      !(item.general_category_id && selectedGeneral.has(item.general_category_id))
    )
      return false
    if (selectedLocations.size > 0 && !selectedLocations.has(item.location_id)) return false
    if (q) {
      const hay = `${item.name} ${item.brand ?? ''} ${item.model ?? ''}`.toLowerCase()
      if (!hay.includes(q)) return false
    }
    return true
  })
})

// --- drawer -----------------------------------------------------------
const activeItem = ref<ItemModel | null>(null)
const reserving = ref(false)
const formError = ref('')
const quantity = ref(1)

function openDrawer(item: ItemModel) {
  activeItem.value = item
  const { available } = availability(item.id)
  quantity.value = Math.min(1, available) || 1
  formError.value = ''
}
function closeDrawer() {
  activeItem.value = null
}

function addToCart() {
  if (!activeItem.value) return
  formError.value = ''
  const { available } = availability(activeItem.value.id)
  if (quantity.value < 1 || quantity.value > available) {
    formError.value = `Quantity must be between 1 and ${available} (what's currently available).`
    return
  }
  const location = locationById.value.get(activeItem.value.location_id)
  const rejection = cart.addItem(
    {
      id: activeItem.value.id,
      name: activeItem.value.name,
      locationId: activeItem.value.location_id,
      locationName: location?.name ?? 'this location',
    },
    quantity.value,
    available
  )
  if (rejection) {
    formError.value = rejection
    return
  }
  pushToast(`Added ${quantity.value} × ${activeItem.value.name} to your reservation.`)
  closeDrawer()
}

async function joinWaitlist() {
  if (!activeItem.value || !auth.user) return
  formError.value = ''
  reserving.value = true
  try {
    const { data: resv, error: rErr } = await supabase
      .from('reservations')
      .insert({
        reservation_name: `${activeItem.value.name} (waitlist)`,
        student_id: auth.user.id,
        location_id: activeItem.value.location_id,
        created_by: auth.user.id,
      })
      .select('id')
      .single()
    if (rErr) throw rErr

    const { error: iErr } = await supabase.from('reservation_items').insert({
      reservation_id: resv.id,
      item_model_id: activeItem.value.id,
      quantity: 1,
    })
    if (iErr) throw iErr

    const { error: wErr } = await supabase.rpc('add_to_waitlist', {
      p_reservation_id: resv.id,
      p_item_model_id: activeItem.value.id,
      p_student_id: auth.user.id,
    })
    if (wErr) throw wErr

    pushToast(`Added to the waitlist for ${activeItem.value.name}.`)
    closeDrawer()
  } catch (e) {
    formError.value = e instanceof Error ? e.message : 'Could not join the waitlist.'
  } finally {
    reserving.value = false
  }
}

// --- toasts -------------------------------------------------------------
const toasts = ref<{ id: number; message: string }[]>([])
let toastSeq = 0
function pushToast(message: string) {
  const id = ++toastSeq
  toasts.value.push({ id, message })
  setTimeout(() => {
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }, 3500)
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Catalog</span>
        <h1>Browse Equipment</h1>
        <p class="view-desc">Live inventory from the Cage, Studio C, and the Media Room.</p>
      </div>
    </div>

    <p v-if="loading">Loading the catalog…</p>
    <p v-else-if="error" class="error-note">Couldn't load the catalog: {{ error }}</p>

    <template v-else>
      <div class="card" style="display: flex; flex-direction: column; gap: 14px">
        <div class="field" style="max-width: 360px">
          <label>Search</label>
          <input v-model="search" type="text" placeholder="Search by name, brand, or model…" />
        </div>

        <div>
          <div class="kicker" style="margin-bottom: 6px">Category</div>
          <div class="chip-row">
            <button
              v-for="c in directCategories"
              :key="c.id"
              type="button"
              class="chip"
              :class="{ active: selectedDirect.has(c.id) }"
              @click="toggle(selectedDirect, c.id)"
            >
              {{ c.name }}
            </button>
          </div>
        </div>

        <div>
          <div class="kicker" style="margin-bottom: 6px">Department</div>
          <div class="chip-row">
            <button
              v-for="c in generalCategories"
              :key="c.id"
              type="button"
              class="chip"
              :class="{ active: selectedGeneral.has(c.id) }"
              @click="toggle(selectedGeneral, c.id)"
            >
              {{ c.name }}
            </button>
          </div>
        </div>

        <div>
          <div class="kicker" style="margin-bottom: 6px">Location</div>
          <div class="chip-row">
            <button
              v-for="l in locations"
              :key="l.id"
              type="button"
              class="chip"
              :class="{ active: selectedLocations.has(l.id) }"
              @click="toggle(selectedLocations, l.id)"
            >
              {{ l.name }}
            </button>
          </div>
        </div>
      </div>

      <p v-if="filteredItems.length === 0" class="empty-note">
        No equipment matches those filters.
      </p>

      <div v-else class="grid-cards">
        <div
          v-for="item in filteredItems"
          :key="item.id"
          class="item-card"
          @click="openDrawer(item)"
        >
          <div class="item-thumb">
            <span class="glyph">🎥</span>
          </div>
          <div class="item-body">
            <span class="item-cat">{{ categoryById.get(item.direct_category_id ?? '')?.name ?? 'Uncategorized' }}</span>
            <span class="item-name">{{ item.name }}</span>
            <span v-if="item.brand || item.model" class="item-brand">{{ item.brand }} {{ item.model }}</span>

            <div v-if="isLocked(item)" class="lock-note">
              🔒 Requires {{ item.min_tier }} tier or higher
            </div>

            <div class="item-meta-row">
              <span class="item-price mono" v-if="item.purchase_price != null"
                >${{ Number(item.purchase_price).toFixed(0) }}</span
              >
              <span class="status-line" :class="availabilityTone(item.id)">
                <span class="status-dot" :class="availabilityTone(item.id)"></span>
                {{ availability(item.id).available }}/{{ availability(item.id).total }} available
              </span>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- ============ ITEM DETAIL DRAWER ============ -->
    <div v-if="activeItem" class="drawer-backdrop" @click.self="closeDrawer">
      <div class="drawer">
        <div class="drawer-thumb">🎥</div>
        <div>
          <span class="item-cat">{{
            categoryById.get(activeItem.direct_category_id ?? '')?.name ?? 'Uncategorized'
          }}</span>
          <h2 style="font-size: 19px; margin-top: 4px">{{ activeItem.name }}</h2>
          <p v-if="activeItem.brand || activeItem.model" style="color: var(--ink-3); margin-top: 2px">
            {{ activeItem.brand }} {{ activeItem.model }}
          </p>
        </div>

        <div class="chip-row">
          <span class="badge accent">{{ locationById.get(activeItem.location_id)?.name }}</span>
          <span class="badge neutral">
            {{ categoryById.get(activeItem.general_category_id ?? '')?.name ?? 'Misc' }}
          </span>
          <span class="badge violet" style="text-transform: capitalize">{{ activeItem.min_tier }}+ tier</span>
        </div>

        <p v-if="activeItem.description" style="color: var(--ink-2)">{{ activeItem.description }}</p>

        <hr class="divider" />

        <div>
          <div class="section-title" style="margin-bottom: 8px">
            Units ({{ availability(activeItem.id).available }}/{{ availability(activeItem.id).total }}
            available)
          </div>
          <div v-for="u in availability(activeItem.id).units" :key="u.id" class="unit-line">
            <span class="mono">{{ u.unit_code }}</span>
            <span class="badge" :class="toneForCondition(u.condition)">{{ conditionLabel(u.condition) }}</span>
            <span v-if="u.current_reservation_id" class="badge muted">checked out</span>
            <span v-if="u.condition_note" style="color: var(--ink-3); font-size: 11px">{{
              u.condition_note
            }}</span>
          </div>
        </div>

        <hr class="divider" />

        <div v-if="isLocked(activeItem)" class="lock-note">
          🔒 This item requires {{ activeItem.min_tier }} tier or higher. Your current tier is
          {{ studentTier }}.
        </div>

        <template v-else-if="availability(activeItem.id).available > 0">
          <div class="qty-stepper">
            <button type="button" @click="quantity = Math.max(1, quantity - 1)" :disabled="quantity <= 1">
              −
            </button>
            <span class="qty-num">{{ quantity }}</span>
            <button
              type="button"
              @click="quantity = Math.min(availability(activeItem.id).available, quantity + 1)"
              :disabled="quantity >= availability(activeItem.id).available"
            >
              +
            </button>
          </div>
          <p v-if="formError" class="error-note">{{ formError }}</p>
          <button class="btn primary" @click="addToCart">Add to reservation</button>
        </template>

        <template v-else>
          <p v-if="formError" class="error-note">{{ formError }}</p>
          <button class="btn" :disabled="reserving" @click="joinWaitlist">
            {{ reserving ? 'Joining…' : 'Join waitlist' }}
          </button>
        </template>
      </div>
    </div>

    <!-- ============ TOASTS ============ -->
    <div class="toast-region">
      <div v-for="t in toasts" :key="t.id" class="toast">{{ t.message }}</div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
