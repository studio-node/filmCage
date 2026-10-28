<script setup lang="ts">
import { computed, ref } from 'vue'
import { supabase } from '../lib/supabaseClient'
import { toneForCondition, conditionLabel, conditionRank, type UnitCondition, toneForUnitStatus, unitStatusLabel, type UnitStatus } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'
import { useCatalogStore } from '../stores/catalog'

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
  // The condition this unit had when the drawer was opened (or 'good'
  // for a brand-new row) — used to detect a real downgrade client-side,
  // matching item_units_condition_guard()'s rule, so we can ask for a
  // note before hitting the database instead of after.
  originalCondition: UnitCondition
  condition_note: string
  qr_code: string
  serial_number: string
  status: UnitStatus
  originalStatus: UnitStatus
  status_note: string
  // Set from item_units_with_status — null unless this unit is
  // currently out on an active reservation. Mirrors item_units_
  // status_guard()'s own rule client-side so staff see why the
  // Status control is locked, instead of hitting it only on save.
  current_reservation_id: string | null
}

const catalog = useCatalogStore()
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

// Which unit (by index into `units`) is expanded into its own card,
// or null to show the compact per-unit list instead. A unit's own
// card is just a roomier place to edit the same fields — unit_code,
// condition, note, QR code, serial number — that used to be crammed
// into one small row; it isn't a separate save step. "Save changes"
// below still saves everything (the item's fields and every unit,
// expanded or not) in one action, same as before.
const activeUnitIndex = ref<number | null>(null)
// A single named reference to "the unit currently expanded into its
// own card" -- lets the template narrow null-ability the same way it
// already does for activeItem above, instead of repeating
// units[activeUnitIndex] (an array index TS can't narrow) everywhere.
const activeUnit = computed(() => (activeUnitIndex.value === null ? null : units.value[activeUnitIndex.value]))

// --- unit delete: checked up front so staff see *why* delete isn't
// available (real reservation/condition history), rather than firing
// it and translating a raw foreign-key error. Same pattern as
// ReservationQueueView's checkDeleteBlockers/deleteBlockedReason.
// Keyed by unit id (a brand-new, unsaved row never needs this --
// "Remove" on those is purely local, see removeUnitRow below).
const unitDeleteConfirmId = ref<string | null>(null)
const unitDeleteBlocked = ref<Record<string, string | null>>({})
const unitDeleteBusy = ref<Record<string, boolean>>({})

async function checkUnitDeleteBlockers(unitId: string) {
  const [resUnits, reviews] = await Promise.all([
    supabase.from('reservation_units').select('unit_id', { count: 'exact', head: true }).eq('unit_id', unitId),
    supabase.from('condition_reviews').select('id', { count: 'exact', head: true }).eq('unit_id', unitId),
  ])
  const parts: string[] = []
  if ((resUnits.count ?? 0) > 0) parts.push(`${resUnits.count} reservation${resUnits.count! > 1 ? 's' : ''}`)
  if ((reviews.count ?? 0) > 0) parts.push(`${reviews.count} condition review${reviews.count! > 1 ? 's' : ''}`)
  unitDeleteBlocked.value = {
    ...unitDeleteBlocked.value,
    [unitId]: parts.length > 0 ? `Has ${parts.join(', ')} attached — retire it instead to keep that history.` : null,
  }
}
async function startUnitDelete(unitId: string) {
  unitDeleteConfirmId.value = unitId
  await checkUnitDeleteBlockers(unitId)
}
function cancelUnitDeletePrompt() {
  unitDeleteConfirmId.value = null
}
async function confirmUnitDelete(unitId: string, index: number) {
  unitDeleteBusy.value = { ...unitDeleteBusy.value, [unitId]: true }
  saveError.value = ''
  try {
    const { error: delErr } = await supabase.from('item_units').delete().eq('id', unitId)
    if (delErr) throw delErr
    units.value.splice(index, 1)
    unitDeleteConfirmId.value = null
    activeUnitIndex.value = null
    catalog.ensureLoaded(true)
  } catch (e) {
    saveError.value = errorMessage(e, 'Could not delete this unit — it may have history attached that blocks deletion.')
  } finally {
    unitDeleteBusy.value = { ...unitDeleteBusy.value, [unitId]: false }
  }
}
// A brand-new row (id === null) hasn't been saved yet — nothing in
// the database to delete, so removing it is purely local, same as
// adding one is.
function removeUnitRow(index: number) {
  units.value.splice(index, 1)
  activeUnitIndex.value = null
}

// --- whole-model delete: same up-front-check pattern as above, one
// level up. Checked against the item's own reservation_items rows
// (every reservation that's ever requested this model, assigned to a
// specific unit or not) plus whatever the unit-level checks above
// already found for each of its units, plus kit membership -- losing
// any of these silently on a cascade delete would be real data loss,
// not cleanup.
const modelDeleteConfirm = ref(false)
const modelDeleteBlockedReason = ref<string | null>(null)
const modelDeleteBusy = ref(false)
const modelDeleteChecking = ref(false)

async function checkModelDeleteBlockers() {
  if (!activeItem.value) return
  modelDeleteChecking.value = true
  const modelId = activeItem.value.id
  const unitIds = units.value.filter((u) => u.id).map((u) => u.id as string)
  const [items, resUnits, kits, reviews] = await Promise.all([
    supabase.from('reservation_items').select('id', { count: 'exact', head: true }).eq('item_model_id', modelId),
    supabase.from('reservation_units').select('unit_id', { count: 'exact', head: true }).eq('item_model_id', modelId),
    supabase.from('kit_items').select('id', { count: 'exact', head: true }).eq('item_model_id', modelId),
    unitIds.length > 0
      ? supabase.from('condition_reviews').select('id', { count: 'exact', head: true }).in('unit_id', unitIds)
      : Promise.resolve({ count: 0, error: null }),
  ])
  const parts: string[] = []
  if ((items.count ?? 0) > 0) parts.push(`${items.count} reservation line item${items.count! > 1 ? 's' : ''}`)
  if ((resUnits.count ?? 0) > 0) parts.push(`${resUnits.count} unit-level reservation${resUnits.count! > 1 ? 's' : ''}`)
  if ((reviews.count ?? 0) > 0) parts.push(`${reviews.count} condition review${reviews.count! > 1 ? 's' : ''}`)
  if ((kits.count ?? 0) > 0) parts.push(`${kits.count} kit${kits.count! > 1 ? 's' : ''}`)
  modelDeleteBlockedReason.value =
    parts.length > 0
      ? `Has ${parts.join(', ')} attached — mark it Inactive instead to keep that history.`
      : units.value.length > 0
        ? `Has ${units.value.length} unit${units.value.length > 1 ? 's' : ''} that would be deleted along with it.`
        : null
  modelDeleteChecking.value = false
}
async function startModelDelete() {
  modelDeleteConfirm.value = true
  await checkModelDeleteBlockers()
}
function cancelModelDeletePrompt() {
  modelDeleteConfirm.value = false
}
async function confirmModelDelete() {
  if (!activeItem.value) return
  modelDeleteBusy.value = true
  saveError.value = ''
  try {
    const { error: delErr } = await supabase.from('item_models').delete().eq('id', activeItem.value.id)
    if (delErr) throw delErr
    const idx = items.value.findIndex((i) => i.id === activeItem.value!.id)
    if (idx !== -1) items.value.splice(idx, 1)
    closeEdit()
    catalog.ensureLoaded(true)
  } catch (e) {
    saveError.value = errorMessage(e, 'Could not delete this item — it may have history attached that blocks deletion.')
  } finally {
    modelDeleteBusy.value = false
  }
}

// One button saves everything in the drawer — the item's own fields
// and every unit row, including condition changes — so there's only
// ever one place that can be "the thing you forgot to click." Adding a
// unit stays a separate, purely local action (addUnitRow below) that
// doesn't touch the database until this save runs.
const saving = ref(false)
const saveError = ref('')
const saveSuccess = ref(false)

// Bumped on every openEdit() call; a fetch only applies its result if
// it's still the most recent request when it resolves. Without this, a
// click on a second item before the first item's units finish loading
// can clobber the correct item's row list with the first item's stale
// units — and since saving sends unit_code for every row, those stale
// codes can collide with the second item's real ones and fail with a
// database "duplicate key" error that has nothing to do with whatever
// edit you actually made.
let editRequestId = 0

async function openEdit(item: ItemModel) {
  const requestId = ++editRequestId
  activeItem.value = item
  editForm.value = { ...item }
  saveError.value = ''
  saveSuccess.value = false
  activeUnitIndex.value = null
  unitsLoading.value = true
  units.value = []
  const { data, error: uErr } = await supabase
    .from('item_units_with_status')
    .select('id, unit_code, condition, condition_note, qr_code, serial_number, status, status_note, current_reservation_id')
    .eq('item_model_id', item.id)
    .order('unit_code')
  if (requestId !== editRequestId) return // a newer openEdit() has since started; drop this stale result
  if (uErr) {
    saveError.value = uErr.message
  } else {
    units.value = (data ?? []).map((u) => ({
      id: u.id,
      unit_code: u.unit_code,
      condition: u.condition as UnitCondition,
      originalCondition: u.condition as UnitCondition,
      condition_note: u.condition_note ?? '',
      qr_code: u.qr_code ?? '',
      serial_number: u.serial_number ?? '',
      status: u.status as UnitStatus,
      originalStatus: u.status as UnitStatus,
      status_note: u.status_note ?? '',
      current_reservation_id: u.current_reservation_id,
    }))
  }
  unitDeleteBlocked.value = {}
  unitDeleteConfirmId.value = null
  unitsLoading.value = false
}
// Closes the whole drawer — from the compact unit list or from inside
// a unit's own expanded card, "Close" always exits both.
function closeEdit() {
  activeItem.value = null
  activeUnitIndex.value = null
}
function openUnit(index: number) {
  activeUnitIndex.value = index
}
// "Back" only steps out of a unit's card, back to this item's compact
// unit list — it does not close the drawer.
function backToUnitList() {
  activeUnitIndex.value = null
}

function addUnitRow() {
  const numericCodes = units.value.map((u) => parseInt(u.unit_code, 10)).filter((n) => !isNaN(n))
  const next = numericCodes.length > 0 ? Math.max(...numericCodes) + 1 : units.value.length + 1
  units.value.push({
    id: null,
    unit_code: String(next),
    condition: 'good',
    originalCondition: 'good',
    condition_note: '',
    qr_code: '',
    serial_number: '',
    status: 'active',
    originalStatus: 'active',
    status_note: '',
    current_reservation_id: null,
  })
  // Jump straight into the new unit's card — you just asked to add
  // one, so you're almost certainly about to fill in its details.
  activeUnitIndex.value = units.value.length - 1
}

// Catches the mistakes that would otherwise only surface as an opaque
// database error after clicking Save: a duplicate unit code or QR code
// among this item's own units, or a condition downgrade with no note.
// (The database requires a note on any downgrade —
// item_units_condition_guard() in the initial schema migration is the
// source of truth this mirrors.) Returns a specific, actionable
// message, or '' if everything checks out.
function validateUnits(): string {
  const codeSeen = new Map<string, number>()
  const qrSeen = new Map<string, number>()

  for (const u of units.value) {
    const code = u.unit_code.trim()
    if (!code) return 'Every unit needs a code/number.'
    codeSeen.set(code, (codeSeen.get(code) ?? 0) + 1)

    const qr = u.qr_code.trim()
    if (qr) qrSeen.set(qr, (qrSeen.get(qr) ?? 0) + 1)

    // A brand-new row starting in anything but Good needs a note too
    // (same rule the trigger applies on insert); an existing row only
    // needs one if this save actually moves it to a worse condition.
    const isDowngrade = u.id
      ? conditionRank(u.condition) < conditionRank(u.originalCondition)
      : u.condition !== 'good'
    if (isDowngrade && !u.condition_note.trim()) {
      return `Unit #${code} is being set to "${conditionLabel(u.condition)}" — add a note before saving (required for anything less than Good).`
    }

    // Mirrors item_units_status_guard() exactly: a unit currently
    // checked out on an active reservation can't have its status
    // changed at all. Caught here instead of only on save so staff
    // see why, rather than an opaque database error.
    if (u.id && u.status !== u.originalStatus && u.current_reservation_id) {
      return `Unit #${code} is currently checked out on an active reservation — its status can't change until it's returned.`
    }
  }

  const dupCode = [...codeSeen.entries()].find(([, count]) => count > 1)
  if (dupCode) return `Unit code "${dupCode[0]}" is used by more than one unit here — codes must be unique.`

  const dupQr = [...qrSeen.entries()].find(([, count]) => count > 1)
  if (dupQr) return `QR code "${dupQr[0]}" is entered on more than one unit here — each code can only be used once.`

  return ''
}

async function saveAll() {
  if (!activeItem.value) return
  saveError.value = ''
  saveSuccess.value = false

  if (!editForm.value.name?.trim()) {
    saveError.value = 'Name is required.'
    return
  }
  const unitProblem = validateUnits()
  if (unitProblem) {
    saveError.value = unitProblem
    return
  }

  saving.value = true
  try {
    const { error: modelErr } = await supabase
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
    if (modelErr) throw modelErr

    for (const u of units.value) {
      const payload = {
        item_model_id: activeItem.value.id,
        unit_code: u.unit_code.trim(),
        condition: u.condition,
        condition_note: u.condition_note.trim() || null,
        qr_code: u.qr_code.trim() || null,
        serial_number: u.serial_number.trim() || null,
        status: u.status,
        status_note: u.status_note.trim() || null,
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
      u.originalCondition = u.condition
      u.originalStatus = u.status
    }

    // Reflect the model change in the list without a full reload.
    const idx = items.value.findIndex((i) => i.id === activeItem.value!.id)
    if (idx !== -1) items.value[idx] = { ...items.value[idx], ...editForm.value } as ItemModel

    saveSuccess.value = true
    // Edits here change what the catalog store has cached, which now
    // feeds both Browse Equipment and the top-nav search — force a
    // refetch so the change shows up without a full page reload.
    catalog.ensureLoaded(true)
  } catch (e) {
    // A real, unexpected failure — could be a genuine database error
    // (RLS, a race we didn't catch above) or, just as likely, the
    // request never reaching Supabase at all (project asleep, no
    // network, a timeout) — errorMessage() surfaces whichever it was
    // instead of masking it, since validateUnits() already handles the
    // common, expected cases above.
    saveError.value = errorMessage(e, 'Could not save your changes — please try again.')
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Inventory</span>
        <h1>Edit Items</h1>
        <p class="view-desc">
          Update an existing item's details, or click into one of its units to manage condition,
          QR code, and serial number.
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
        <div style="display: flex; align-items: center; justify-content: space-between">
          <h2 style="font-size: 19px">Edit {{ activeItem.name }}</h2>
          <button class="icon-btn" title="Close" aria-label="Close" @click="closeEdit">✕</button>
        </div>

        <!-- ---------- item fields + compact unit list ---------- -->
        <template v-if="activeUnitIndex === null">
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

          <!-- Deleting the whole item model -- only offered once it's
               confirmed safe (see checkModelDeleteBlockers). Anything
               with real history gets pointed at the Active checkbox
               above instead, same as a unit's Retire vs Delete split
               below. -->
          <div v-if="!modelDeleteConfirm">
            <button class="btn ghost small" @click="startModelDelete">Delete this item…</button>
          </div>
          <div v-else class="field-hint">
            <p v-if="modelDeleteChecking">Checking for attached history…</p>
            <template v-else-if="modelDeleteBlockedReason">
              <span class="lock-note">{{ modelDeleteBlockedReason }}</span>
              <div style="margin-top: 6px"><button class="btn ghost small" @click="cancelModelDeletePrompt">Close</button></div>
            </template>
            <template v-else>
              Permanently delete "{{ activeItem?.name }}"? This can't be undone.
              <div style="display: flex; gap: 8px; margin-top: 6px">
                <button class="btn primary small" :disabled="modelDeleteBusy" @click="confirmModelDelete">
                  Yes, delete it
                </button>
                <button class="btn ghost small" @click="cancelModelDeletePrompt">Never mind</button>
              </div>
            </template>
          </div>

          <hr class="divider" />

          <div class="section-title">Units</div>
          <p v-if="unitsLoading">Loading units…</p>
          <template v-else>
            <button
              v-for="(u, i) in units"
              :key="u.id ?? `new-${i}`"
              type="button"
              class="unit-row-compact"
              @click="openUnit(i)"
            >
              <span class="mono" style="width: 34px; text-align: left">{{ u.unit_code || '?' }}</span>
              <span class="badge" :class="u.id ? toneForCondition(u.condition) : 'accent'">{{
                u.id ? conditionLabel(u.condition) : 'new'
              }}</span>
              <span v-if="u.id && u.status !== 'active'" class="badge" :class="toneForUnitStatus(u.status)">{{
                unitStatusLabel(u.status)
              }}</span>
              <span class="unit-row-compact-meta">Serial: {{ u.serial_number || '—' }}</span>
              <span class="unit-row-compact-chevron" aria-hidden="true">›</span>
            </button>
            <!-- Adding a row is purely local (nothing is written until
                 "Save changes" below runs) — its own small, separate
                 button so it's never confused with saving. -->
            <button class="btn ghost small" style="align-self: flex-start" @click="addUnitRow">+ Add unit</button>
          </template>
        </template>

        <!-- ---------- one unit, enlarged into its own card ---------- -->
        <template v-else-if="activeUnit">
          <div style="display: flex; gap: 8px">
            <button class="btn ghost small" @click="backToUnitList">← Back to units</button>
          </div>

          <div class="card" style="display: flex; flex-direction: column; gap: 14px">
            <div style="display: flex; align-items: center; gap: 8px">
              <span class="section-title">Unit #{{ activeUnit.unit_code || '?' }}</span>
              <span class="badge" :class="activeUnit.id ? toneForCondition(activeUnit.condition) : 'accent'">{{
                activeUnit.id ? conditionLabel(activeUnit.condition) : 'new'
              }}</span>
              <span v-if="activeUnit.current_reservation_id" class="badge muted">checked out</span>
            </div>

            <div class="field">
              <label>Unit code / number</label>
              <input v-model="activeUnit.unit_code" type="text" class="mono" />
            </div>
            <div class="field">
              <label>Condition</label>
              <select v-model="activeUnit.condition">
                <option value="good">Good</option>
                <option value="caution">Caution</option>
                <option value="damaged">Damaged</option>
                <option value="missing">Missing</option>
              </select>
            </div>
            <div class="field">
              <label>Condition note</label>
              <textarea
                v-model="activeUnit.condition_note"
                rows="2"
                placeholder="Required if downgrading condition"
              ></textarea>
            </div>
            <div class="field">
              <label>QR code</label>
              <input v-model="activeUnit.qr_code" type="text" class="mono" placeholder="e.g. FC-3K9QZ2" />
            </div>
            <div class="field">
              <label>Serial number</label>
              <input
                v-model="activeUnit.serial_number"
                type="text"
                class="mono"
                placeholder="Manufacturer serial (if it has one)"
              />
            </div>

            <hr class="divider" />

            <!-- Status is a separate axis from Condition above --
                 "is this unit part of the working fleet right now,"
                 not a quality read. Locked while checked out, same
                 rule item_units_status_guard() enforces server-side. -->
            <div class="field">
              <label>Status</label>
              <select v-model="activeUnit.status" :disabled="!!activeUnit.current_reservation_id">
                <option value="active">Active</option>
                <option value="out_for_repair">Out for repair</option>
                <option value="retired">Retired</option>
                <option value="lost">Lost</option>
                <option value="stolen">Stolen</option>
              </select>
              <p v-if="activeUnit.current_reservation_id" class="field-hint">
                Checked out on an active reservation — status can't change until it's returned.
              </p>
            </div>
            <div class="field">
              <label>Status note (optional)</label>
              <textarea
                v-model="activeUnit.status_note"
                rows="2"
                placeholder="Why it's retired/lost/stolen/out for repair — not required"
              ></textarea>
            </div>

            <!-- Delete only once a saved unit is confirmed to have no
                 history; a brand-new, unsaved row just removes itself
                 locally. -->
            <template v-if="activeUnit.id">
              <div v-if="unitDeleteConfirmId !== activeUnit.id">
                <button class="btn ghost small" @click="startUnitDelete(activeUnit.id)">Delete this unit…</button>
              </div>
              <div v-else class="field-hint">
                <p v-if="unitDeleteBlocked[activeUnit.id] === undefined">Checking for attached history…</p>
                <template v-else-if="unitDeleteBlocked[activeUnit.id]">
                  <span class="lock-note">{{ unitDeleteBlocked[activeUnit.id] }}</span>
                  <div style="margin-top: 6px"><button class="btn ghost small" @click="cancelUnitDeletePrompt">Close</button></div>
                </template>
                <template v-else>
                  Permanently delete unit #{{ activeUnit.unit_code || '?' }}? This can't be undone.
                  <div style="display: flex; gap: 8px; margin-top: 6px">
                    <button
                      class="btn primary small"
                      :disabled="unitDeleteBusy[activeUnit.id]"
                      @click="confirmUnitDelete(activeUnit.id, activeUnitIndex as number)"
                    >
                      Yes, delete it
                    </button>
                    <button class="btn ghost small" @click="cancelUnitDeletePrompt">Never mind</button>
                  </div>
                </template>
              </div>
            </template>
            <button v-else class="btn ghost small" @click="removeUnitRow(activeUnitIndex as number)">Remove unit</button>
          </div>
        </template>

        <p v-if="saveError" class="error-note">{{ saveError }}</p>
        <p v-if="saveSuccess" style="color: var(--good); font-weight: 600">Saved.</p>
        <button class="btn primary" :disabled="saving || unitsLoading" @click="saveAll">
          {{ saving ? 'Saving…' : 'Save changes' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
.unit-row-compact {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 9px 4px;
  border: none;
  border-top: 1px solid var(--border);
  background: none;
  font: inherit;
  color: var(--ink);
  cursor: pointer;
  text-align: left;
}
.unit-row-compact:first-of-type {
  border-top: none;
}
.unit-row-compact:hover {
  background: var(--surface-2);
}
.unit-row-compact-meta {
  font-size: 12px;
  color: var(--ink-2);
  font-family: var(--font-mono);
}
.unit-row-compact-chevron {
  margin-left: auto;
  color: var(--ink-3);
}
</style>
