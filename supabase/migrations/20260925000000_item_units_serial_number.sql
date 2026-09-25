-- ============================================================
-- Serial numbers for physical unit tracking.
--
-- Every camera or lens has a manufacturer serial number (some other
-- gear doesn't), separate from both unit_code (our own sequential
-- label, e.g. "3") and qr_code (our own generated tracking code).
-- Nullable, no default — entered by staff/admin from Add Items or
-- Edit Items whenever a unit's serial is known, same "type it in when
-- you have it" pattern as qr_code.
--
-- Deliberately NOT unique (unlike qr_code): this is real-world
-- manufacturer data being transcribed by hand, not an identifier our
-- own system generates and relies on for lookups — a stray duplicate
-- (typo, or genuinely re-used numbering across manufacturers/product
-- lines) shouldn't block saving the rest of a unit's edit. Can add a
-- uniqueness check later if it turns out to matter in practice.
-- ============================================================
alter table public.item_units
  add column serial_number text;
