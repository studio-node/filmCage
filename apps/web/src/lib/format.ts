// Small display helpers shared by the Users pages. (Older views keep
// their own local copies of formatDate/formatTime; same output.)

export function formatDate(d: string | null | undefined): string {
  if (!d) return '—'
  return new Date(d.length === 10 ? d + 'T12:00:00' : d).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

export function formatTime(t: string | null | undefined): string {
  if (!t) return ''
  const [h, m] = t.split(':').map(Number)
  const ampm = h >= 12 ? 'PM' : 'AM'
  let h12 = h % 12
  if (h12 === 0) h12 = 12
  return `${h12}:${String(m).padStart(2, '0')} ${ampm}`
}

export function formatMoney(n: number | string | null | undefined): string {
  const v = Number(n ?? 0)
  return `$${v.toFixed(2)}`
}

export const ROLE_LABELS: Record<string, string> = {
  student: 'Student',
  class_instructor: 'Class instructor',
  staff: 'Staff',
  supervisor: 'Supervisor',
  admin: 'Admin',
}

export function roleLabel(role: string | null | undefined): string {
  return role ? ROLE_LABELS[role] ?? role : '—'
}

export const FINE_TYPE_LABELS: Record<string, string> = {
  late_return: 'Late return',
  damage: 'Damage',
  missing: 'Missing equipment',
  other: 'Other',
}

// PostgREST returns a one-to-one embed as an object, but older
// versions (or an ambiguous relationship) can hand back a one-element
// array. Normalize either shape.
export function one<T>(v: T | T[] | null | undefined): T | null {
  if (Array.isArray(v)) return v[0] ?? null
  return v ?? null
}
