<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from '../stores/auth'
import { useCatalogStore, type CatalogItem } from '../stores/catalog'
import { errorMessage } from '../lib/errors'

// Mirrors reservations_approval_guard()'s threshold exactly (see the
// reservations migration) — informational only on this side; the
// database is what actually enforces it.
const APPROVAL_ITEM_THRESHOLD = 20
const LEAD_TIME_DAYS = 3
// Client policy change, 10/21: a capstone reservation needs 7 days'
// lead time, not 3 -- everything else (item count, Friday, the
// 3-day loan window, the hard inventory check) is identical to a
// regular reservation. Mirrors reservations_approval_guard() exactly.
const CAPSTONE_LEAD_TIME_DAYS = 7
const LOAN_WINDOW_DAYS = 3
const CREW_ROLES = ['Producer', 'Camera Operator', 'Sound', 'Gaffer / Lighting', 'Grip', 'Editor']
// Mirrors reservations_insert_own_or_staff / reservations_personal_use_guard --
// only these three roles can set student_id to someone else, or flag
// is_personal_use at all. class_instructor gets the same self-service
// flow as a student, just exempt from the lead-time/loan-window checks
// below (reservations_approval_guard waives those for any non-student
// holder, same as for a staff+ actor).
const STAFF_PLUS_ROLES = ['staff', 'supervisor', 'admin']

interface LocationHours {
  day_of_week: string
  is_open: boolean
  appointment_only: boolean
  open_time: string | null
  close_time: string | null
}
interface Closure {
  date: string
  reason: string
}
interface UserOption {
  id: string
  full_name: string
}
interface TargetOption {
  id: string
  full_name: string
  email: string
  role: string
}
interface CrewRow {
  tempId: number
  userId: string | null
  fullName: string
  role: string
  query: string
  results: UserOption[]
  showResults: boolean
}
interface ReservationLine {
  itemModelId: string
  name: string
  quantity: number
  maxAvailable: number
}
// A line's assignment can be a single person holding the whole
// quantity (the common case -- one row, covering it all) or, for a
// group reservation, split across more than one person when the
// quantity is > 1 (migration 23: reservation_assignments now allows
// more than one row per item model per reservation, each with its own
// quantity, as long as they sum to the item's total). `id` is a
// client-only key for list rendering/removal, not a database id.
interface AssignmentSplit {
  id: number
  userId: string
  quantity: number
}
interface WaitlistRequest {
  itemModelId: string
  name: string
  quantity: number
}

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const catalog = useCatalogStore()

// Set from Browse Equipment's "start a reservation to check
// availability" prompt (?item=<id>&location=<locationId>) -- the item
// itself can't be picked until canPickItems is true (location + a
// real window, or capstone), so this just waits for that moment and
// the catalog to be loaded, then auto-runs the same picker flow a
// manual search would.
const pendingItemId = ref<string | null>(null)

const DAY_NAMES = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday']

const hours = ref<LocationHours[]>([])
const closures = ref<Closure[]>([])
const loadingSchedule = ref(false)

// --- location, picked here first -- nothing below is reachable until
// this and (for a non-capstone reservation) a full pickup/drop-off
// window are set. That ordering is the actual fix for the double-
// booking bug: equipment can only ever be added against a specific,
// already-known date/time range, so it can be checked against it.
const locationId = ref('')
const locationName = computed(() => catalog.locationById.get(locationId.value)?.name ?? '')

const reservationName = ref('')
const isCapstone = ref(false)
const capstoneAppointmentDate = ref('')

const pickupDate = ref('')
const pickupTime = ref('')
const dropoffDate = ref('')
const dropoffTime = ref('')

const isGroupReservation = ref(false)
const allowIndividualPickupTimes = ref(false)
const crew = reactive<CrewRow[]>([])
let crewSeq = 0
// item_model_id -> its assignment split rows. Every line gets exactly
// one row by default (the old single-assignee behavior, unchanged
// visually); a line with quantity > 1 can be expanded into more than
// one row so each person's share is recorded separately. See
// AssignmentSplit above for why this exists.
const assignmentSplits = reactive<Record<string, AssignmentSplit[]>>({})
let splitSeq = 0

// --- staff/admin personal-use vs. on-behalf-of ---------------------------
const isStaffPlus = computed(() => STAFF_PLUS_ROLES.includes(auth.role ?? ''))
const isPersonalUse = ref(false)
const targetQuery = ref('')
const targetUser = ref<TargetOption | null>(null)
const targetResults = ref<TargetOption[]>([])
const showTargetResults = ref(false)
let targetSearchSeq = 0

watch(isPersonalUse, (checked) => {
  if (checked) {
    targetUser.value = null
    targetQuery.value = ''
    targetResults.value = []
    showTargetResults.value = false
  }
})

async function onTargetQueryInput() {
  targetUser.value = null
  const mySeq = ++targetSearchSeq
  const q = targetQuery.value.trim()
  if (q.length < 2) {
    targetResults.value = []
    showTargetResults.value = false
    return
  }
  const { data } = await supabase
    .from('users')
    .select('id, full_name, email, role')
    .or(`full_name.ilike.%${q}%,email.ilike.%${q}%`)
    .limit(8)
  if (mySeq !== targetSearchSeq) return
  targetResults.value = (data ?? []) as TargetOption[]
  showTargetResults.value = true
}
function chooseTargetResult(user: TargetOption) {
  targetUser.value = user
  targetQuery.value = `${user.full_name} (${user.email})`
  showTargetResults.value = false
}
function hideTargetResultsSoon() {
  setTimeout(() => {
    showTargetResults.value = false
  }, 150)
}

const submitting = ref(false)
const error = ref('')

async function loadSchedule() {
  if (!locationId.value) {
    hours.value = []
    closures.value = []
    return
  }
  loadingSchedule.value = true
  try {
    const [hoursRes, closuresRes] = await Promise.all([
      supabase
        .from('location_hours')
        .select('day_of_week, is_open, appointment_only, open_time, close_time')
        .eq('location_id', locationId.value),
      supabase
        .from('location_closures')
        .select('date, reason')
        .eq('location_id', locationId.value)
        .gte('date', new Date().toISOString().slice(0, 10)),
    ])
    hours.value = (hoursRes.data ?? []) as LocationHours[]
    closures.value = (closuresRes.data ?? []) as Closure[]
  } finally {
    loadingSchedule.value = false
  }
}
onMounted(() => {
  catalog.ensureLoaded()
  loadSchedule()
  // Arrived from Browse Equipment's "start a reservation to check
  // availability" prompt — pre-fill what it already knew so the
  // student doesn't have to re-pick the location or re-type the name.
  const qItem = typeof route.query.item === 'string' ? route.query.item : null
  const qLocation = typeof route.query.location === 'string' ? route.query.location : null
  if (qLocation) locationId.value = qLocation
  if (qItem) pendingItemId.value = qItem
})
watch(locationId, loadSchedule)

function dayInfo(dateStr: string): LocationHours | null {
  if (!dateStr) return null
  const idx = new Date(dateStr + 'T12:00:00').getDay()
  const row = hours.value.find((h) => h.day_of_week === DAY_NAMES[idx])
  if (!row || !row.is_open) return null
  return row
}
function closureFor(dateStr: string): Closure | null {
  return closures.value.find((c) => c.date === dateStr) ?? null
}
function timeToMins(t: string) {
  const [h, m] = t.split(':').map(Number)
  return h * 60 + m
}
function minsToLabel(mins: number) {
  let h = Math.floor(mins / 60)
  const m = mins % 60
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}
function minsToHHMM(mins: number) {
  return `${String(Math.floor(mins / 60)).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}`
}

// --- the reservation's own lines + any shortfall routed to the waitlist
const lines = ref<ReservationLine[]>([])
const waitlistRequests = ref<WaitlistRequest[]>([])

const cartItemCount = computed(() => lines.value.reduce((s, l) => s + l.quantity, 0))
const isOverThreshold = computed(() => cartItemCount.value > APPROVAL_ITEM_THRESHOLD)
const isApprovalExempt = computed(() => isStaffPlus.value || (auth.role ?? 'student') !== 'student')

function slotOptions(dateStr: string) {
  const info = dayInfo(dateStr)
  if (!info || !info.open_time || !info.close_time) return []
  const step = isOverThreshold.value ? 30 : 15
  const lastWindow = isOverThreshold.value ? 60 : 30
  const open = timeToMins(info.open_time)
  const close = timeToMins(info.close_time)
  const lastStart = close - lastWindow
  const opts: { time: string; label: string }[] = []
  for (let m = open; m <= lastStart; m += step) {
    opts.push({ time: minsToHHMM(m), label: minsToLabel(m) })
  }
  return opts
}

const pickupSlots = computed(() => slotOptions(pickupDate.value))
const dropoffSlots = computed(() => slotOptions(dropoffDate.value))

watch(pickupDate, () => {
  if (!pickupSlots.value.find((s) => s.time === pickupTime.value)) pickupTime.value = ''
})
watch(dropoffDate, () => {
  if (!dropoffSlots.value.find((s) => s.time === dropoffTime.value)) dropoffTime.value = ''
})

// 7 days for a capstone reservation, 3 for everything else -- the one
// difference the client asked for; item count, Friday, the loan
// window, and the hard inventory check are all otherwise identical.
const leadTimeDays = computed(() => (isCapstone.value ? CAPSTONE_LEAD_TIME_DAYS : LEAD_TIME_DAYS))

const pickupNote = computed(() => {
  if (!pickupDate.value) return null
  const closure = closureFor(pickupDate.value)
  if (closure) return { tone: 'lock-note', text: `Closed this day — ${closure.reason}.` }
  const info = dayInfo(pickupDate.value)
  if (!info) return { tone: 'lock-note', text: 'This location is closed that day. Pick a different date.' }
  if (info.appointment_only)
    return {
      tone: 'info-note',
      text: "This day is by appointment only — staff will need to confirm this specific time before it's accepted.",
    }
  if (isApprovalExempt.value) return null
  const lead = new Date(pickupDate.value + 'T00:00:00')
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const diffDays = Math.round((lead.getTime() - today.getTime()) / 86400000)
  if (diffDays < leadTimeDays.value)
    return { tone: 'info-note', text: `Less than ${leadTimeDays.value} days out — this will need staff approval.` }
  return null
})

const loanWindowNote = computed(() => {
  if (!pickupDate.value || !dropoffDate.value || isApprovalExempt.value) return null
  const p = new Date(pickupDate.value + 'T00:00:00')
  const d = new Date(dropoffDate.value + 'T00:00:00')
  const days = Math.round((d.getTime() - p.getTime()) / 86400000)
  if (days > LOAN_WINDOW_DAYS)
    return { tone: 'info-note', text: `Longer than the standard ${LOAN_WINDOW_DAYS}-day loan window — this will need staff approval.` }
  return null
})

const approvalNote = computed(() => {
  if (isOverThreshold.value)
    return `This reservation is over ${APPROVAL_ITEM_THRESHOLD} items — it needs a staff member or admin to approve it before gear is assigned.`
  if (pickupNote.value || loanWindowNote.value)
    return 'One or more of your dates needs staff approval — see the notes above. The reservation is still submitted now and will be reviewed.'
  return `At or under ${APPROVAL_ITEM_THRESHOLD} items and within the standard windows, this reservation is confirmed as soon as you submit.`
})

// A real pickup/drop-off window is required before any item can be
// checked against real availability -- there's nothing to check it
// against otherwise. Client policy change, 10/21: a capstone
// reservation now collects this same tentative window up front,
// alongside its pre-pickup appointment request, instead of waiting
// until after the meeting -- so it needs exactly the same real
// window before equipment is reachable, no exception anymore.
const scheduleReady = computed(() => {
  if (!pickupDate.value || !pickupTime.value || !dropoffDate.value || !dropoffTime.value) return false
  if (dropoffDate.value < pickupDate.value) return false
  if (dropoffDate.value === pickupDate.value && dropoffTime.value <= pickupTime.value) return false
  return true
})
const canPickItems = computed(() => !!locationId.value && scheduleReady.value)

// Changing the location or the window after items are already picked
// would leave their cached availability stale against a now-different
// window -- rather than silently trusting an old number, clear the
// list and have the student re-add against the new window. The
// database re-checks at submit time regardless, but this keeps the
// on-screen numbers honest in the meantime.
let suppressClear = false
watch([locationId, pickupDate, pickupTime, dropoffDate, dropoffTime, isCapstone], () => {
  if (suppressClear) return
  if (lines.value.length > 0 || waitlistRequests.value.length > 0) {
    lines.value = []
    waitlistRequests.value = []
    clearedNote.value = true
  }
})
const clearedNote = ref(false)

// --- the item picker -----------------------------------------------------
const itemQuery = ref('')
// Ranked, not just filtered — catalog.rank() prefers a match on the
// item's own name/brand/model, then a match on its specific direct
// category (e.g. "Cameras"), then a match that only comes from its
// broader general category/location (e.g. "Camera Dept"). Without
// that ordering, this list used to just take the first 8 matches in
// catalog order (alphabetical by name) — so a specific, well-tagged
// item could get silently truncated out by a flood of other items
// that only share its general-category tag, with nothing to do with
// how relevant it actually was.
const itemResults = computed(() => {
  const q = itemQuery.value.trim()
  if (!q || !locationId.value) return []
  const candidates = catalog.items
    .filter((i) => i.location_id === locationId.value)
    .filter((i) => !lines.value.some((l) => l.itemModelId === i.id))
  return catalog.rank(q, candidates)
    .slice(0, 8)
    .map((r) => r.item)
})

const pickingItem = ref<CatalogItem | null>(null)
const pickQuantity = ref(1)
const pickAvailable = ref<number | null>(null)
const pickLoading = ref(false)
const pickError = ref('')

async function selectItemToAdd(item: CatalogItem) {
  pickingItem.value = item
  pickQuantity.value = 1
  pickError.value = ''
  pickAvailable.value = null
  itemQuery.value = ''
  pickLoading.value = true
  try {
    const { data, error: availErr } = await supabase.rpc('item_available_quantity', {
      p_item_model_id: item.id,
      p_window_start: `${pickupDate.value}T${pickupTime.value}:00`,
      p_window_end: `${dropoffDate.value}T${dropoffTime.value}:00`,
      p_exclude_reservation_id: null,
    })
    if (availErr) throw availErr
    pickAvailable.value = typeof data === 'number' ? data : 0
  } catch (e) {
    pickError.value = errorMessage(e, 'Could not check availability for this item.')
    pickAvailable.value = 0
  } finally {
    pickLoading.value = false
  }
}
function cancelPick() {
  pickingItem.value = null
  pickAvailable.value = null
  pickError.value = ''
}

// Fires once the thing Browse Equipment couldn't check for itself
// becomes checkable here: a real window (or capstone) is set, the
// catalog has loaded, and there's still a pending item to resolve.
watch(
  () => [canPickItems.value, catalog.items, pendingItemId.value] as const,
  ([ready, items, pending]) => {
    if (!ready || !pending) return
    const item = items.find((i) => i.id === pending)
    if (item) {
      selectItemToAdd(item)
      pendingItemId.value = null
    }
  },
  { immediate: true }
)

// joinWaitlist decides what happens to the shortfall when the request
// exceeds what's actually available for this window -- the student
// picks this explicitly per item (see the three buttons in the picker
// below) rather than it happening automatically. Each item is decided
// independently, so joining the waitlist for one item and skipping it
// for another is just two separate confirmAdd() calls with different
// values -- no extra plumbing needed for that.
function confirmAdd(joinWaitlist: boolean) {
  if (!pickingItem.value || pickAvailable.value === null) return
  const item = pickingItem.value
  const requested = Math.max(1, Math.floor(pickQuantity.value))
  const available = Math.max(0, pickAvailable.value)
  suppressClear = true
  if (requested <= available) {
    lines.value.push({ itemModelId: item.id, name: item.name, quantity: requested, maxAvailable: available })
    ensureSplits(item.id, requested)
  } else {
    if (available > 0) {
      lines.value.push({ itemModelId: item.id, name: item.name, quantity: available, maxAvailable: available })
      ensureSplits(item.id, available)
    }
    if (joinWaitlist) {
      const shortfall = requested - available
      waitlistRequests.value.push({ itemModelId: item.id, name: item.name, quantity: shortfall })
    }
  }
  suppressClear = false
  cancelPick()
}

function removeLine(itemModelId: string) {
  lines.value = lines.value.filter((l) => l.itemModelId !== itemModelId)
  delete assignmentSplits[itemModelId]
}
function changeQty(itemModelId: string, delta: number) {
  const line = lines.value.find((l) => l.itemModelId === itemModelId)
  if (line) {
    line.quantity = Math.max(1, Math.min(line.quantity + delta, line.maxAvailable))
    syncSplitsToQuantity(itemModelId, line.quantity)
  }
}
function removeWaitlistRequest(itemModelId: string) {
  waitlistRequests.value = waitlistRequests.value.filter((w) => w.itemModelId !== itemModelId)
}

// --- assignment splits (migration 23 groundwork) -------------------------
// Not read or displayed anywhere yet -- Suzanne's call (10/22): this is
// forward-looking groundwork for Pickup/Return (checkout), not wired
// into the Detail page or the Queue. It only has to be correct and
// buildable here; nothing downstream consumes it yet.

// Read-only accessor for the template -- never mutates, so it's safe
// to call during render. Returns [] for a line that hasn't been seeded
// yet (shouldn't normally happen -- see ensureSplits below -- but the
// template would otherwise break on an item with no rows at all).
function splitsFor(itemModelId: string): AssignmentSplit[] {
  return assignmentSplits[itemModelId] ?? []
}
function isSplit(itemModelId: string): boolean {
  return splitsFor(itemModelId).length > 1
}
// How much of the line's quantity is NOT yet covered by its split
// rows. 0 means the split is valid and submittable; nonzero drives the
// warning note in the template and blocks submit (see validate()).
function splitRemainder(itemModelId: string): number {
  const line = lines.value.find((l) => l.itemModelId === itemModelId)
  if (!line) return 0
  const sum = splitsFor(itemModelId).reduce((s, r) => s + r.quantity, 0)
  return line.quantity - sum
}

// Seeds the default single row (the whole quantity, assigned to the
// current user) the first time a line needs one -- called right after
// a line is added, so the template never has to handle an empty array.
// A no-op if the line already has rows.
function ensureSplits(itemModelId: string, quantity: number) {
  if (assignmentSplits[itemModelId]?.length) return
  assignmentSplits[itemModelId] = [{ id: ++splitSeq, userId: auth.user?.id ?? '', quantity }]
}

// Keeps a line's split rows valid whenever its quantity changes (the
// +/- stepper). Grows or shrinks the last row to absorb the
// difference rather than silently dropping anyone's assignment; if
// shrinking would take a row below 1, that row is removed and the
// remainder carries over to the row before it, down to a floor of one
// row at quantity 1.
function syncSplitsToQuantity(itemModelId: string, quantity: number) {
  const rows = assignmentSplits[itemModelId]
  if (!rows || rows.length === 0) {
    ensureSplits(itemModelId, quantity)
    return
  }
  let remaining = quantity - rows.reduce((s, r) => s + r.quantity, 0)
  let i = rows.length - 1
  while (remaining !== 0 && i >= 0) {
    const row = rows[i]
    const newQty = row.quantity + remaining
    if (newQty >= 1) {
      row.quantity = newQty
      remaining = 0
    } else if (rows.length > 1) {
      remaining = newQty
      rows.splice(i, 1)
    } else {
      row.quantity = 1
      remaining = 0
    }
    i--
  }
}

// "Split between people": pulls one unit from whichever row currently
// holds the most (least disruptive to that person's share) and opens
// a new, unassigned row for it. Does nothing if every row is already
// down to 1 -- there's nothing left to split off.
function addSplitRow(itemModelId: string) {
  const rows = assignmentSplits[itemModelId]
  if (!rows || rows.length === 0) return
  const donor = rows.reduce((best, r) => (r.quantity > (best?.quantity ?? 0) ? r : best), null as AssignmentSplit | null)
  if (!donor || donor.quantity <= 1) return
  donor.quantity -= 1
  rows.push({ id: ++splitSeq, userId: '', quantity: 1 })
}
// Removing a row never loses its quantity -- it's handed back to the
// row above it (or, removing the first row, to the new first row).
// Always leaves at least one row behind.
function removeSplitRow(itemModelId: string, id: number) {
  const rows = assignmentSplits[itemModelId]
  if (!rows) return
  const idx = rows.findIndex((r) => r.id === id)
  if (idx === -1 || rows.length <= 1) return
  const [removed] = rows.splice(idx, 1)
  const target = rows[idx - 1] ?? rows[0]
  if (target) target.quantity += removed.quantity
}
// Clamps a split row's quantity after the person edits it directly:
// never below 1, never higher than what's left once every other row's
// share is accounted for (mirrors the database's own quantity-sum
// guard, just enforced here first for a quicker, friendlier message).
function clampSplitQuantity(itemModelId: string, id: number) {
  const rows = assignmentSplits[itemModelId]
  const line = lines.value.find((l) => l.itemModelId === itemModelId)
  if (!rows || !line) return
  const row = rows.find((r) => r.id === id)
  if (!row) return
  const othersSum = rows.filter((r) => r.id !== id).reduce((s, r) => s + r.quantity, 0)
  const max = Math.max(1, line.quantity - othersSum)
  const parsed = Math.floor(Number(row.quantity))
  row.quantity = Math.min(Math.max(1, Number.isFinite(parsed) && parsed > 0 ? parsed : 1), max)
}

// --- group / crew -----------------------------------------------------
function toggleGroup() {
  isGroupReservation.value = !isGroupReservation.value
  if (isGroupReservation.value && crew.length === 0) addCrewMember()
}
function addCrewMember() {
  crew.push({ tempId: ++crewSeq, userId: null, fullName: '', role: 'Camera Operator', query: '', results: [], showResults: false })
}
function removeCrewMember(tempId: number) {
  const idx = crew.findIndex((c) => c.tempId === tempId)
  if (idx > -1) crew.splice(idx, 1)
}
let searchSeq = 0
async function onCrewQueryInput(row: CrewRow) {
  row.userId = null
  const mySeq = ++searchSeq
  const q = row.query.trim()
  if (q.length < 2) {
    row.results = []
    row.showResults = false
    return
  }
  const { data } = await supabase
    .from('users')
    .select('id, full_name')
    .ilike('full_name', `%${q}%`)
    .neq('id', auth.user?.id ?? '')
    .limit(6)
  if (mySeq !== searchSeq) return
  const taken = new Set(crew.filter((c) => c !== row && c.userId).map((c) => c.userId))
  row.results = ((data ?? []) as UserOption[]).filter((u) => !taken.has(u.id))
  row.showResults = true
}
function chooseCrewResult(row: CrewRow, user: UserOption) {
  row.userId = user.id
  row.fullName = user.full_name
  row.query = user.full_name
  row.showResults = false
}
function hideCrewResultsSoon(row: CrewRow) {
  setTimeout(() => {
    row.showResults = false
  }, 150)
}
const assigneeOptions = computed(() => [
  { id: auth.user?.id ?? '', full_name: `${auth.fullName ?? 'You'} (Director)` },
  ...crew.filter((c) => c.userId).map((c) => ({ id: c.userId as string, full_name: `${c.fullName} (${c.role})` })),
])
watch(assigneeOptions, (opts) => {
  const validIds = new Set(opts.map((o) => o.id))
  for (const line of lines.value) {
    for (const row of assignmentSplits[line.itemModelId] ?? []) {
      if (!row.userId || !validIds.has(row.userId)) {
        row.userId = auth.user?.id ?? ''
      }
    }
  }
})

// --- submit -------------------------------------------------------------
function validate(): string | null {
  if (lines.value.length === 0 && waitlistRequests.value.length === 0) {
    return 'Pick a location and your dates, then add at least one item.'
  }
  if (!locationId.value) return 'Pick a location.'
  if (!reservationName.value.trim()) return 'Give this reservation a name.'
  if (isStaffPlus.value && !isPersonalUse.value && !targetUser.value) {
    return 'Pick who this reservation is for, or check "This is for my own personal use."'
  }
  if (isCapstone.value && !capstoneAppointmentDate.value) {
    return 'Pick a requested pre-pickup appointment date.'
  }
  if (!scheduleReady.value) return 'Pick a valid pickup and drop-off date and time.'
  if (isGroupReservation.value && crew.some((c) => c.query.trim() && !c.userId)) {
    return 'Pick a real person from the list for every crew member, or remove the row.'
  }
  if (isGroupReservation.value) {
    for (const line of lines.value) {
      if (splitRemainder(line.itemModelId) !== 0) {
        return `${line.name}'s assigned quantities must add up to ${line.quantity}.`
      }
      if ((assignmentSplits[line.itemModelId] ?? []).some((r) => !r.userId)) {
        return `Pick a person for every split row on ${line.name}.`
      }
    }
  }
  return null
}

async function submitReservation() {
  error.value = ''
  const problem = validate()
  if (problem) {
    error.value = problem
    return
  }
  submitting.value = true
  try {
    if (!auth.user) throw new Error('Not signed in.')

    const studentId = isStaffPlus.value && !isPersonalUse.value && targetUser.value ? targetUser.value.id : auth.user.id

    if (lines.value.length > 0) {
      const insertRow: Record<string, unknown> = {
        reservation_name: reservationName.value.trim(),
        student_id: studentId,
        location_id: locationId.value,
        created_by: auth.user.id,
        is_capstone: isCapstone.value,
        is_group_reservation: isGroupReservation.value,
        is_personal_use: isStaffPlus.value && isPersonalUse.value,
        allow_individual_pickup_times: isGroupReservation.value && !isCapstone.value && allowIndividualPickupTimes.value,
        // Client policy change, 10/21: a capstone reservation now
        // collects its tentative pickup/drop-off window up front, same
        // as a regular reservation -- no more waiting for the meeting
        // before a real date exists.
        pickup_date: pickupDate.value,
        pickup_time: pickupTime.value,
        dropoff_date: dropoffDate.value,
        dropoff_time: dropoffTime.value,
      }
      if (isCapstone.value) {
        insertRow.capstone_appointment_date = capstoneAppointmentDate.value
      }

      const { data: resv, error: rErr } = await supabase.from('reservations').insert(insertRow).select('id').single()
      if (rErr) throw rErr
      const reservationId = resv.id as string

      const itemRows = lines.value.map((l) => ({
        reservation_id: reservationId,
        item_model_id: l.itemModelId,
        quantity: l.quantity,
      }))
      const { error: iErr } = await supabase.from('reservation_items').insert(itemRows)
      if (iErr) throw iErr

      if (isGroupReservation.value) {
        const crewRows = [
          { reservation_id: reservationId, user_id: auth.user.id, crew_role: 'Director', is_producer: true },
          ...crew
            .filter((c) => c.userId)
            .map((c) => ({ reservation_id: reservationId, user_id: c.userId as string, crew_role: c.role, is_producer: c.role === 'Producer' })),
        ]
        const { error: cErr } = await supabase.from('reservation_crew').insert(crewRows)
        if (cErr) throw cErr

        // Migration 23: reservation_assignments now carries its own
        // quantity, so a quantity > 1 line can be split across more
        // than one person. Flatten each line's split rows into one
        // insert row per person, merging two rows that ended up
        // assigned to the same person (shouldn't happen given the UI,
        // but the database only allows one row per person per item --
        // cheap to collapse here rather than let that reject it).
        const assignmentRows = lines.value.flatMap((l) => {
          const rows = assignmentSplits[l.itemModelId]
          const merged = new Map<string, number>()
          for (const row of rows && rows.length ? rows : [{ id: 0, userId: '', quantity: l.quantity }]) {
            const userId = row.userId || auth.user!.id
            merged.set(userId, (merged.get(userId) ?? 0) + row.quantity)
          }
          return Array.from(merged.entries()).map(([assigned_to_user_id, quantity]) => ({
            reservation_id: reservationId,
            item_model_id: l.itemModelId,
            assigned_to_user_id,
            quantity,
          }))
        })
        const { error: aErr } = await supabase.from('reservation_assignments').insert(assignmentRows)
        if (aErr) throw aErr
      }

      // reservations_approval_guard() only sees reservation_items that
      // already exist at the time it fires, and only re-fires on a
      // later update -- touching pickup_date again (no-op value) once
      // the items are in place is what makes it recompute for real,
      // including the inventory-availability check that's the whole
      // point of this page's new ordering. Capstone goes through this
      // exact same re-fire now too -- it's no longer a special case.
      const { error: touchErr } = await supabase.from('reservations').update({ pickup_date: pickupDate.value }).eq('id', reservationId)
      if (touchErr) throw touchErr
    }

    // Any shortfall the student chose to wait for becomes its own
    // small reservation, holding just the short items -- it never
    // touches the normal pending/approved path (add_to_waitlist sets
    // 'waitlisted' directly), so there's nothing for the inventory
    // check to reject here; it's supposed to not fit yet.
    if (waitlistRequests.value.length > 0) {
      const { data: wResv, error: wrErr } = await supabase
        .from('reservations')
        .insert({
          reservation_name: `${reservationName.value.trim()} (waitlist)`,
          student_id: studentId,
          location_id: locationId.value,
          created_by: auth.user.id,
          pickup_date: pickupDate.value,
          pickup_time: pickupTime.value,
          dropoff_date: dropoffDate.value,
          dropoff_time: dropoffTime.value,
        })
        .select('id')
        .single()
      if (wrErr) throw wrErr
      const waitlistReservationId = wResv.id as string

      const wItemRows = waitlistRequests.value.map((w) => ({
        reservation_id: waitlistReservationId,
        item_model_id: w.itemModelId,
        quantity: w.quantity,
      }))
      const { error: wiErr } = await supabase.from('reservation_items').insert(wItemRows)
      if (wiErr) throw wiErr

      for (const w of waitlistRequests.value) {
        const { error: addErr } = await supabase.rpc('add_to_waitlist', {
          p_reservation_id: waitlistReservationId,
          p_item_model_id: w.itemModelId,
          p_student_id: studentId,
        })
        if (addErr) throw addErr
      }
    }

    router.push({ name: 'reservations', query: { submitted: '1' } })
  } catch (e) {
    error.value = errorMessage(e, 'Could not submit the reservation.')
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="view">
    <div class="view-head">
      <div>
        <span class="view-eyebrow">Scheduling</span>
        <h1>New Reservation</h1>
        <p class="view-desc">
          Pick a location and your pickup/drop-off window first — equipment can only be added once
          we know exactly when you need it, so we can check it's actually free for those dates.
        </p>
      </div>
    </div>

    <div class="two-col">
      <div class="card" style="display: flex; flex-direction: column; gap: 14px">
        <div class="field">
          <label>Reservation name</label>
          <input v-model="reservationName" type="text" placeholder="e.g. FILM 2300, Interview Doc" />
        </div>

        <div class="field">
          <label>Location</label>
          <select v-model="locationId">
            <option value="" disabled>Select a location…</option>
            <option v-for="l in catalog.locations" :key="l.id" :value="l.id">{{ l.name }}</option>
          </select>
        </div>

        <template v-if="isStaffPlus">
          <hr class="divider" />
          <label style="display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600">
            <input v-model="isPersonalUse" type="checkbox" style="width: 16px; height: 16px" />
            This is for my own personal use
          </label>
          <p class="field-hint">
            Leave this unchecked to book on behalf of someone else — search for them below by name or
            email. Checked, you're the one keeping the gear, but a different staff member has to handle
            your pickup and return.
          </p>
          <div v-if="!isPersonalUse" class="field">
            <label>Who is this reservation for?</label>
            <div class="autocomplete-wrap">
              <input
                v-model="targetQuery"
                type="text"
                placeholder="Search by name or email…"
                style="border: 1px solid var(--border-strong); border-radius: 7px; padding: 6px 8px; font-size: 12.5px; width: 100%; background: var(--surface); color: var(--ink)"
                @input="onTargetQueryInput"
                @focus="onTargetQueryInput"
                @blur="hideTargetResultsSoon"
              />
              <div v-if="showTargetResults && targetResults.length" class="autocomplete-list">
                <div v-for="u in targetResults" :key="u.id" class="autocomplete-item" @mousedown="chooseTargetResult(u)">
                  {{ u.full_name }} — {{ u.email }}
                </div>
              </div>
            </div>
            <p v-if="targetUser" class="field-hint">Booking for {{ targetUser.full_name }} ({{ targetUser.email }}).</p>
          </div>
        </template>

        <hr class="divider" />
        <label style="display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600">
          <input v-model="isCapstone" type="checkbox" style="width: 16px; height: 16px" />
          This reservation is for a capstone project
        </label>

        <template v-if="isCapstone">
          <div class="info-note">
            Capstone reservations also need a requested pre-pickup appointment date, alongside the
            tentative pickup/drop-off window below. Your equipment is checked and approved against that
            window exactly like a regular reservation — the only difference is a longer,
            {{ CAPSTONE_LEAD_TIME_DAYS }}-day minimum lead time instead of {{ LEAD_TIME_DAYS }}. The
            meeting itself still needs to happen before pickup — staff will mark it complete once it
            does, but that no longer changes your approval status.
          </div>
          <div class="field">
            <label>Requested pre-pickup appointment date</label>
            <input v-model="capstoneAppointmentDate" type="date" />
          </div>
        </template>

        <div class="field-row">
          <div class="field">
            <label>Pickup date</label>
            <input v-model="pickupDate" type="date" />
          </div>
          <div class="field">
            <label>Drop-off date</label>
            <input v-model="dropoffDate" type="date" />
          </div>
        </div>
        <div v-if="pickupNote" :class="pickupNote.tone">{{ pickupNote.text }}</div>
        <div v-if="loanWindowNote" :class="loanWindowNote.tone">{{ loanWindowNote.text }}</div>

        <div class="field-row">
          <div class="field">
            <label>Pickup time</label>
            <select v-model="pickupTime" class="select-time">
              <option value="" disabled>Select a time…</option>
              <option v-for="s in pickupSlots" :key="s.time" :value="s.time">{{ s.label }}</option>
            </select>
            <p v-if="pickupDate && pickupSlots.length === 0" class="field-hint">Closed this day.</p>
          </div>
          <div class="field">
            <label>Drop-off time</label>
            <select v-model="dropoffTime" class="select-time">
              <option value="" disabled>Select a time…</option>
              <option v-for="s in dropoffSlots" :key="s.time" :value="s.time">{{ s.label }}</option>
            </select>
            <p v-if="dropoffDate && dropoffSlots.length === 0" class="field-hint">Closed this day.</p>
          </div>
        </div>
        <p class="field-hint" v-if="isOverThreshold">
          Over {{ APPROVAL_ITEM_THRESHOLD }} items: each reservation needs a 30-minute block and a
          staff member will need to approve the request before gear is assigned.
        </p>

        <hr class="divider" />
        <div class="section-title" style="font-size: 13px">Equipment</div>

        <p v-if="!locationId" class="field-hint">Pick a location above to start adding equipment.</p>
        <p v-else-if="!canPickItems" class="field-hint">
          Pick your pickup and drop-off date and time above to start adding equipment — availability
          depends on the exact window.
        </p>

        <template v-else>
          <p v-if="clearedNote" class="info-note">
            Your items were cleared because the pickup window changed — availability depends on the exact
            dates, so add them again for the new window.
          </p>

          <div class="field" style="position: relative">
            <label>Add equipment</label>
            <input v-model="itemQuery" type="text" placeholder="Search by name, brand, model…" />
            <div v-if="itemResults.length" class="autocomplete-list" style="position: static; margin-top: 4px">
              <div v-for="item in itemResults" :key="item.id" class="autocomplete-item" @click="selectItemToAdd(item)">
                {{ item.name }}<span v-if="item.brand || item.model" style="color: var(--ink-3)"> — {{ item.brand }} {{ item.model }}</span>
              </div>
            </div>
          </div>

          <div v-if="pickingItem" class="card-flat" style="display: flex; flex-direction: column; gap: 8px">
            <div style="font-weight: 600; font-size: 13px">{{ pickingItem.name }}</div>
            <p v-if="pickLoading" class="field-hint">Checking availability…</p>
            <template v-else>
              <p class="field-hint">{{ pickAvailable }} available for your dates</p>
              <div class="field" style="max-width: 140px">
                <label>Quantity</label>
                <input v-model.number="pickQuantity" type="number" min="1" />
              </div>
              <p v-if="pickQuantity > (pickAvailable ?? 0)" class="info-note">
                Only {{ pickAvailable }} free for these dates. Your choice: add just what's available,
                join the waitlist for the rest, or skip this item.
              </p>
              <p v-if="pickError" class="error-note">{{ pickError }}</p>
              <div style="display: flex; gap: 8px; flex-wrap: wrap">
                <button
                  v-if="pickQuantity > (pickAvailable ?? 0) && (pickAvailable ?? 0) > 0"
                  class="btn ghost small"
                  @click="confirmAdd(false)"
                >
                  Add {{ pickAvailable }} now, skip the rest
                </button>
                <button class="btn primary small" @click="confirmAdd(true)">
                  {{ pickQuantity > (pickAvailable ?? 0) && (pickAvailable ?? 0) === 0
                    ? `Join waitlist for ${pickQuantity}`
                    : pickQuantity > (pickAvailable ?? 0)
                      ? `Add ${pickAvailable} + join waitlist for ${pickQuantity - (pickAvailable ?? 0)}`
                      : 'Add' }}
                </button>
                <button class="btn ghost small" @click="cancelPick">Cancel</button>
              </div>
            </template>
          </div>
        </template>

        <div v-if="lines.length || waitlistRequests.length" style="display: flex; flex-direction: column; gap: 8px">
          <div v-for="line in lines" :key="line.itemModelId" class="card-flat" style="display: flex; flex-direction: column; gap: 8px">
            <div style="display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap">
              <span style="font-size: 13px">{{ line.name }}</span>
              <div style="display: flex; align-items: center; gap: 8px">
                <div class="qty-stepper">
                  <button type="button" @click="changeQty(line.itemModelId, -1)" :disabled="line.quantity <= 1">−</button>
                  <span class="qty-num">{{ line.quantity }}</span>
                  <button type="button" @click="changeQty(line.itemModelId, 1)" :disabled="line.quantity >= line.maxAvailable">+</button>
                </div>
                <select
                  v-if="isGroupReservation && !isSplit(line.itemModelId)"
                  v-model="splitsFor(line.itemModelId)[0].userId"
                  style="font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink)"
                >
                  <option v-for="opt in assigneeOptions" :key="opt.id" :value="opt.id">{{ opt.full_name }}</option>
                </select>
                <button
                  v-if="isGroupReservation && line.quantity > 1 && !isSplit(line.itemModelId)"
                  class="btn ghost small"
                  @click="addSplitRow(line.itemModelId)"
                >
                  Split between people
                </button>
                <button class="btn ghost small" @click="removeLine(line.itemModelId)">Remove</button>
              </div>
            </div>

            <div
              v-if="isGroupReservation && isSplit(line.itemModelId)"
              style="display: flex; flex-direction: column; gap: 6px; padding-left: 10px; border-left: 2px solid var(--border-strong)"
            >
              <div v-for="row in splitsFor(line.itemModelId)" :key="row.id" style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap">
                <input
                  v-model.number="row.quantity"
                  type="number"
                  min="1"
                  :max="line.quantity"
                  style="width: 54px; font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink)"
                  @change="clampSplitQuantity(line.itemModelId, row.id)"
                />
                <select
                  v-model="row.userId"
                  style="font-size: 11.5px; padding: 4px 6px; border: 1px solid var(--border-strong); border-radius: 6px; background: var(--surface); color: var(--ink); flex: 1"
                >
                  <option value="" disabled>Select a person…</option>
                  <option v-for="opt in assigneeOptions" :key="opt.id" :value="opt.id">{{ opt.full_name }}</option>
                </select>
                <button class="icon-btn" style="width: 24px; height: 24px" @click="removeSplitRow(line.itemModelId, row.id)">✕</button>
              </div>
              <button
                class="btn ghost small"
                style="align-self: flex-start"
                :disabled="splitsFor(line.itemModelId).every((r) => r.quantity <= 1)"
                @click="addSplitRow(line.itemModelId)"
              >
                + Add another person
              </button>
              <p v-if="splitRemainder(line.itemModelId) !== 0" class="error-note" style="font-size: 11.5px">
                These need to add up to {{ line.quantity }} — currently {{ line.quantity - splitRemainder(line.itemModelId) }}.
              </p>
            </div>
          </div>
          <div v-for="w in waitlistRequests" :key="w.itemModelId" class="card-flat" style="display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap; border-style: dashed">
            <span style="font-size: 13px">{{ w.name }} — waitlisted ×{{ w.quantity }}</span>
            <button class="btn ghost small" @click="removeWaitlistRequest(w.itemModelId)">Remove</button>
          </div>
        </div>

        <hr class="divider" />
        <button class="btn small" style="align-self: flex-start" @click="toggleGroup">
          {{ isGroupReservation ? '− Remove group production setup' : '+ Make this a group production reservation' }}
        </button>

        <div v-if="isGroupReservation" style="display: flex; flex-direction: column; gap: 10px">
          <p class="field-hint">
            Search by name, then assign items to them above. Whoever's assigned an item is the one
            who'll check it off at pickup.
          </p>
          <label
            v-if="!isCapstone"
            style="display: flex; align-items: center; gap: 8px; font-size: 12.5px; font-weight: 600"
          >
            <input v-model="allowIndividualPickupTimes" type="checkbox" style="width: 16px; height: 16px" />
            Let crew members pick their own pickup/drop-off time
          </label>
          <p v-if="!isCapstone" class="field-hint">
            Off (default): everyone follows the pickup/drop-off times above, and you're responsible for
            all of it. On: each crew member gets notified and can set their own time in My Reservations
            — anyone who doesn't set one just falls back to the times above.
          </p>
          <div style="display: flex; align-items: center; justify-content: space-between">
            <div class="section-title" style="font-size: 13px">Crew</div>
            <button class="btn small" @click="addCrewMember">+ Add crew member</button>
          </div>
          <div v-for="row in crew" :key="row.tempId" class="crew-row">
            <div class="crew-avatar">{{ row.fullName ? row.fullName.slice(0, 2).toUpperCase() : '?' }}</div>
            <div class="autocomplete-wrap">
              <input
                v-model="row.query"
                type="text"
                placeholder="Type a name…"
                style="border: 1px solid var(--border-strong); border-radius: 7px; padding: 6px 8px; font-size: 12.5px; width: 100%; background: var(--surface); color: var(--ink)"
                @input="onCrewQueryInput(row)"
                @focus="onCrewQueryInput(row)"
                @blur="hideCrewResultsSoon(row)"
              />
              <div v-if="row.showResults && row.results.length" class="autocomplete-list">
                <div v-for="u in row.results" :key="u.id" class="autocomplete-item" @mousedown="chooseCrewResult(row, u)">
                  {{ u.full_name }}
                </div>
              </div>
            </div>
            <select v-model="row.role" style="width: 150px">
              <option v-for="r in CREW_ROLES" :key="r">{{ r }}</option>
            </select>
            <button class="icon-btn" style="width: 26px; height: 26px" @click="removeCrewMember(row.tempId)">✕</button>
          </div>
        </div>

        <hr class="divider" />
        <div class="field-hint">{{ approvalNote }}</div>
        <p v-if="error" class="error-note">{{ error }}</p>
        <button class="btn primary" style="width: 100%" :disabled="submitting" @click="submitReservation">
          {{ submitting ? 'Submitting…' : 'Submit reservation' }}
        </button>
      </div>

      <div class="card">
        <div class="section-title" style="margin-bottom: 10px">{{ locationName || 'Hours' }}</div>
        <p v-if="!locationId" class="field-hint">Pick a location to see its hours.</p>
        <p v-else-if="loadingSchedule" class="field-hint">Loading hours…</p>
        <div v-else style="display: flex; flex-direction: column; gap: 6px">
          <div v-for="d in DAY_NAMES.slice(1).concat(DAY_NAMES[0])" :key="d" style="display: flex; justify-content: space-between; font-size: 12.5px; text-transform: capitalize">
            <span>{{ d }}</span>
            <span class="field-hint" style="text-transform: none">
              <template v-if="hours.find((h) => h.day_of_week === d)?.is_open">
                {{ hours.find((h) => h.day_of_week === d)?.open_time?.slice(0, 5) }}–{{
                  hours.find((h) => h.day_of_week === d)?.close_time?.slice(0, 5)
                }}
                <span v-if="hours.find((h) => h.day_of_week === d)?.appointment_only"> (by appt)</span>
              </template>
              <template v-else>Closed</template>
            </span>
          </div>
        </div>
        <template v-if="closures.length">
          <hr class="divider" />
          <div class="kicker" style="margin-bottom: 6px">Upcoming closures</div>
          <div v-for="c in closures" :key="c.date" class="field-hint">{{ c.date }} — {{ c.reason }}</div>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
