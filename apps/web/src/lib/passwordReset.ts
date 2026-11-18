import { createClient } from '@supabase/supabase-js'

// Sending a reset email for SOMEONE ELSE (admin, from the Users page).
//
// The app's main client uses the PKCE flow, which stores a one-time
// "code verifier" in the browser that asked for the email and expects
// the link to be opened in that same browser. That's the admin's
// browser here, not the student's, so a PKCE reset link would fail
// for the person it's meant for. This throwaway client uses the
// implicit flow and keeps no session, so it leaves nothing behind in
// the admin's browser.
//
// The link itself must use the token-hash form (set once in Supabase:
// Authentication → Email Templates → Reset Password):
//   {{ .SiteURL }}?token_hash={{ .TokenHash }}&type=recovery
// auth.init() picks that up, verifies it, and sends the person to the
// Set New Password screen. See ResetPasswordView.vue.
const resetClient = createClient(
  import.meta.env.VITE_SUPABASE_URL ?? '',
  import.meta.env.VITE_SUPABASE_ANON_KEY ?? '',
  { auth: { flowType: 'implicit', persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }
)

export async function sendPasswordResetEmail(email: string): Promise<void> {
  const redirectTo = window.location.origin + import.meta.env.BASE_URL
  const { error } = await resetClient.auth.resetPasswordForEmail(email, { redirectTo })
  if (error) throw error
}
