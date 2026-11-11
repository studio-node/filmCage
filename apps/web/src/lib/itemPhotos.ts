// Upload/delete helpers for item_models.picture_url, backed by the
// public 'item-photos' Storage bucket (see migration
// 20261111120000_item_photo_storage.sql). Shared by Add Items (new
// model, no id yet) and Edit Items (existing model) so both screens
// upload/validate/clean up the same way instead of duplicating it.

import { supabase } from './supabaseClient'

const BUCKET = 'item-photos'
const MAX_BYTES = 8 * 1024 * 1024 // 8MB -- plenty for a product photo, small enough to not stall a phone upload at the counter
const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif']

export function validatePhotoFile(file: File): string {
  if (!ACCEPTED_TYPES.includes(file.type)) return 'Please choose a JPEG, PNG, WEBP, or GIF image.'
  if (file.size > MAX_BYTES) return 'That image is too large (max 8MB).'
  return ''
}

// `scope` groups files under the item model's id so a model's photos
// are easy to find/clean up by eye in the bucket; a new item doesn't
// have an id yet, so it uploads under 'new' and the file is left
// where it is -- there's no move/rename step, picture_url just points
// at wherever the file actually landed.
export async function uploadItemPhoto(file: File, scope: string): Promise<string> {
  const problem = validatePhotoFile(file)
  if (problem) throw new Error(problem)

  const ext = file.name.includes('.') ? file.name.slice(file.name.lastIndexOf('.')) : ''
  const path = `${scope}/${crypto.randomUUID()}${ext}`

  const { error } = await supabase.storage.from(BUCKET).upload(path, file, {
    cacheControl: '3600',
    upsert: false,
  })
  if (error) throw error

  const { data } = supabase.storage.from(BUCKET).getPublicUrl(path)
  return data.publicUrl
}

// Best-effort cleanup when a photo is replaced or removed -- never
// blocks the actual save on a storage error (an orphaned file is a
// minor annoyance, a failed save over it is not).
export async function deleteItemPhoto(publicUrl: string | null | undefined): Promise<void> {
  if (!publicUrl) return
  const marker = `/object/public/${BUCKET}/`
  const idx = publicUrl.indexOf(marker)
  if (idx === -1) return // not one of our own bucket URLs -- nothing we can clean up
  const path = publicUrl.slice(idx + marker.length)
  if (!path) return
  try {
    await supabase.storage.from(BUCKET).remove([path])
  } catch {
    // best-effort only, see comment above
  }
}
