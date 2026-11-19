import { onUnmounted, ref } from 'vue'

// The Cage's local clock (America/Denver), independent of the viewer's
// own device time zone -- matches public.cage_local_now() in the
// database (migration 33). Using new Date().toISOString() for "today"
// gave the UTC date, which is already tomorrow from 5pm Mountain
// (6pm in summer), so evening views treated today as the past.
export const CAGE_TIME_ZONE = 'America/Denver'

export interface CageNow {
  date: string // YYYY-MM-DD
  minutes: number // minutes since local midnight
}

export function cageNow(): CageNow {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: CAGE_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date())
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '00'
  return {
    date: `${get('year')}-${get('month')}-${get('day')}`,
    minutes: Number(get('hour')) * 60 + Number(get('minute')),
  }
}

export function cageToday(): string {
  return cageNow().date
}

// YYYY-MM-DD plus n days (calendar math, no time zone involved)
export function addDays(dateStr: string, n: number): string {
  const d = new Date(dateStr + 'T12:00:00Z')
  d.setUTCDate(d.getUTCDate() + n)
  return d.toISOString().slice(0, 10)
}

// A live clock for a view: re-reads every 30s so times that pass while
// the page is open grey out without a reload.
export function useCageClock() {
  const now = ref<CageNow>(cageNow())
  const timer = window.setInterval(() => {
    now.value = cageNow()
  }, 30_000)
  onUnmounted(() => window.clearInterval(timer))
  return now
}
