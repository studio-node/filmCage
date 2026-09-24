// Turns whatever a catch block actually receives into a readable
// message.
//
// A request that reaches Supabase and gets a real response — RLS
// denial, a trigger's raised exception, a constraint violation, a
// missing column — comes back as a PostgrestError, which *is* a real
// Error, so e.message is already the right thing to show.
//
// A request that never gets a response at all — the Supabase project
// is paused/asleep, there's no network, DNS fails, the request times
// out — comes back from supabase-js as a plain {message, details,
// hint, code} object instead, which is NOT an Error instance. Code
// that only checks `instanceof Error` silently swallows exactly these
// cases and shows a generic fallback right when the real message
// (often naming the actual problem, e.g. a DNS/timeout hint) would
// help the most. This checks for that shape too before giving up.
export function errorMessage(e: unknown, fallback: string): string {
  if (e instanceof Error && e.message) return e.message
  if (e && typeof e === 'object' && 'message' in e) {
    const msg = (e as { message?: unknown }).message
    if (typeof msg === 'string' && msg) {
      const hint = (e as { hint?: unknown }).hint
      return typeof hint === 'string' && hint ? `${msg} (${hint})` : msg
    }
  }
  return fallback
}
