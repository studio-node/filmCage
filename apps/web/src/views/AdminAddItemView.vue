<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { errorMessage } from '../lib/errors'
import { useCatalogStore } from '../stores/catalog'
import { uploadItemPhoto, validatePhotoFile } from '../lib/itemPhotos'
import IconBase from '../components/icons/IconBase.vue'

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
const catalog = useCatalogStore()
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

// Photo is uploaded at submit time, once the new item model's id
// exists to scope the storage path -- until then it's just a local
// File plus an object-URL preview, nothing touches the network.
const photoFile = ref<File | null>(null)
const photoPreviewUrl = ref<string | null>(null)
const photoError = ref('')

function clearPhotoPreview() {
  if (photoPreviewUrl.value) URL.revokeObjectURL(photoPreviewUrl.value)
  photoPreviewUrl.value = null
  photoFile.value = null
}
function onPhotoChange(e: Event) {
  photoError.value = ''
  const file = (e.target as HTMLInputElement).files?.[0] ?? null
  if (!file) return
  const problem = validatePhotoFile(file)
  if (problem) {
    photoError.value = problem
    ;(e.target as HTMLInputElement).value = ''
    return
  }
  clearPhotoPreview()
  photoFile.value = file
  photoPreviewUrl.value = URL.createObjectURL(file)
}
onBeforeUnmount(() => {
  if (photoPreviewUrl.value) URL.revokeObjectURL(photoPreviewUrl.value)
})

const submitting = ref(false)
const error = ref('')
const successMessage = ref('')

interface CreatedUnit {
  id: string
  unit_code: string
  qr_code: string
  serial_number: string
}
const createdUnits = ref<CreatedUnit[]>([])
const savingDetails = ref(false)
const detailsError = ref('')
const detailsSaved = ref(false)

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
  clearPhotoPreview()
  photoError.value = ''
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
  detailsSaved.value = false
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

    let photoNote = ''
    if (photoFile.value) {
      try {
        const publicUrl = await uploadItemPhoto(photoFile.value, newModel.id)
        const { error: photoErr } = await supabase
          .from('item_models')
          .update({ picture_url: publicUrl })
          .eq('id', newModel.id)
        if (photoErr) throw photoErr
      } catch (e) {
        // The item itself is already created and usable — a photo
        // upload failure shouldn't undo that. Surface it separately so
        // it's clear the photo didn't make it, with a way to add one
        // later from Edit Items.
        photoNote = ` (photo didn't upload: ${errorMessage(e, 'unknown error')} — add it later from Edit Items)`
      }
    }

    successMessage.value = `Added "${name.value.trim()}" with ${quantity.value} unit${
      quantity.value === 1 ? '' : 's'
    } (labeled 1–${quantity.value}).${photoNote}`
    createdUnits.value = (newUnits ?? []).map((u) => ({ id: u.id, unit_code: u.unit_code, qr_code: '', serial_number: '' }))
    resetForm()
    // New item models change what the catalog store has cached, which
    // now feeds both Browse Equipment and the top-nav search — force
    // a refetch so the new item shows up without a full page reload.
    catalog.ensureLoaded(true)
  } catch (e) {
    error.value = errorMessage(e, 'Could not add this item.')
  } finally {
    submitting.value = false
  }
}

async function saveUnitDetails() {
  detailsError.value = ''
  detailsSaved.value = false
  const toSave = createdUnits.value.filter((u) => u.qr_code.trim() || u.serial_number.trim())
  if (toSave.length === 0) {
    detailsError.value =
      'Enter at least a QR code or serial number to save, or skip this for now — you can add these later from Edit Items.'
    return
  }
  savingDetails.value = true
  try {
    for (const u of toSave) {
      const { error: updErr } = await supabase
        .from('item_units')
        .update({
          qr_code: u.qr_code.trim() || null,
          serial_number: u.serial_number.trim() || null,
        })
        .eq('id', u.id)
      if (updErr) throw updErr
    }
    detailsSaved.value = true
  } catch (e) {
    detailsError.value = errorMessage(e, 'Could not save one or more units — please try again.')
  } finally {
    savingDetails.value = false
  }
}
</script>

<template>
  <!-- No .view-head here -- this component is now rendered as the "Add
  Item" tab of InventoryManagementView.vue, which owns the page title.
  .view-body keeps the same vertical rhythm as .view without doubling
  up the max-width/centering. -->
  <div class="view-body">
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

      <div class="field">
        <label>Photo</label>
        <div class="photo-picker">
          <div class="photo-preview">
            <img v-if="photoPreviewUrl" :src="photoPreviewUrl" alt="" />
            <IconBase v-else name="camera" :size="22" />
          </div>
          <div style="display: flex; flex-direction: column; gap: 6px">
            <input type="file" accept="image/jpeg,image/png,image/webp,image/gif" @change="onPhotoChange" />
            <button v-if="photoPreviewUrl" type="button" class="btn ghost small" style="align-self: flex-start" @click="clearPhotoPreview">
              Remove photo
            </button>
          </div>
        </div>
        <p class="field-hint">Shown on the Browse Equipment card. Optional — you can add one later from Edit Items.</p>
        <p v-if="photoError" class="error-note" style="margin-top: 4px">{{ photoError }}</p>
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
        }}, each in "good" condition. QR codes and serial numbers aren't required — you'll get a
        place to type them in (from a sticker or the item itself, or leave either blank) right after
        adding.
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
      <div class="section-title">Assign QR codes &amp; serial numbers (optional)</div>
      <p style="color: var(--ink-2)">
        If any of these units already have a physical QR sticker or a manufacturer serial number,
        type or scan them in here. Leave either blank to fill in later from Edit Items.
      </p>
      <div v-for="u in createdUnits" :key="u.id" class="unit-line" style="flex-wrap: wrap">
        <span class="mono" style="width: 32px">#{{ u.unit_code }}</span>
        <input v-model="u.qr_code" type="text" placeholder="QR code, e.g. FC-3K9QZ2" class="qr-input" />
        <input v-model="u.serial_number" type="text" placeholder="Serial number" class="qr-input" />
      </div>
      <p v-if="detailsError" class="error-note">{{ detailsError }}</p>
      <p v-if="detailsSaved" style="color: var(--good); font-weight: 600">Saved.</p>
      <div>
        <button class="btn" :disabled="savingDetails" @click="saveUnitDetails">
          {{ savingDetails ? 'Saving…' : 'Save' }}
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
