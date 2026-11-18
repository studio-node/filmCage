import { defineStore } from 'pinia'
import { supabase } from '../lib/supabaseClient'
import type { User } from '@supabase/supabase-js'

export type UserRole = 'student' | 'staff' | 'supervisor' | 'admin' | 'class_instructor'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    user: null as User | null,
    role: null as UserRole | null,
    fullName: null as string | null,
    loading: true,
    // true after opening a password-reset email link, until a new
    // password is saved (ResetPasswordView.vue)
    passwordRecovery: false,
    recoveryError: '' as string,
  }),
  actions: {
    async init() {
      // A reset email links to <site>?token_hash=...&type=recovery
      // (Supabase email template, see lib/passwordReset.ts). Verify it,
      // which signs the person in, then strip it from the address bar.
      const params = new URLSearchParams(window.location.search)
      const tokenHash = params.get('token_hash')
      if (tokenHash && params.get('type') === 'recovery') {
        const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: 'recovery' })
        if (error) this.recoveryError = error.message
        this.passwordRecovery = true
        window.history.replaceState(null, '', window.location.pathname + '#/reset-password')
      }

      const { data } = await supabase.auth.getSession()
      this.user = data.session?.user ?? null
      if (this.user) await this.loadProfile()
      this.loading = false

      supabase.auth.onAuthStateChange(async (event, session) => {
        if (event === 'PASSWORD_RECOVERY') this.passwordRecovery = true
        this.user = session?.user ?? null
        this.role = null
        this.fullName = null
        if (this.user) await this.loadProfile()
      })
    },
    async loadProfile() {
      if (!this.user) return
      const { data, error } = await supabase
        .from('users')
        .select('role, full_name')
        .eq('id', this.user.id)
        .single()
      if (!error) {
        this.role = (data?.role as UserRole) ?? null
        this.fullName = data?.full_name ?? null
      }
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
