<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { toneForCondition, conditionLabel, type UnitCondition } from '../lib/conditionStatus'

interface Category {
  id: string
  name: string
  kind: 'direct' | 'general'
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
  is_active: boolean
}
interface UnitRow {
  id: string | null // null = not yet saved
  unit_code: string
  condition: UnitCondition
  condition_note: string
  qr_code: string
}

const loading = ref(true)
const error = ref('')
const categories = ref<Category[]>([])
const locations = ref<Location[]>([])
const items = ref<ItemModel[]>([])

const locationById = computed(() => new Map(locations.value.map((l) => [l.id, l])))

async function loadAll() {
  loading.value = true
  error.value = ''
  const [catRes, locRes, modelRes] = await Promise.all([
    supabase.from('categories').select('id, name, kind').order('display_order'),
    supabase.from('locations').select('id, name').order('name'),
    supabase
      .from('item_models')
      .select(
        'id, name, brand, model, description, purchase_price, location_id, direct_category_id, general_category_id, min_tier, is_active'
      )
      .order('name'),
  ])
  if (catRes.error) error.value = catRes.error.message
  else categories.value = catRes.data ?? []
  if (locRes.error) error.value = locRes.error.message
  else locations.value = locRes.data ?? []
  if (modelRes.error) error.value = modelRes.error.message
  else items.value = (modelRes.data ?? []) as ItemModel[]
  loading.value = false
}
loadAll()

const search = ref('')
const filteredItems = computed(() => {
  const q = search.value.trim().toLowerCase()
  if (!q) return items.value
  return items.value.filter((item) =>
    `${item.name} ${item.brand ?? ''} ${item.model ?? ''}`.toLowerCase().includes(q)
  )
})

// --- edit panel ---------------------------------------------------------
const activeItem = ref<ItemModel | null>(null)
const editForm = ref<Partial<ItemModel>>({})
const units = ref<UnitRow[]>([])
const unitsLoading = ref(false)

const savingModel = ref(false)
const modelError = ref('')
const modelSaved = ref(false)

const savingUnits = ref(false)
const unitsError = ref('')
const unitsSaved = ref(false)

async function openEdit(item: ItemModel) {
  activeItem.value = item
  editForm.value = { ...item }
  modelError.value = ''
  modelSaved.value = false
  unitsError.value = ''
  unitsSaved.value = false
  unitsLoading.value = true
  units.value = []
  const { data, error: uErr } = await supabase
    .from('item_units')
    .select('id, unit_code, condition, condition_note, qr_code')
    .eq('item_model_id', item.id)
    .order('unit_code')
  if (uErr) {
    unitsError.value = uErr.message
  } else {
    units.value = (data ?? []).map((u) => ({
      id: u.id,
      unit_code: u.unit_code,
      condition: u.condition as UnitCondition,
      condition_note: u.condition_note ?? '',
      qr_code: u.qr_code ?? '',
    }))
  }
  unitsLoading.value = false
}
function closeEdit() {
  activeItem.value = null
}

async function saveModel() {
  if (!activeItem.value) return
  modelError.value = ''
  modelSaved.value = false
  if (!editForm.value.name?.trim()) {
    modelError.value = 'Name is required.'
    return
  }
  savingModel.value = true
  try {
    const { error: updErr } = await supabase
      .from('item_models')
      .update({
        name: editForm.value.name.trim(),
        brand: editForm.value.brand?.trim() || null,
        model: editForm.value.model?.trim() || null,
        description: editForm.value.description?.trim() || null,
        purchase_price: editForm.value.purchase_price ?? null,
        location_id: editForm.value.location_id,
        direct_category_id: editForm.value.direct_category_id || null,
        general_category_id: editForm.value.general_category_id || null,
        min_tier: editForm.value.min_tier,
        is_active: editForm.value.is_active,
      })
      .eq('id', activeItem.value.id)
    if (updErr) throw updErr
    modelSaved.value = true
    // Reflect the change in the list without a full reload.
    const idx = items.value.findIndex((i) => i.id === activeItem.value!.id)
    if (idx !== -1) items.value[idx] = { ...items.value[idx], ...editForm.value } as ItemModel
  } catch (e) {
    modelError.value = e instanceof Error ? e.message : 'Could not save changes.'
  } finally {
    savingModel.value = false
  }
}

function addUnitRow() {
  const numericCodes = units.value.map((u) => parseInt(u.unit_code, 10)).filter((n) => !isNaN(n))
  const next = numericCodes.length > 0 ? Math.max(...numericCodes) + 1 : units.value.length + 1
  units.value.push({ id: null, unit_code: String(next), condition: 'good', condition_note: '', qr_code: '' })
}

async function saveUnits() {
  if (!activeItem.value) return
  unitsError.value = ''
  unitsSaved.value = false
  savingUnits.value = true
  try {
    for (const u of units.value) {
      if (!u.unit_code.trim()) throw new Error('Every unit needs a code/number.')
      const payload = {
        item_model_id: activeItem.value.id,
        unit_code: u.unit_code.trim(),
        condition: u.condition,
        condition_note: u.condition_note.trim() || null,
        qr_code: u.qr_code.trim() || null,
      }
      if (u.id) {
        const { error: updErr } = await supabase.from('item_units').update(payload).eq('id', u.id)
        if (updErr) throw updErr
      } else {
        const { data, error: insErr } = await supabase
          .from('item_units')
          .insert(payload)
          .select('id')
          .single()
        if (insErr) throw insErr
        u.id = data.id
      }
    }
    unitsSaved.value = true
  } catch (e) {
    unitsError.value = e instanceof Error ? e.message : 'Could not save one or more units (duplicate code or QR?).'
  } finally {
    savingUnits.value = false
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Admin</span>
        <h1>Edit Items</h1>
        <p class="view-desc">
          Update an existing item's details, or manage its individual units — condition, unit
          numbers, and QR codes.
        </p>
      </div>
    </div>

    <p v-if="loading">Loading catalog…</p>
    <p v-else-if="error" class="error-note">Couldn't load the catalog: {{ error }}</p>

    <template v-else>
      <div class="field" style="max-width: 360px">
        <label>Search</label>
        <input v-model="search" type="text" placeholder="Search by name, brand, or model…" />
      </div>

      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Brand / Model</th>
              <th>Location</th>
              <th>Tier</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="item in filteredItems" :key="item.id" class="clickable" @click="openEdit(item)">
              <td>{{ item.name }}</td>
              <td>{{ item.brand }} {{ item.model }}</td>
              <td>{{ locationById.get(item.location_id)?.name ?? '—' }}</td>
              <td style="text-transform: capitalize">{{ item.min_tier }}</td>
              <td>
                <span class="badge" :class="item.is_active ? 'good' : 'muted'">{{
                  item.is_active ? 'Active' : 'Inactive'
                }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>

    <!-- ============ EDIT DRAWER ============ -->
    <div v-if="activeItem" class="drawer-backdrop" @click.self="closeEdit">
      <div class="drawer">
        <h2 style="font-size: 19px">Edit {{ activeItem.name }}</h2>

        <div class="field">
          <label>Name</label>
          <input v-model="editForm.name" type="text" />
        </div>
        <div class="field-row">
          <div class="field">
            <label>Brand</label>
            <input v-model="editForm.brand" type="text" />
          </div>
          <div class="field">
            <label>Model</label>
            <input v-model="editForm.model" type="text" />
          </div>
        </div>
        <div class="field">
          <label>Description</label>
          <textarea v-model="editForm.description" rows="3"></textarea>
        </div>
        <div class="field-row">
          <div class="field">
            <label>Purchase price</label>
            <input v-model.number="editForm.purchase_price" type="number" min="0" step="0.01" />
          </div>
          <div class="field">
            <label>Minimum tier</label>
            <select v-model="editForm.min_tier">
              <option value="beginner">Beginner</option>
              <option value="intermediate">Intermediate</option>
              <option value="advanced">Advanced</option>
            </select>
          </div>
        </div>
        <div class="field">
          <label>Location</label>
          <select v-model="editForm.location_id">
            <option v-for="l in locations" :key="l.id" :value="l.id">{{ l.name }}</option>
          </select>
        </div>
        <div class="field-row">
          <div class="field">
            <label>Category</label>
            <select v-model="editForm.direct_category_id">
              <option value="">None</option>
              <option v-for="c in categories.filter((c) => c.kind === 'direct')" :key="c.id" :value="c.id">
                {{ c.name }}
              </option>
            </select>
          </div>
          <div class="field">
            <label>Department</label>
            <select v-model="editForm.general_category_id">
              <option value="">None</option>
              <option v-for="c in categories.filter((c) => c.kind === 'general')" :key="c.id" :value="c.id">
                {{ c.name }}
              </option>
            </select>
          </div>
        </div>
        <label style="display: flex; align-items: center; gap: 8px; font-size: 13px">
          <input v-model="editForm.is_active" type="checkbox" style="width: auto" />
          Active (visible in Browse Equipment)
        </label>

        <p v-if="modelError" class="error-note">{{ modelError }}</p>
        <p v-if="modelSaved" style="color: var(--good); font-weight: 600">Saved.</p>
        <button class="btn primary" :disabled="savingModel" @click="saveModel">
          {{ savingModel ? 'Saving…' : 'Save changes' }}
        </button>

        <hr class="divider" />

        <div class="section-title">Units</div>
        <p v-if="unitsLoading">Loading units…</p>
        <template v-else>
          <div v-for="(u, i) in units" :key="u.id ?? `new-${i}`" class="unit-line" style="flex-wrap: wrap">
            <input v-model="u.unit_code" type="text" class="qr-input mono" style="max-width: 50px" />
            <select v-model="u.condition" class="qr-input" style="max-width: 110px">
              <option value="good">Good</option>
              <option value="caution">Caution</option>
              <option value="damaged">Damaged</option>
              <option value="missing">Missing</option>
            </select>
            <input v-model="u.condition_note" type="text" placeholder="Condition note" class="qr-input" style="flex: 1; min-width: 120px" />
            <input v-model="u.qr_code" type="text" placeholder="QR code" class="qr-input mono" style="flex: 1; min-width: 120px" />
            <span v-if="u.id" class="badge" :class="toneForCondition(u.condition)">{{ conditionLabel(u.condition) }}</span>
            <span v-else class="badge accent">new</span>
          </div>
          <button class="btn ghost small" style="align-self: flex-start" @click="addUnitRow">+ Add unit</button>

          <p v-if="unitsError" class="error-note">{{ unitsError }}</p>
          <p v-if="unitsSaved" style="color: var(--good); font-weight: 600">Units saved.</p>
          <button class="btn primary" :disabled="savingUnits" @click="saveUnits">
            {{ savingUnits ? 'Saving…' : 'Save units' }}
          </button>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
.qr-input {
  border: 1px solid var(--border-strong);
  background: var(--surface);
  color: var(--ink);
  border-radius: 8px;
  padding: 6px 8px;
  font-size: 12.5px;
  font-family: var(--font-body);
}
</style>
