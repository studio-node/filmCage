import { defineStore } from 'pinia'
import { supabase } from '../lib/supabaseClient'
import { useAuthStore } from './auth'

export interface CartLine {
  itemModelId: string
  name: string
  quantity: number
  maxAvailable: number
}

// A reservation is one row with one location_id (public.reservations),
// so a cart can only hold items from a single location at a time —
// you can't pick up from The Cage and Studio C on one visit. addItem
// returns an error string (and refuses the add) if the cart already
// has a different location in it, rather than silently splitting into
// two reservations behind the scenes.
export const useCartStore = defineStore('cart', {
  state: () => ({
    lines: [] as CartLine[],
    locationId: null as string | null,
    locationName: null as string | null,
  }),
  getters: {
    count: (state) => state.lines.reduce((sum, l) => sum + l.quantity, 0),
  },
  actions: {
    addItem(
      item: { id: string; name: string; locationId: string; locationName: string },
      quantity: number,
      maxAvailable: number
    ): string | null {
      if (this.locationId && this.locationId !== item.locationId) {
        return `Your cart already has items from ${this.locationName}. Submit or clear that request before adding items from ${item.locationName}.`
      }
      this.locationId = item.locationId
      this.locationName = item.locationName

      const existing = this.lines.find((l) => l.itemModelId === item.id)
      if (existing) {
        existing.quantity = Math.min(existing.quantity + quantity, maxAvailable)
        existing.maxAvailable = maxAvailable
      } else {
        this.lines.push({ itemModelId: item.id, name: item.name, quantity, maxAvailable })
      }
      return null
    },
    updateQuantity(itemModelId: string, quantity: number) {
      const line = this.lines.find((l) => l.itemModelId === itemModelId)
      if (line) line.quantity = Math.max(1, Math.min(quantity, line.maxAvailable))
    },
    removeItem(itemModelId: string) {
      this.lines = this.lines.filter((l) => l.itemModelId !== itemModelId)
      if (this.lines.length === 0) {
        this.locationId = null
        this.locationName = null
      }
    },
    clear() {
      this.lines = []
      this.locationId = null
      this.locationName = null
    },
    // Submits the whole cart as ONE reservations row + one
    // reservation_items row per line. Not a real DB transaction —
    // supabase-js doesn't give us one without a dedicated RPC function
    // — so a failure on the second insert can leave an empty
    // reservation behind. Acceptable for now; worth a real
    // create_reservation() RPC later if that ever actually happens.
    async submit(reservationName: string, pickupDate: string, dropoffDate: string) {
      const auth = useAuthStore()
      if (!auth.user) throw new Error('Not signed in.')
      if (this.lines.length === 0) throw new Error('Your cart is empty.')
      if (!this.locationId) throw new Error('No location set for this reservation.')

      const { data: resv, error: rErr } = await supabase
        .from('reservations')
        .insert({
          reservation_name: reservationName,
          student_id: auth.user.id,
          location_id: this.locationId,
          created_by: auth.user.id,
          pickup_date: pickupDate,
          dropoff_date: dropoffDate,
        })
        .select('id')
        .single()
      if (rErr) throw rErr

      const rows = this.lines.map((l) => ({
        reservation_id: resv.id,
        item_model_id: l.itemModelId,
        quantity: l.quantity,
      }))
      const { error: iErr } = await supabase.from('reservation_items').insert(rows)
      if (iErr) throw iErr

      this.clear()
      return resv.id as string
    },
  },
})
