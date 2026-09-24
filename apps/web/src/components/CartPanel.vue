<script setup lang="ts">
import { ref, watch } from 'vue'
import { useCartStore } from '../stores/cart'

const props = defineProps<{ open: boolean }>()
const emit = defineEmits<{ close: []; submitted: [reservationId: string] }>()

const cart = useCartStore()
const reservationName = ref('')
const pickupDate = ref('')
const dropoffDate = ref('')
const submitting = ref(false)
const error = ref('')

function defaultDateStrings() {
  const pickup = new Date()
  pickup.setDate(pickup.getDate() + 3) // matches the 3-day minimum lead time
  const dropoff = new Date(pickup)
  dropoff.setDate(dropoff.getDate() + 3) // matches the default 3-day loan window
  const fmt = (d: Date) => d.toISOString().slice(0, 10)
  return { pickup: fmt(pickup), dropoff: fmt(dropoff) }
}

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen && !reservationName.value) {
      const { pickup, dropoff } = defaultDateStrings()
      pickupDate.value = pickup
      dropoffDate.value = dropoff
      reservationName.value = cart.locationName ? `${cart.locationName} pickup` : ''
    }
    error.value = ''
  }
)

async function handleSubmit() {
  error.value = ''
  if (!reservationName.value.trim()) {
    error.value = 'Give this reservation a name.'
    return
  }
  if (!pickupDate.value || !dropoffDate.value) {
    error.value = 'Pickup and drop-off dates are both required.'
    return
  }
  if (dropoffDate.value <= pickupDate.value) {
    error.value = 'Drop-off must be after pickup.'
    return
  }
  submitting.value = true
  try {
    const id = await cart.submit(reservationName.value.trim(), pickupDate.value, dropoffDate.value)
    reservationName.value = ''
    emit('submitted', id)
    emit('close')
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Could not submit the reservation.'
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div v-if="open" class="drawer-backdrop" @click.self="emit('close')">
    <div class="drawer">
      <h2 style="font-size: 19px">Your reservation</h2>
      <p v-if="cart.locationName" style="color: var(--ink-3)">Pickup at {{ cart.locationName }}</p>

      <p v-if="cart.lines.length === 0" class="empty-note">
        Your cart is empty — add equipment from Browse Equipment.
      </p>

      <div v-else style="display: flex; flex-direction: column; gap: 10px">
        <div v-for="line in cart.lines" :key="line.itemModelId" class="unit-line" style="border-top: none">
          <span style="flex: 1">{{ line.name }}</span>
          <div class="qty-stepper">
            <button
              type="button"
              @click="cart.updateQuantity(line.itemModelId, line.quantity - 1)"
              :disabled="line.quantity <= 1"
            >
              −
            </button>
            <span class="qty-num">{{ line.quantity }}</span>
            <button
              type="button"
              @click="cart.updateQuantity(line.itemModelId, line.quantity + 1)"
              :disabled="line.quantity >= line.maxAvailable"
            >
              +
            </button>
          </div>
          <button class="btn ghost small" @click="cart.removeItem(line.itemModelId)">Remove</button>
        </div>

        <hr class="divider" />

        <div class="field">
          <label>Reservation name</label>
          <input v-model="reservationName" type="text" />
        </div>
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
        <p class="field-hint">
          Pickups under 3 days out, on a Friday, or loans over 3 days need staff approval — every
          request starts as Pending either way.
        </p>
        <p v-if="error" class="error-note">{{ error }}</p>
        <div style="display: flex; gap: 8px">
          <button class="btn primary" :disabled="submitting" @click="handleSubmit">
            {{ submitting ? 'Submitting…' : 'Submit request' }}
          </button>
          <button class="btn ghost" @click="cart.clear()">Clear cart</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-note {
  color: var(--crit);
}
</style>
