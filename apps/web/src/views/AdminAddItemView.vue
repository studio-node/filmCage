<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabaseClient'

interface Category {
  id: string
  name: string
  kind: 'direct' | 'general'
}
interface Location {
  id: string
  name: string
}

const categories = ref<Category[]>([])
const locations = ref<Location[]>([])
const loadingOptions = ref(true)
const optionsError = ref('')

async function loadOptions() {
  loadingOptions.value = true
  optionsError.value = ''
  const [catRes, locRes] = await Promise.all([
    supabase.from('categories').select('id, name, kind').order('display_order'),
    supabase.from('locations').select('id, name').order('name'),
  ])
  if (catRes.error) optionsError.value = catRes.error.message
  else categories.value = catRes.data ?? []
  if (locRes.error) optionsError.value = locRes.error.message
  else locations.value = locRes.data ?? []
  loadingOptions.value = false
}
onMounted(loadOptions)

const name = ref('')
const brand = ref('')
const model = ref('')
const description = ref('')
const purchasePrice = ref<number | null>(null)
const locationId = ref('')
const directCategoryId = ref('')
const generalCategoryId = ref('')
const minTier = ref<'beginner' | 'intermediate' | 'advanced'>('beginner')
const quantity = ref(1)

const submitting = ref(false)
const error = ref('')
const successMessage = ref('')

function resetForm() {
  name.value = ''
  brand.value = ''
  model.value = ''
  description.value = ''
  purchasePrice.value = null
  locationId.value = ''
  directCategoryId.value = ''
  generalCategoryId.value = ''
  minTier.value = 'beginner'
  quantity.value = 1
}

async function handleSubmit() {
  error.value = ''
  successMessage.value = ''

  if (!name.value.trim()) {
    error.value = 'Name is required.'
    return
  }
  if (!locationId.value) {
    error.value = 'Pick a location.'
    return
  }
  if (quantity.value < 1 || quantity.value > 100) {
    error.value = 'Quantity must be between 1 and 100.'
    return
  }

  submitting.value = true
  try {
    const { data: newModel, error: modelErr } = await supabase
      .from('item_models')
      .insert({
        name: name.value.trim(),
        brand: brand.value.trim() || null,
        model: model.value.trim() || null,
        description: description.value.trim() || null,
        purchase_price: purchasePrice.value,
        location_id: locationId.value,
        direct_category_id: directCategoryId.value || null,
        general_category_id: generalCategoryId.value || null,
        min_tier: minTier.value,
      })
      .select('id')
      .single()
    if (modelErr) throw modelErr

    // Auto-numbered units: quantity 5 -> unit_code '1' through '5'.
    // qr_code is intentionally omitted — item_units.qr_code has a
    // column default that generates a unique code automatically.
    const unitRows = Array.from({ length: quantity.value }, (_, i) => ({
      item_model_id: newModel.id,
      unit_code: String(i + 1),
    }))
    const { error: unitsErr } = await supabase.from('item_units').insert(unitRows)
    if (unitsErr) throw unitsErr

    successMessage.value = `Added "${name.value.trim()}" with ${quantity.value} unit${
      quantity.value === 1 ? '' : 's'
    } (labeled 1–${quantity.value}).`
    resetForm()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not add this item.'
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Admin</span>
        <h1>Add Items</h1>
        <p class="view-desc">
          Add a new piece of equipment to the catalog. Units are created and numbered
          automatically from the quantity you enter.
        </p>
      </div>
    </div>

    <p v-if="loadingOptions">Loading categories and locations…</p>
    <p v-else-if="optionsError" class="error-note">Couldn't load form options: {{ optionsError }}</p>

    <div v-else class="card" style="max-width: 640px; display: flex; flex-direction: column; gap: 14px">
      <div class="field">
        <label>Name</label>
        <input v-model="name" type="text" placeholder="e.g. Canon EOS R6 Mark II" />
      </div>

      <div class="field-row">
        <div class="field">
          <label>Brand</label>
          <input v-model="brand" type="text" placeholder="e.g. Canon" />
        </div>
        <div class="field">
          <label>Model</label>
          <input v-model="model" type="text" placeholder="e.g. EOS R6 Mark II" />
        </div>
      </div>

      <div class="field">
        <label>Description</label>
        <textarea v-model="description" rows="3" placeholder="Optional notes shown in Browse Equipment"></textarea>
      </div>

      <div class="field-row">
        <div class="field">
          <label>Purchase price</label>
          <input v-model.number="purchasePrice" type="number" min="0" step="0.01" placeholder="0.00" />
        </div>
        <div class="field">
          <label>Minimum tier</label>
          <select v-model="minTier">
            <option value="beginner">Beginner</option>
            <option value="intermediate">Intermediate</option>
            <option value="advanced">Advanced</option>
          </select>
        </div>
      </div>

      <div class="field">
        <label>Location</label>
        <select v-model="locationId">
          <option value="" disabled>Select a location…</option>
          <option v-for="l in locations" :key="l.id" :value="l.id">{{ l.name }}</option>
        </select>
      </div>

      <div class="field-row">
        <div class="field">
          <label>Category</label>
          <select v-model="directCategoryId">
            <option value="">None</option>
            <option v-for="c in categories.filter((c) => c.kind === 'direct')" :key="c.id" :value="c.id">
              {{ c.name }}
            </option>
          </select>
        </div>
        <div class="field">
          <label>Department</label>
          <select v-model="generalCategoryId">
            <option value="">None</option>
            <option v-for="c in categories.filter((c) => c.kind === 'general')" :key="c.id" :value="c.id">
              {{ c.name }}
            </option>
          </select>
        </div>
      </div>

      <div class="field" style="max-width: 160px">
        <label>Quantity</label>
        <input v-model.number="quantity" type="number" min="1" max="100" />
      </div>
      <p class="field-hint">
        Creates {{ quantity }} unit{{ quantity === 1 ? '' : 's' }} labeled 1{{
          quantity > 1 ? `–${quantity}` : ''
        }}, each in "good" condition with its own auto-generated QR code.
      </p>

      <p v-if="error" class="error-note">{{ error }}</p>
      <p v-if="successMessage" style="color: var(--good); font-weight: 600">{{ successMessage }}</p>

      <div>
        <button class="btn primary" :disabled="submitting" @click="handleSubmit">
          {{ submitting ? 'Adding…' : 'Add item' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
