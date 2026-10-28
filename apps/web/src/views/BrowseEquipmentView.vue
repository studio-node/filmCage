<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore, type CatalogItem } from '../stores/catalog'
import { fuzzyTest } from '../lib/fuzzySearch'

interface UnitRow {
  id: string
  item_model_id: string
  status: string
}

const TIER_RANK: Record<string, number> = { beginner: 0, intermediate: 1, advanced: 2 }
// Retired/lost/stolen units are permanently out of the fleet -- they
// don't count toward "how many of this do we own" at all, same as if
// they were never added. out_for_repair is temporary (it'll come
// back), so it still counts toward the total.
const FLEET_STATUSES = ['active', 'out_for_repair']

const auth = useAuthStore()
const catalog = useCatalogStore()
const router = useRouter()

// The catalog itself (item models, categories, locations) is shared
// with the top-nav global search via the catalog store — this view
// just reads it instead of fetching its own copy. Unit-level counts
// are per-unit stock, not catalog data, so they're still fetched here
// on their own.
const loading = ref(true)
const error = ref('')

const unitsByModel = ref<Map<string, UnitRow[]>>(new Map())
const studentTier = ref<string | null>(null)

const directCategories = computed(() => catalog.categories.filter((c) => c.kind === 'direct'))
const generalCategories = computed(() => catalog.categories.filter((c) => c.kind === 'general'))

// --- filters --------------------------------------------------------
// catalog.query is the shared search text — the same box drives both
// this page and the top-nav global search, so they stay in sync no
// matter which one someone types into.
const selectedDirect = reactive(new Set<string>())
const selectedGeneral = reactive(new Set<string>())
const selectedLocations = reactive(new Set<string>())

function toggle(set: Set<string>, id: string) {
  if (set.has(id)) set.delete(id)
  else set.add(id)
}

async function loadUnits() {
  const { data, error: unitErr } = await supabase
    .from('item_units_with_status')
    .select('id, item_model_id, status')
  if (unitErr) throw unitErr
  const grouped = new Map<string, UnitRow[]>()
  for (const u of (data ?? []) as UnitRow[]) {
    const list = grouped.get(u.item_model_id) ?? []
    list.push(u)
    grouped.set(u.item_model_id, list)
  }
  unitsByModel.value = grouped
}

async function loadAll() {
  loading.value = true
  error.value = ''
  try {
    await Promise.all([catalog.ensureLoaded(), loadUnits()])
    if (catalog.error) throw new Error(catalog.error)

    if (auth.role === 'student' && auth.user) {
      const { data: profile } = await supabase
        .from('user_profiles')
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
    if (userId) loadAll()
  },
  { immediate: true }
)

// This page is pure browsing — it only ever shows how many of an item
// the Cage owns in total, never how many are free right now. Real,
// date-aware availability can only be checked against an actual
// pickup/drop-off window, and that only happens on the New Reservation
// screen (see item_available_quantity()). Showing an "available"
// number here is exactly what let the Oct 19 rod double-booking slip
// through unnoticed, so this page no longer claims to know it.
function totalOwned(modelId: string): number {
  return (unitsByModel.value.get(modelId) ?? []).filter((u) => FLEET_STATUSES.includes(u.status)).length
}

function ownedTone(modelId: string): 'good' | 'crit' {
  return totalOwned(modelId) > 0 ? 'good' : 'crit'
}

function isLocked(item: CatalogItem) {
  if (auth.role !== 'student' || !studentTier.value) return false
  return TIER_RANK[studentTier.value] < TIER_RANK[item.min_tier]
}

const filteredItems = computed(() => {
  const q = catalog.query
  return catalog.items.filter((item) => {
    if (selectedDirect.size > 0 && !(item.direct_category_id && selectedDirect.has(item.direct_category_id)))
      return false
    if (
      selectedGeneral.size > 0 &&
      !(item.general_category_id && selectedGeneral.has(item.general_category_id))
    )
      return false
    if (selectedLocations.size > 0 && !selectedLocations.has(item.location_id)) return false
    if (q.trim() && !fuzzyTest(q, catalog.searchableText(item))) return false
    return true
  })
})

// --- drawer -----------------------------------------------------------
// Purely informational now — picking a quantity, adding to a
// reservation, or joining a waitlist all happen on New Reservation
// instead, once a real window is set and there's something to check
// availability against.
const activeItem = ref<CatalogItem | null>(null)

function openDrawer(item: CatalogItem) {
  activeItem.value = item
}
function closeDrawer() {
  activeItem.value = null
}

function goStartReservation() {
  if (!activeItem.value) return
  router.push({ name: 'new-reservation', query: { item: activeItem.value.id, location: activeItem.value.location_id } })
  closeDrawer()
}

// If the global search dropdown (top nav) sent us here to open a
// specific item, do it as soon as that item is actually available to
// open — covers both "already on this page" (fires right away) and
// "navigating in from elsewhere" (fires once loadAll() resolves).
watch(
  () => [catalog.pendingOpenItemId, catalog.items] as const,
  ([pendingId]) => {
    if (!pendingId) return
    const item = catalog.items.find((i) => i.id === pendingId)
    if (item) {
      openDrawer(item)
      catalog.pendingOpenItemId = null
    }
  },
  { immediate: true }
)
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
          <input
            v-model="catalog.query"
            type="text"
            placeholder="Search by name, brand, model, category…"
          />
          <p class="field-hint">Close spellings and typos still match — it doesn't have to be exact.</p>
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
              v-for="l in catalog.locations"
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
            <span class="item-cat">{{ catalog.categoryById.get(item.direct_category_id ?? '')?.name ?? 'Uncategorized' }}</span>
            <span class="item-name">{{ item.name }}</span>
            <span v-if="item.brand || item.model" class="item-brand">{{ item.brand }} {{ item.model }}</span>

            <div v-if="isLocked(item)" class="lock-note">
              🔒 Requires {{ item.min_tier }} tier or higher
            </div>

            <div class="item-meta-row">
              <span class="item-price mono" v-if="item.purchase_price != null"
                >${{ Number(item.purchase_price).toFixed(0) }}</span
              >
              <span class="status-line" :class="ownedTone(item.id)">
                <span class="status-dot" :class="ownedTone(item.id)"></span>
                {{ totalOwned(item.id) }} owned
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
            catalog.categoryById.get(activeItem.direct_category_id ?? '')?.name ?? 'Uncategorized'
          }}</span>
          <h2 style="font-size: 19px; margin-top: 4px">{{ activeItem.name }}</h2>
          <p v-if="activeItem.brand || activeItem.model" style="color: var(--ink-3); margin-top: 2px">
            {{ activeItem.brand }} {{ activeItem.model }}
          </p>
        </div>

        <div class="chip-row">
          <span class="badge accent">{{ catalog.locationById.get(activeItem.location_id)?.name }}</span>
          <span class="badge neutral">
            {{ catalog.categoryById.get(activeItem.general_category_id ?? '')?.name ?? 'Misc' }}
          </span>
          <span class="badge violet" style="text-transform: capitalize">{{ activeItem.min_tier }}+ tier</span>
        </div>

        <p v-if="activeItem.description" style="color: var(--ink-2)">{{ activeItem.description }}</p>

        <hr class="divider" />

        <div class="item-meta-row">
          <span class="status-line" :class="ownedTone(activeItem.id)">
            <span class="status-dot" :class="ownedTone(activeItem.id)"></span>
            {{ totalOwned(activeItem.id) }} owned total
          </span>
        </div>

        <div v-if="isLocked(activeItem)" class="lock-note">
          🔒 This item requires {{ activeItem.min_tier }} tier or higher. Your current tier is
          {{ studentTier }}.
        </div>

        <hr class="divider" />

        <div class="info-note">
          This page just shows what's in the fleet. Start a new reservation to check real
          availability for your actual pickup and drop-off dates.
        </div>
        <button class="btn primary" @click="goStartReservation">Start a reservation</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
