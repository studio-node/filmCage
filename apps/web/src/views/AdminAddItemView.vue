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

interface CreatedUnit {
  id: string
  unit_code: string
  qr_code: string
}
const createdUnits = ref<CreatedUnit[]>([])
const savingQr = ref(false)
const qrError = ref('')
const qrSaved = ref(false)

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
  qrSaved.value = false
  createdUnits.value = []
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
    // qr_code is left blank — some equipment already has a physical QR
    // sticker from before this system existed, so codes are typed (or
    // scanned) in below rather than generated, and don't have to match
    // the sequential unit number.
    const unitRows = Array.from({ length: quantity.value }, (_, i) => ({
      item_model_id: newModel.id,
      unit_code: String(i + 1),
    }))
    const { data: newUnits, error: unitsErr } = await supabase
      .from('item_units')
      .insert(unitRows)
      .select('id, unit_code')
      .order('unit_code')
    if (unitsErr) throw unitsErr

    successMessage.value = `Added "${name.value.trim()}" with ${quantity.value} unit${
      quantity.value === 1 ? '' : 's'
    } (labeled 1–${quantity.value}).`
    createdUnits.value = (newUnits ?? []).map((u) => ({ id: u.id, unit_code: u.unit_code, qr_code: '' }))
    resetForm()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not add this item.'
  } finally {
    submitting.value = false
  }
}

async function saveQrCodes() {
  qrError.value = ''
  qrSaved.value = false
  const toSave = createdUnits.value.filter((u) => u.qr_code.trim())
  if (toSave.length === 0) {
    qrError.value = 'Enter at least one QR code to save, or skip this for now — you can add codes later from Edit Items.'
    return
  }
  savingQr.value = true
  try {
    for (const u of toSave) {
      const { error: updErr } = await supabase
        .from('item_units')
        .update({ qr_code: u.qr_code.trim() })
        .eq('id', u.id)
      if (updErr) throw updErr
    }
    qrSaved.value = true
  } catch (e) {
    qrError.value = e instanceof Error ? e.message : 'Could not save one or more QR codes (is one already in use?).'
  } finally {
    savingQr.value = false
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
        }}, each in "good" condition. QR codes aren't generated — you'll get a place to type in the
        code from an existing sticker (or leave it blank) right after adding.
      </p>

      <p v-if="error" class="error-note">{{ error }}</p>
      <p v-if="successMessage" style="color: var(--good); font-weight: 600">{{ successMessage }}</p>

      <div>
        <button class="btn primary" :disabled="submitting" @click="handleSubmit">
          {{ submitting ? 'Adding…' : 'Add item' }}
        </button>
      </div>
    </div>

    <div v-if="createdUnits.length > 0" class="card" style="max-width: 640px; display: flex; flex-direction: column; gap: 12px">
      <div class="section-title">Assign QR codes (optional)</div>
      <p style="color: var(--ink-2)">
        If any of these units already have a physical QR sticker, type or scan the code in here. Leave
        blank to assign one later from Edit Items.
      </p>
      <div v-for="u in createdUnits" :key="u.id" class="unit-line">
        <span class="mono" style="width: 32px">#{{ u.unit_code }}</span>
        <input v-model="u.qr_code" type="text" placeholder="e.g. FC-3K9QZ2" class="qr-input" />
      </div>
      <p v-if="qrError" class="error-note">{{ qrError }}</p>
      <p v-if="qrSaved" style="color: var(--good); font-weight: 600">QR codes saved.</p>
      <div>
        <button class="btn" :disabled="savingQr" @click="saveQrCodes">
          {{ savingQr ? 'Saving…' : 'Save QR codes' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
.qr-input {
  flex: 1;
  border: 1px solid var(--border-strong);
  background: var(--surface);
  color: var(--ink);
  border-radius: 8px;
  padding: 8px 10px;
  font-size: 13.5px;
  font-family: var(--font-mono);
}
</style>
