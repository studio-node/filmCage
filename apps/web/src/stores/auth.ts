import { defineStore } from 'pinia'
import { supabase } from '../lib/supabaseClient'
import type { User } from '@supabase/supabase-js'

export type UserRole = 'student' | 'staff' | 'supervisor' | 'admin' | 'professor'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    user: null as User | null,
    role: null as UserRole | null,
    loading: true,
  }),
  actions: {
    async init() {
      const { data } = await supabase.auth.getSession()
      this.user = data.session?.user ?? null
      if (this.user) await this.loadRole()
      this.loading = false

      supabase.auth.onAuthStateChange(async (_event, session) => {
        this.user = session?.user ?? null
        this.role = null
        if (this.user) await this.loadRole()
      })
    },
    async loadRole() {
      if (!this.user) return
      const { data, error } = await supabase
        .from('users')
        .select('role')
        .eq('id', this.user.id)
        .single()
      if (!error) this.role = (data?.role as UserRole) ?? null
    },
    async signIn(email: string, password: string) {
      const { error } = await supabase.auth.signInWithPassword({ email, password })
      if (error) throw error
    },
    async signOut() {
      await supabase.auth.signOut()
    },
  },
})
