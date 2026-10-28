<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { toneForReservationStatus, reservationStatusLabel, type ReservationStatus } from '../lib/conditionStatus'
import { errorMessage } from '../lib/errors'

// Shared detail/edit page for a single reservation, linked from both
// ReservationQueueView and MyReservationsView -- "every reservation
// should be clickable... from that detail page, staff/admin should be
// able to edit... including removing items, changing pickup or
// dropoff times, cancelling... or for admin [extended to staff too],
// deleting." What's actually offered on this one shared page is
// computed purely from {who's looking, the row itself} -- not from
// which list sent them here, since the database doesn't distinguish
// those two paths either (see 20261019120000's own header comment).
//
// 10/21 client policy change: capstone reservations now go through the
// exact same approval path as a regular reservation (just a longer
// lead time, enforced by the trigger -- this page doesn't re-derive
// that math) and are editable here identically, no special case. The
// pre-pickup meeting (capstone_appointment_date/appointment_completed)
// is shown as a purely informational line; marking it complete is
// staff-only and lives on the Reservation Queue, not here.

const STAFF_PLUS = new Set(['staff', 'supervisor', 'admin'])
// Items can be added/removed on any of these -- "pending, approved,
// denied or waitlist status" -- never active/cancelled/completed.
// Dates are editable on this same set MINUS waitlisted -- a waitlist
// slot's window is what the item-availability check is matching
// against, so Suzanne's ask only ever covered its item list. Crew and
// equipment assignments (10/28) share this exact same window --
// migration 20261028120000 brought reservation_crew/reservation_assignments'
// own self-edit policies into parity with reservation_items' (same
// auto-approved-stays-editable carve-out, same dropped capstone
// exclusion), so there's nothing different to compute here.
const ITEM_EDITABLE_STATUSES = new Set(['pending', 'approved', 'denied', 'waitlisted'])
const DATE_EDITABLE_STATUSES = new Set(['pending', 'approved', 'denied'])
const LOCKED_STATUSES = new Set(['active', 'completed', 'cancelled'])
const CREW_ROLES = ['Producer', 'Camera Operator', 'Sound', 'Gaffer / Lighting', 'Grip', 'Editor']

interface ItemLine {
  id: string
  item_model_id: string
  quantity: number
  item_models: { name: string } | null
}
interface CrewRow {
  id: string
  user_id: string
  crew_role: string
  is_producer: boolean
  users: { full_name: string | null } | null
}
interface AssignmentRow {
  id: string
  item_model_id: string
  assigned_to_user_id: string
  quantity: number
}
interface ReservationRow {
  id: string
  reservation_name: string
  student_id: string
  status: ReservationStatus
  is_capstone: boolean
  is_group_reservation: boolean
  is_personal_use: boolean
  capstone_appointment_date: string | null
  appointment_completed: boolean
  pickup_date: string | null
  pickup_time: string | null
  dropoff_date: string | null
  dropoff_time: string | null
  denial_reason: string | null
  admin_notes: string | null
  approved_by: string | null
  approved_at: string | null
  created_at: string
  location_id: string
  locations: { name: string } | null
  reservation_items: ItemLine[]
  reservation_crew: CrewRow[]
  reservation_assignments: AssignmentRow[]
  student: { id: string; full_name: string | null; email: string | null; role: string } | null
}
interface ItemModelOption {
  id: string
  name: string
}
interface UserOption {
  id: string
  full_name: string
}
// A line's assignment can be one person holding the whole quantity
// (the common case) or, for a group reservation, split across more
// than one person when quantity > 1 -- same model and same reasoning
// as NewReservationView.vue's AssignmentSplit (migration 23). `id` is
// a client-only key for list rendering/removal, not a database id.
interface AssignmentSplit {
  id: number
  userId: string
  quantity: number
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const loading = ref(true)
const notFound = ref(false)
const error = ref('')
const saving = ref(false)
const saveError = ref('')
const row = ref<ReservationRow | null>(null)
const itemOptions = ref<ItemModelOption[]>([])
const editing = ref(false)

const RESERVATION_FIELDS = `id, reservation_name, student_id, status, is_capstone, is_group_reservation,
         is_personal_use, capstone_appointment_date, appointment_completed,
         pickup_date, pickup_time, dropoff_date, dropoff_time,
         denial_reason, admin_notes, approved_by, approved_at, created_at, location_id,
         locations(name),
         reservation_items(id, item_model_id, quantity, item_models(name)),
         reservation_crew(id, user_id, crew_role, is_producer, users(full_name)),
         reservation_assignments(id, item_model_id, assigned_to_user_id, quantity),
         student:users!reservations_student_id_fkey(id, full_name, email, role)`

async function load() {
  loading.value = true
  notFound.value = false
  error.value = ''
  try {
    const { data, error: err } = await supabase
      .from('reservations')
      .select(RESERVATION_FIELDS)
      .eq('id', route.params.id as string)
      .maybeSingle()
    if (err) throw err
    if (!data) {
      notFound.value = true
      return
    }
    row.value = data as unknown as ReservationRow
    if (route.query.edit === '1' && canEdit.value) startEdit()
  } catch (e) {
    error.value = errorMessage(e, 'Could not load this reservation.')
  } finally {
    loading.value = false
  }
}

async function loadItemOptions() {
  const { data } = await supabase.from('item_models').select('id, name').eq('is_active', true).order('name')
  itemOptions.value = (data ?? []) as ItemModelOption[]
}
loadItemOptions()
load()

const isStaffPlus = computed(() => STAFF_PLUS.has(auth.role ?? ''))
const isOwner = computed(() => !!row.value && row.value.student_id === auth.user?.id)
const isLocked = computed(() => !!row.value && LOCKED_STATUSES.has(row.value.status))

// The one rule that's identical for every role once it's your OWN
// reservation: full checks always apply to self-edits, and once a
// reservation that needed real review has been manually approved
// (approved_by set), editing disappears for good -- "once approval is
// given, no one will have the ability to edit... through the my
// reservation screen." A denied one stays self-editable (re-entering
// approval), matching the database's own rule (see migration
// 20261019120000) -- only approved_by actually locks anything.
function selfEditable(r: ReservationRow): boolean {
  if (r.status === 'approved') return r.approved_by == null
  if (r.status === 'waitlist_offered') return false
  return true
}

const canEdit = computed(() => {
  const r = row.value
  if (!r || isLocked.value) return false
  if (isOwner.value) return selfEditable(r)
  return isStaffPlus.value // staff+ editing someone else's -- any non-locked status
})
const canEditDates = computed(() => !!row.value && canEdit.value && DATE_EDITABLE_STATUSES.has(row.value.status))
const canEditItems = computed(() => !!row.value && canEdit.value && ITEM_EDITABLE_STATUSES.has(row.value.status))

// Cancel: once it's not active/completed/cancelled already --
// "available to the student who owns the reservation, even once it's
// already approved" (migration 20261006090000) -- but confirmed 10/19
// specifically for My Reservations that a reservation's own holder can
// only cancel their own Upcoming ones, never Active or Past, same
// bucket this page's callers use. That restriction is about SELF-
// service specifically -- staff+ cancelling someone else's from the
// Queue keeps the broader "just not locked" rule, no bucket
// restriction, matching ReservationQueueView.
const today = new Date().toISOString().slice(0, 10)
function bucketOf(r: ReservationRow): 'active' | 'upcoming' | 'past' {
  if (r.status === 'active') return 'active'
  const relevantDate = r.dropoff_date ?? r.pickup_date
  const datePassed = !!relevantDate && relevantDate < today
  if (r.status === 'completed' || r.status === 'cancelled' || r.status === 'denied' || datePassed) return 'past'
  return 'upcoming'
}
const canCancel = computed(() => {
  const r = row.value
  if (!r || isLocked.value) return false
  if (isOwner.value) return bucketOf(r) === 'upcoming'
  return isStaffPlus.value
})
// Delete: staff+ only, never active/completed/cancelled -- "we can
// extend it to staff as well" (Suzanne, confirming it isn't admin-only).
const canDelete = computed(() => !!row.value && isStaffPlus.value && !isLocked.value)

// A plain `staff` actor can never approve/deny their own -- supervisor
// and admin can. Mirrors the database guard exactly; this is only
// what decides whether the buttons show, the trigger is what actually
// enforces it.
const canApproveDeny = computed(() => {
  const r = row.value
  if (!r || r.status !== 'pending') return false
  if (!isStaffPlus.value) return false
  if (auth.role === 'staff' && isOwner.value) return false
  return true
})

function formatDate(d: string | null) {
  if (!d) return '—'
  return new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
}
function formatTime(t: string | null) {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}
function crewLine(r: ReservationRow) {
  if (!r.is_group_reservation || r.reservation_crew.length === 0) return null
  return r.reservation_crew.map((c) => `${c.users?.full_name ?? 'Unknown'} (${c.crew_role})`).join(', ')
}
// Capstone-only informational line — the pre-pickup meeting no longer
// gates status, so this is just shown alongside the normal pickup/
// drop-off schedule rather than instead of it.
function appointmentLine(r: ReservationRow) {
  return `Pre-pickup meeting: ${formatDate(r.capstone_appointment_date)} — ${r.appointment_completed ? 'Completed' : 'Not yet completed'}`
}

// ---- edit mode -----------------------------------------------------
const draftPickupDate = ref('')
const draftPickupTime = ref('')
const draftDropoffDate = ref('')
const draftDropoffTime = ref('')
interface ItemDraft {
  key: string // existing item id, or a client-side temp key for a new line
  id: string | null
  item_model_id: string
  quantity: number
  removed: boolean
}
const itemDrafts = reactive<ItemDraft[]>([])
const newItemModelId = ref('')
const newItemQuantity = ref(1)

// A crew member being edited: either an existing reservation_crew row
// (id set, soft-removable/undoable, mirrors ItemDraft's pattern) or one
// just added this session (id null, dropped outright on remove). The
// producer row is never removable -- it's the reservation's own owner.
interface CrewDraft {
  key: string
  id: string | null
  userId: string
  fullName: string
  role: string
  isProducer: boolean
  removed: boolean
}
const crewDrafts = reactive<CrewDraft[]>([])
const crewQuery = ref('')
const crewResults = ref<UserOption[]>([])
const showCrewResults = ref(false)
let crewSearchSeq = 0
const newCrewRole = ref('Camera Operator')
// item_model_id -> its assignment split rows -- same shape and
// reasoning as NewReservationView.vue's groundwork (migration 23).
// Every surviving item-draft line gets exactly one row by default (the
// whole quantity, assigned to the producer), seeded in startEdit()/
// addDraftLine() and kept in sync by syncSplitsToQuantity() whenever
// its quantity changes.
const assignmentSplits = reactive<Record<string, AssignmentSplit[]>>({})
let splitSeq = 0

// The reservation's own holder/producer -- always assignable, never
// removable from crew, and the fallback assignee for every split row.
const producerOption = computed<UserOption>(() => {
  const r = row.value
  const fromCrew = r?.reservation_crew.find((c) => c.is_producer)
  if (fromCrew) return { id: fromCrew.user_id, full_name: fromCrew.users?.full_name ?? 'Producer' }
  return { id: r?.student_id ?? '', full_name: r?.student?.full_name ?? 'Producer' }
})
const assigneeOptions = computed<UserOption[]>(() => [
  producerOption.value,
  ...crewDrafts
    .filter((c) => !c.removed && !c.isProducer && c.userId)
    .map((c) => ({ id: c.userId, full_name: `${c.fullName} (${c.role})` })),
])
// If someone assigned a split drops off the crew list (or was never
// valid), fall back to the producer rather than leaving a dangling id.
watch(assigneeOptions, (opts) => {
  const validIds = new Set(opts.map((o) => o.id))
  for (const rows of Object.values(assignmentSplits)) {
    for (const split of rows) {
      if (!split.userId || !validIds.has(split.userId)) split.userId = producerOption.value.id
    }
  }
})

function draftQuantityFor(itemModelId: string): number {
  return itemDrafts.find((l) => l.item_model_id === itemModelId && !l.removed)?.quantity ?? 0
}
function splitsFor(itemModelId: string): AssignmentSplit[] {
  return assignmentSplits[itemModelId] ?? []
}
function isSplit(itemModelId: string): boolean {
  return splitsFor(itemModelId).length > 1
}
function splitRemainder(itemModelId: string): number {
  const sum = splitsFor(itemModelId).reduce((s, r) => s + r.quantity, 0)
  return draftQuantityFor(itemModelId) - sum
}
function ensureSplits(itemModelId: string, quantity: number) {
  if (assignmentSplits[itemModelId]?.length) return
  assignmentSplits[itemModelId] = [{ id: ++splitSeq, userId: producerOption.value.id, quantity }]
}
function syncSplitsToQuantity(itemModelId: string, quantity: number) {
  const rows = assignmentSplits[itemModelId]
  if (!rows || rows.length === 0) {
    ensureSplits(itemModelId, quantity)
    return
  }
  let remaining = quantity - rows.reduce((s, r) => s + r.quantity, 0)
  let i = rows.length - 1
  while (remaining !== 0 && i >= 0) {
    const r = rows[i]
    const newQty = r.quantity + remaining
    if (newQty >= 1) {
      r.quantity = newQty
      remaining = 0
    } else if (rows.length > 1) {
      remaining = newQty
      rows.splice(i, 1)
    } else {
      r.quantity = 1
      remaining = 0
    }
    i--
  }
}
function addSplitRow(itemModelId: string) {
  const rows = assignmentSplits[itemModelId]
  if (!rows || rows.length === 0) return
  const donor = rows.reduce((best, r) => (r.quantity > (best?.quantity ?? 0) ? r : best), null as AssignmentSplit | null)
  if (!donor || donor.quantity <= 1) return
  donor.quantity -= 1
  rows.push({ id: ++splitSeq, userId: '', quantity: 1 })
}
function removeSplitRow(itemModelId: string, id: number) {
  const rows = assignmentSplits[itemModelId]
  if (!rows) return
  const idx = rows.findIndex((r) => r.id === id)
  if (idx === -1 || rows.length <= 1) return
  const [removed] = rows.splice(idx, 1)
  const target = rows[idx - 1] ?? rows[0]
  if (target) target.quantity += removed.quantity
}
function clampSplitQuantity(itemModelId: string, id: number) {
  const rows = assignmentSplits[itemModelId]
  if (!rows) return
  const row = rows.find((r) => r.id === id)
  if (!row) return
  const othersSum = rows.filter((r) => r.id !== id).reduce((s, r) => s + r.quantity, 0)
  const max = Math.max(1, draftQuantityFor(itemModelId) - othersSum)
  const parsed = Math.floor(Number(row.quantity))
  row.quantity = Math.min(Math.max(1, Number.isFinite(parsed) && parsed > 0 ? parsed : 1), max)
}
function onItemQuantityChange(line: ItemDraft) {
  syncSplitsToQuantity(line.item_model_id, line.quantity)
}

async function onCrewQueryInput() {
  const mySeq = ++crewSearchSeq
  const q = crewQuery.value.trim()
  if (q.length < 2) {
    crewResults.value = []
    showCrewResults.value = false
    return
  }
  const { data } = await supabase.from('users').select('id, full_name').ilike('full_name', `%${q}%`).limit(6)
  if (mySeq !== crewSearchSeq) return
  const taken = new Set(crewDrafts.filter((c) => !c.removed && c.userId).map((c) => c.userId))
  taken.add(producerOption.value.id)
  crewResults.value = ((data ?? []) as UserOption[]).filter((u) => !taken.has(u.id))
  showCrewResults.value = true
}
function chooseCrewResult(user: UserOption) {
  crewDrafts.push({
    key: `new-${user.id}-${Date.now()}`,
    id: null,
    userId: user.id,
    fullName: user.full_name,
    role: newCrewRole.value,
    isProducer: false,
    removed: false,
  })
  crewQuery.value = ''
  crewResults.value = []
  showCrewResults.value = false
  newCrewRole.value = 'Camera Operator'
}
function hideCrewResultsSoon() {
  setTimeout(() => {
    showCrewResults.value = false
  }, 150)
}
function removeCrewDraft(key: string) {
  const c = crewDrafts.find((d) => d.key === key)
  if (!c || c.isProducer) return
  if (c.id === null) {
    const idx = crewDrafts.indexOf(c)
    crewDrafts.splice(idx, 1)
  } else {
    c.removed = true
  }
}
function restoreCrewDraft(key: string) {
  const c = crewDrafts.find((d) => d.key === key)
  if (c) c.removed = false
}

function startEdit() {
  const r = row.value
  if (!r || !canEdit.value) return
  draftPickupDate.value = r.pickup_date ?? ''
  draftPickupTime.value = r.pickup_time ?? ''
  draftDropoffDate.value = r.dropoff_date ?? ''
  draftDropoffTime.value = r.dropoff_time ?? ''
  itemDrafts.splice(
    0,
    itemDrafts.length,
    ...r.reservation_items.map((l) => ({ key: l.id, id: l.id, item_model_id: l.item_model_id, quantity: l.quantity, removed: false }))
  )
  crewDrafts.splice(
    0,
    crewDrafts.length,
    ...r.reservation_crew.map((c) => ({
      key: c.id,
      id: c.id,
      userId: c.user_id,
      fullName: c.users?.full_name ?? 'Unknown',
      role: c.crew_role,
      isProducer: c.is_producer,
      removed: false,
    }))
  )
  crewQuery.value = ''
  crewResults.value = []
  showCrewResults.value = false
  newCrewRole.value = 'Camera Operator'
  for (const key of Object.keys(assignmentSplits)) delete assignmentSplits[key]
  splitSeq = 0
  for (const line of itemDrafts) {
    const existing = r.reservation_assignments.filter((a) => a.item_model_id === line.item_model_id)
    if (existing.length) {
      assignmentSplits[line.item_model_id] = existing.map((a) => ({ id: ++splitSeq, userId: a.assigned_to_user_id, quantity: a.quantity }))
    } else {
      ensureSplits(line.item_model_id, line.quantity)
    }
  }
  saveError.value = ''
  editing.value = true
}
function cancelEdit() {
  editing.value = false
  saveError.value = ''
}
function removeDraftLine(key: string) {
  const line = itemDrafts.find((l) => l.key === key)
  if (!line) return
  if (line.id === null) {
    // a line that was only ever added client-side this session -- drop it outright
    const idx = itemDrafts.indexOf(line)
    itemDrafts.splice(idx, 1)
    delete assignmentSplits[line.item_model_id]
  } else {
    line.removed = true
  }
}
function restoreDraftLine(key: string) {
  const line = itemDrafts.find((l) => l.key === key)
  if (line) line.removed = false
}
function itemName(itemModelId: string) {
  return itemOptions.value.find((o) => o.id === itemModelId)?.name ?? 'Unknown item'
}
function addDraftLine() {
  if (!newItemModelId.value || newItemQuantity.value < 1) return
  const existing = itemDrafts.find((l) => l.item_model_id === newItemModelId.value && !l.removed)
  if (existing) {
    existing.quantity += newItemQuantity.value
    syncSplitsToQuantity(existing.item_model_id, existing.quantity)
  } else {
    itemDrafts.push({
      key: `new-${newItemModelId.value}-${Date.now()}`,
      id: null,
      item_model_id: newItemModelId.value,
      quantity: newItemQuantity.value,
      removed: false,
    })
    ensureSplits(newItemModelId.value, newItemQuantity.value)
  }
  newItemModelId.value = ''
  newItemQuantity.value = 1
}

async function saveEdit() {
  const r = row.value
  if (!r) return
  saving.value = true
  saveError.value = ''
  try {
    if (canEditDates.value) {
      if (!draftPickupDate.value || !draftPickupTime.value || !draftDropoffDate.value || !draftDropoffTime.value) {
        saveError.value = 'Pickup and drop-off dates and times are both required.'
        return
      }
      if (
        draftDropoffDate.value < draftPickupDate.value ||
        (draftDropoffDate.value === draftPickupDate.value && draftDropoffTime.value <= draftPickupTime.value)
      ) {
        saveError.value = 'Drop-off must be after pickup.'
        return
      }
    }

    // Crew/assignment validation -- mirrors NewReservationView.vue's
    // validate() exactly, just over the surviving (not-removed) draft
    // lines instead of `lines`.
    if (canEditItems.value && r.is_group_reservation) {
      for (const line of itemDrafts.filter((l) => !l.removed)) {
        if (splitRemainder(line.item_model_id) !== 0) {
          saveError.value = `${itemName(line.item_model_id)}'s assigned quantities must add up to ${line.quantity}.`
          return
        }
        if (splitsFor(line.item_model_id).some((s) => !s.userId)) {
          saveError.value = `Pick a person for every assignment row on ${itemName(line.item_model_id)}.`
          return
        }
      }
    }

    // Crew changes -- share canEditItems' window exactly (see the
    // ITEM_EDITABLE_STATUSES comment above). Editing an existing
    // member's role isn't offered yet, only add/remove, matching what
    // Suzanne actually asked for ("the ability to edit who is on the
    // reservation").
    if (canEditItems.value && r.is_group_reservation) {
      const toDeleteCrew = crewDrafts.filter((c) => c.removed && c.id)
      const toAddCrew = crewDrafts.filter((c) => !c.removed && c.id === null)
      for (const c of toDeleteCrew) {
        const { error: err } = await supabase.from('reservation_crew').delete().eq('id', c.id!)
        if (err) throw err
      }
      if (toAddCrew.length) {
        const { error: err } = await supabase
          .from('reservation_crew')
          .insert(toAddCrew.map((c) => ({ reservation_id: r.id, user_id: c.userId, crew_role: c.role, is_producer: false })))
        if (err) throw err
      }
    }

    // Item changes next -- the subsequent reservations-row update (or,
    // if nothing else changed, an explicit re-fire touch) is what makes
    // reservations_approval_guard recompute against the new item list,
    // the same re-fire NewReservationView.vue already relies on.
    if (canEditItems.value) {
      const toDelete = itemDrafts.filter((l) => l.removed && l.id)
      const toAdd = itemDrafts.filter((l) => !l.removed && l.id === null)
      const toUpdate = itemDrafts.filter((l) => !l.removed && l.id !== null)

      for (const line of toDelete) {
        const { error: err } = await supabase.from('reservation_items').delete().eq('id', line.id!)
        if (err) throw err
      }
      for (const line of toUpdate) {
        const { error: err } = await supabase.from('reservation_items').update({ quantity: line.quantity }).eq('id', line.id!)
        if (err) throw err
      }
      for (const line of toAdd) {
        const { error: err } = await supabase
          .from('reservation_items')
          .insert({ reservation_id: r.id, item_model_id: line.item_model_id, quantity: line.quantity })
        if (err) throw err
      }

      // Equipment assignments (group reservations only) -- replace each
      // surviving line's assignment rows wholesale with its current
      // split rows, and drop assignments for any line that got removed.
      // A full delete+reinsert per line is simpler than a row-by-row
      // diff and just as correct, since this only runs on an explicit
      // save and a line's rows are always a handful at most. Mirrors
      // NewReservationView.vue's submit-time merge-by-Map pattern so
      // two split rows that ended up on the same person collapse into
      // one, rather than trying (and failing) to insert two rows for
      // the same person on the same item.
      if (r.is_group_reservation) {
        for (const line of toDelete) {
          const { error: err } = await supabase
            .from('reservation_assignments')
            .delete()
            .eq('reservation_id', r.id)
            .eq('item_model_id', line.item_model_id)
          if (err) throw err
        }
        for (const line of itemDrafts.filter((l) => !l.removed)) {
          const { error: delErr } = await supabase
            .from('reservation_assignments')
            .delete()
            .eq('reservation_id', r.id)
            .eq('item_model_id', line.item_model_id)
          if (delErr) throw delErr
          const splits = splitsFor(line.item_model_id)
          const merged = new Map<string, number>()
          for (const split of splits.length ? splits : [{ id: 0, userId: producerOption.value.id, quantity: line.quantity }]) {
            const userId = split.userId || producerOption.value.id
            merged.set(userId, (merged.get(userId) ?? 0) + split.quantity)
          }
          const assignmentRows = Array.from(merged.entries()).map(([assigned_to_user_id, quantity]) => ({
            reservation_id: r.id,
            item_model_id: line.item_model_id,
            assigned_to_user_id,
            quantity,
          }))
          const { error: insErr } = await supabase.from('reservation_assignments').insert(assignmentRows)
          if (insErr) throw insErr
        }
      }
    }

    // Editing a denied reservation has to explicitly ask to re-enter
    // the approval flow -- 'denied' is one of reservations_approval_guard's
    // untouchable_statuses, so without this it would silently keep
    // whatever fields changed but stay denied forever. Same escape
    // hatch confirm_waitlist_entry() already uses.
    const reservationPatch: Record<string, unknown> = {}
    if (canEditDates.value) {
      reservationPatch.pickup_date = draftPickupDate.value
      reservationPatch.pickup_time = draftPickupTime.value
      reservationPatch.dropoff_date = draftDropoffDate.value
      reservationPatch.dropoff_time = draftDropoffTime.value
    }
    if (r.status === 'denied') {
      reservationPatch.status = 'pending'
    }
    if (Object.keys(reservationPatch).length === 0) {
      // Items-only edit on a pending/approved/waitlisted reservation --
      // still needs a touch so the trigger re-evaluates the new item
      // count/availability.
      reservationPatch.pickup_date = r.pickup_date
    }
    const { error: err } = await supabase.from('reservations').update(reservationPatch).eq('id', r.id)
    if (err) throw err

    editing.value = false
    await load()
  } catch (e) {
    saveError.value = errorMessage(e, 'Could not save these changes.')
  } finally {
    saving.value = false
  }
}

// ---- cancel / delete / approve / deny ------------------------------
const confirmingCancel = ref(false)
const confirmingDelete = ref(false)
const deleteBlockers = ref<{ fines: number; reviews: number; occurrences: number } | null>(null)
const denying = ref(false)
const denyReason = ref('')
const busy = ref(false)
const actionError = ref('')

async function approve() {
  if (!row.value) return
  busy.value = true
  actionError.value = ''
  try {
    const { error: err } = await supabase
      .from('reservations')
      .update({ status: 'approved', approved_by: auth.user!.id, approved_at: new Date().toISOString() })
      .eq('id', row.value.id)
    if (err) throw err
    await load()
  } catch (e) {
    actionError.value = errorMessage(e, 'Could not approve this reservation.')
  } finally {
    busy.value = false
  }
}
function startDeny() {
  denying.value = true
  denyReason.value = ''
}
async function confirmDeny() {
  if (!row.value || !denyReason.value.trim()) return
  busy.value = true
  actionError.value = ''
  try {
    const { error: err } = await supabase
      .from('reservations')
      .update({ status: 'denied', denial_reason: denyReason.value.trim() })
      .eq('id', row.value.id)
    if (err) throw err
    denying.value = false
    await load()
  } catch (e) {
    actionError.value = errorMessage(e, 'Could not deny this reservation.')
  } finally {
    busy.value = false
  }
}
async function doCancel() {
  if (!row.value) return
  busy.value = true
  actionError.value = ''
  try {
    const { error: err } = await supabase.from('reservations').update({ status: 'cancelled' }).eq('id', row.value.id)
    if (err) throw err
    confirmingCancel.value = false
    await load()
  } catch (e) {
    actionError.value = errorMessage(e, 'Could not cancel this reservation.')
  } finally {
    busy.value = false
  }
}
async function openDeletePrompt() {
  if (!row.value) return
  confirmingDelete.value = true
  const [fines, reviews, occurrences] = await Promise.all([
    supabase.from('fines').select('id', { count: 'exact', head: true }).eq('reservation_id', row.value.id),
    supabase.from('condition_reviews').select('id', { count: 'exact', head: true }).eq('reservation_id', row.value.id),
    supabase.from('recurring_reservation_occurrences').select('id', { count: 'exact', head: true }).eq('reservation_id', row.value.id),
  ])
  deleteBlockers.value = { fines: fines.count ?? 0, reviews: reviews.count ?? 0, occurrences: occurrences.count ?? 0 }
}
const deleteBlockedReason = computed(() => {
  const c = deleteBlockers.value
  if (!c) return null
  const parts: string[] = []
  if (c.fines > 0) parts.push(`${c.fines} fine${c.fines > 1 ? 's' : ''}`)
  if (c.reviews > 0) parts.push(`${c.reviews} condition review${c.reviews > 1 ? 's' : ''}`)
  if (c.occurrences > 0) parts.push('a recurring-reservation link')
  if (parts.length === 0) return null
  return `Has ${parts.join(', ')} attached — cancel instead to keep that history.`
})
async function doDelete() {
  if (!row.value) return
  busy.value = true
  actionError.value = ''
  try {
    const { error: err } = await supabase.from('reservations').delete().eq('id', row.value.id)
    if (err) throw err
    router.back()
  } catch (e) {
    actionError.value = errorMessage(e, 'Could not delete this reservation — it may have history attached that blocks deletion.')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <button class="btn ghost small" @click="router.back()">← Back</button>
      </div>
    </div>

    <p v-if="loading">Loading…</p>
    <p v-else-if="error" class="error-note">{{ error }}</p>
    <p v-else-if="notFound" class="empty-note">Reservation not found.</p>

    <div v-else-if="row" class="card">
      <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; flex-wrap: wrap">
        <div>
          <div style="display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
            <span class="badge accent" v-if="row.is_capstone">Capstone</span>
            <span class="badge violet" v-if="row.is_group_reservation">Group production</span>
            <span class="badge" v-if="row.is_personal_use">Personal use</span>
          </div>
          <h1 style="margin-top: 6px">{{ row.reservation_name }}</h1>
          <div style="font-size: 13px; color: var(--ink-2); margin-top: 2px">
            {{ row.student?.full_name ?? row.student?.email ?? 'Unknown student' }} · {{ row.locations?.name ?? '—' }}
          </div>
        </div>
        <span class="badge" :class="toneForReservationStatus(row.status)">{{ reservationStatusLabel(row.status) }}</span>
      </div>

      <div v-if="row.is_capstone" class="field-hint" style="margin-top: 10px">{{ appointmentLine(row) }}</div>

      <div v-if="row.status === 'denied' && row.denial_reason" class="lock-note" style="margin-top: 10px">
        Denied: {{ row.denial_reason }}
      </div>
      <div v-if="isLocked" class="field-hint" style="margin-top: 10px">
        This reservation is {{ reservationStatusLabel(row.status).toLowerCase() }} and can no longer be changed.
      </div>
      <div v-else-if="row.status === 'approved' && row.approved_by && isOwner" class="field-hint" style="margin-top: 10px">
        This reservation was manually approved — ask another staff member, a supervisor, or an admin for further changes.
      </div>

      <!-- ---- view mode ---- -->
      <template v-if="!editing">
        <div style="margin-top: 14px; display: grid; grid-template-columns: 1fr 1fr; gap: 14px">
          <div>
            <div class="field-hint">Pickup</div>
            <div>{{ formatDate(row.pickup_date) }} {{ formatTime(row.pickup_time) }}</div>
          </div>
          <div>
            <div class="field-hint">Drop-off</div>
            <div>{{ formatDate(row.dropoff_date) }} {{ formatTime(row.dropoff_time) }}</div>
          </div>
        </div>

        <div style="margin-top: 14px">
          <div class="field-hint">Items</div>
          <ul style="margin: 6px 0 0; padding-left: 18px">
            <li v-for="line in row.reservation_items" :key="line.id">
              {{ line.item_models?.name ?? 'Unknown item' }}<template v-if="line.quantity > 1"> ×{{ line.quantity }}</template>
            </li>
            <li v-if="row.reservation_items.length === 0" class="field-hint">No items on this reservation.</li>
          </ul>
        </div>

        <div v-if="crewLine(row)" class="field-hint" style="margin-top: 10px">Crew: {{ crewLine(row) }}</div>

        <p v-if="actionError" class="error-note" style="margin-top: 10px">{{ actionError }}</p>

        <div style="display: flex; gap: 8px; margin-top: 16px; flex-wrap: wrap">
          <button v-if="canEdit" class="btn small" :disabled="busy" @click="startEdit">Edit</button>
          <button
            v-if="canApproveDeny"
            class="btn small"
            :class="row.is_capstone ? 'capstone' : 'primary'"
            :disabled="busy"
            @click="approve"
          >
            {{ row.is_capstone ? 'Approve (Capstone)' : 'Approve' }}
          </button>
          <button v-if="canApproveDeny" class="btn ghost small" :disabled="busy" @click="startDeny">Deny</button>
          <button v-if="canCancel && !confirmingCancel" class="btn ghost small" :disabled="busy" @click="confirmingCancel = true">
            Cancel reservation
          </button>
          <button v-if="canDelete && !confirmingDelete" class="btn ghost small" :disabled="busy" @click="openDeletePrompt">Delete…</button>
        </div>

        <div v-if="denying" class="field" style="margin-top: 10px">
          <label>Reason for denial</label>
          <textarea v-model="denyReason" rows="2" placeholder="Shown to the student" />
          <div style="display: flex; gap: 8px; margin-top: 6px">
            <button class="btn primary small" :disabled="busy || !denyReason.trim()" @click="confirmDeny">Confirm deny</button>
            <button class="btn ghost small" @click="denying = false">Never mind</button>
          </div>
        </div>

        <div v-if="confirmingCancel" class="field-hint" style="margin-top: 10px">
          Cancel this reservation? {{ isOwner ? "This can't be undone." : 'The student will see it as cancelled.' }}
          <div style="display: flex; gap: 8px; margin-top: 6px">
            <button class="btn primary small" :disabled="busy" @click="doCancel">Yes, cancel it</button>
            <button class="btn ghost small" @click="confirmingCancel = false">Never mind</button>
          </div>
        </div>

        <div v-if="confirmingDelete" class="field-hint" style="margin-top: 10px">
          <template v-if="deleteBlockedReason">
            <span class="lock-note">{{ deleteBlockedReason }}</span>
            <div style="margin-top: 6px"><button class="btn ghost small" @click="confirmingDelete = false">Close</button></div>
          </template>
          <template v-else-if="deleteBlockers">
            Permanently delete this reservation? This can't be undone.
            <div style="display: flex; gap: 8px; margin-top: 6px">
              <button class="btn primary small" :disabled="busy" @click="doDelete">Yes, delete it</button>
              <button class="btn ghost small" @click="confirmingDelete = false">Never mind</button>
            </div>
          </template>
        </div>
      </template>

      <!-- ---- edit mode ---- -->
      <template v-else>
        <div v-if="canEditDates" style="margin-top: 14px">
          <div class="field-row">
            <div class="field">
              <label>Pickup date</label>
              <input v-model="draftPickupDate" type="date" />
            </div>
            <div class="field">
              <label>Pickup time</label>
              <input v-model="draftPickupTime" type="time" />
            </div>
          </div>
          <div class="field-row" style="margin-top: 10px">
            <div class="field">
              <label>Drop-off date</label>
              <input v-model="draftDropoffDate" type="date" />
            </div>
            <div class="field">
              <label>Drop-off time</label>
              <input v-model="draftDropoffTime" type="time" />
            </div>
          </div>
        </div>
        <div v-else class="field-hint" style="margin-top: 14px">
          Dates aren't editable while waitlisted — remove and re-add items instead, or ask the student to cancel and rebook.
        </div>

        <div v-if="row.is_group_reservation && canEditItems" style="margin-top: 16px">
          <div class="field-hint">Crew</div>
          <div style="display: flex; flex-direction: column; gap: 6px; margin-top: 6px">
            <div
              v-for="c in crewDrafts"
              :key="c.key"
              style="display: flex; align-items: center; gap: 8px"
              :style="c.removed ? 'opacity: 0.5' : ''"
            >
              <span style="flex: 1">{{ c.fullName }} ({{ c.isProducer ? 'Producer' : c.role }})</span>
              <span v-if="c.isProducer" class="field-hint">Owner — can't be removed</span>
              <button v-else-if="!c.removed" class="btn ghost small" @click="removeCrewDraft(c.key)">Remove</button>
              <button v-else class="btn ghost small" @click="restoreCrewDraft(c.key)">Undo</button>
            </div>
            <div v-if="crewDrafts.length === 0" class="field-hint">No crew on this reservation.</div>
          </div>
          <div style="display: flex; align-items: flex-end; gap: 8px; margin-top: 10px">
            <div class="field autocomplete-wrap" style="flex: 1">
              <label>Add crew member</label>
              <input
                v-model="crewQuery"
                type="text"
                placeholder="Type a name…"
                @input="onCrewQueryInput"
                @focus="onCrewQueryInput"
                @blur="hideCrewResultsSoon"
              />
              <div v-if="showCrewResults && crewResults.length" class="autocomplete-list">
                <div v-for="u in crewResults" :key="u.id" class="autocomplete-item" @mousedown="chooseCrewResult(u)">
                  {{ u.full_name }}
                </div>
              </div>
            </div>
            <div class="field" style="width: 150px">
              <label>Role</label>
              <select v-model="newCrewRole">
                <option v-for="roleOpt in CREW_ROLES" :key="roleOpt">{{ roleOpt }}</option>
              </select>
            </div>
          </div>
        </div>

        <div v-if="canEditItems" style="margin-top: 16px">
          <div class="field-hint">Items</div>
          <div style="display: flex; flex-direction: column; gap: 10px; margin-top: 6px">
            <div v-for="line in itemDrafts" :key="line.key" style="display: flex; flex-direction: column; gap: 6px">
              <div style="display: flex; align-items: center; gap: 8px" :style="line.removed ? 'opacity: 0.5' : ''">
                <span style="flex: 1">{{ itemName(line.item_model_id) }}</span>
                <input
                  v-model.number="line.quantity"
                  type="number"
                  min="1"
                  style="width: 70px"
                  :disabled="line.removed"
                  @change="onItemQuantityChange(line)"
                />
                <select
                  v-if="row.is_group_reservation && !line.removed && !isSplit(line.item_model_id)"
                  v-model="splitsFor(line.item_model_id)[0].userId"
                  style="font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink)"
                >
                  <option v-for="opt in assigneeOptions" :key="opt.id" :value="opt.id">{{ opt.full_name }}</option>
                </select>
                <button
                  v-if="row.is_group_reservation && !line.removed && line.quantity > 1 && !isSplit(line.item_model_id)"
                  class="btn ghost small"
                  @click="addSplitRow(line.item_model_id)"
                >
                  Split between people
                </button>
                <button v-if="!line.removed" class="btn ghost small" @click="removeDraftLine(line.key)">Remove</button>
                <button v-else class="btn ghost small" @click="restoreDraftLine(line.key)">Undo</button>
              </div>

              <div
                v-if="row.is_group_reservation && !line.removed && isSplit(line.item_model_id)"
                style="display: flex; flex-direction: column; gap: 6px; padding-left: 10px; border-left: 2px solid var(--border-strong)"
              >
                <div
                  v-for="split in splitsFor(line.item_model_id)"
                  :key="split.id"
                  style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap"
                >
                  <input
                    v-model.number="split.quantity"
                    type="number"
                    min="1"
                    :max="line.quantity"
                    style="width: 54px; font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink)"
                    @change="clampSplitQuantity(line.item_model_id, split.id)"
                  />
                  <select
                    v-model="split.userId"
                    style="font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink); flex: 1"
                  >
                    <option value="" disabled>Select a person…</option>
                    <option v-for="opt in assigneeOptions" :key="opt.id" :value="opt.id">{{ opt.full_name }}</option>
                  </select>
                  <button class="icon-btn" style="width: 24px; height: 24px" @click="removeSplitRow(line.item_model_id, split.id)">✕</button>
                </div>
                <button
                  class="btn ghost small"
                  style="align-self: flex-start"
                  :disabled="splitsFor(line.item_model_id).every((s) => s.quantity <= 1)"
                  @click="addSplitRow(line.item_model_id)"
                >
                  + Add another person
                </button>
                <p v-if="splitRemainder(line.item_model_id) !== 0" class="error-note" style="font-size: 11.5px">
                  These need to add up to {{ line.quantity }} — currently {{ line.quantity - splitRemainder(line.item_model_id) }}.
                </p>
              </div>
            </div>
            <div v-if="itemDrafts.length === 0" class="field-hint">No items on this reservation.</div>
          </div>
          <div style="display: flex; align-items: flex-end; gap: 8px; margin-top: 10px">
            <div class="field" style="flex: 1">
              <label>Add an item</label>
              <select v-model="newItemModelId">
                <option value="">Select equipment…</option>
                <option v-for="opt in itemOptions" :key="opt.id" :value="opt.id">{{ opt.name }}</option>
              </select>
            </div>
            <div class="field" style="width: 80px">
              <label>Qty</label>
              <input v-model.number="newItemQuantity" type="number" min="1" />
            </div>
            <button class="btn small" :disabled="!newItemModelId" @click="addDraftLine">Add</button>
          </div>
        </div>

        <p v-if="saveError" class="error-note" style="margin-top: 10px">{{ saveError }}</p>

        <div style="display: flex; gap: 8px; margin-top: 16px">
          <button class="btn primary small" :disabled="saving" @click="saveEdit">{{ saving ? 'Saving…' : 'Save changes' }}</button>
          <button class="btn ghost small" :disabled="saving" @click="cancelEdit">Cancel</button>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
textarea {
  width: 100%;
  resize: vertical;
}
/* Matches ReservationQueueView.vue's capstone Approve button styling —
   keep these in sync. */
.btn.capstone {
  background: var(--violet);
  border-color: var(--violet);
  color: var(--accent-ink);
}
.btn.capstone:hover {
  opacity: 0.9;
}
</style>
