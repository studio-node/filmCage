import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  console.warn(
    '[supabase] Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY — copy .env.example to .env.local and fill in your project values.'
  )
}

// PKCE: auth redirects (OAuth, password-reset/confirmation links) come back as
// ?code=... instead of tokens in the #fragment, which would collide with hash routing.
export const supabase = createClient(supabaseUrl ?? '', supabaseAnonKey ?? '', {
  auth: { flowType: 'pkce' },
})
