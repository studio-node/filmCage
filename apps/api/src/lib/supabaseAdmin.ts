import { createClient } from '@supabase/supabase-js';
import { env } from './env.js';

// Service-role client: bypasses RLS entirely. Server-side use only —
// never expose this client (or the key it's built from) to the frontend.
export const supabaseAdmin = createClient(env.supabaseUrl, env.supabaseServiceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
