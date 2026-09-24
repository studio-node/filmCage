-- ============================================================
-- QR codes for physical unit tracking.
--
-- Each physical unit (not the item_model it belongs to) gets its own
-- short, unique code — this is what a printed label's QR code encodes,
-- e.g. as a URL like https://thefilmcage.app/units/FC-3K9QZ2, so a
-- staff member (or eventually a student) can scan the physical label
-- with an ordinary phone camera and land on that unit's record. No
-- image is stored anywhere: the QR code picture itself is rendered on
-- demand from this text value, in the browser, whenever it's needed
-- (viewing a unit, printing a label) — storing a rendered image would
-- just be a redundant, unscannable-by-text copy of this column.
--
-- Nullable, no auto-generation: some equipment already has physical
-- QR stickers from before this system existed, so a new or existing
-- unit starts with no code and staff/admin type in (or scan in) the
-- real code from Add Items / Edit Items whenever one exists. Existing
-- seeded units are left null for the same reason — nothing here is
-- tied to a real physical sticker yet.
-- ============================================================
alter table public.item_units
  add column qr_code text;

alter table public.item_units
  add constraint item_units_qr_code_unique unique (qr_code);
