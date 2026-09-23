-- ============================================================
-- SAMPLE DATA — locations, hours, and a starter equipment catalog.
--
-- This is demo/sample content, not structural schema, so it's a
-- lighter-weight migration than the schema ones — but it follows the
-- same seed-data convention already used for categories and
-- course_tier_mappings in the initial migration. Replace or expand
-- with the department's real inventory before this goes live for
-- real use; these rows exist so the frontend has something real to
-- render against while it's being built.
-- ============================================================

-- ============================================================
-- LOCATIONS (the three from the confirmed rename mapping:
-- Digital Media Cage -> The Cage, Sound Stage Locker -> Studio C,
-- Broadcast Studio Closet -> Media Room)
-- ============================================================
insert into public.locations (name, building, room) values
  ('The Cage',    'Jennings Building', 'JEN 145'),
  ('Studio C',    'Jennings Building', 'JEN 210'),
  ('Media Room',  'Jennings Building', 'JEN 118');

-- Mon–Thu 8am–5pm open, Fri 10am–5pm by appointment only, Sat/Sun closed
-- — same hours at all three locations for now.
insert into public.location_hours (location_id, day_of_week, is_open, appointment_only, open_time, close_time)
select l.id, d.day, d.is_open, d.appointment_only, d.open_time, d.close_time
from public.locations l
cross join (values
  ('monday'::day_of_week_enum,    true,  false, time '08:00', time '17:00'),
  ('tuesday'::day_of_week_enum,   true,  false, time '08:00', time '17:00'),
  ('wednesday'::day_of_week_enum, true,  false, time '08:00', time '17:00'),
  ('thursday'::day_of_week_enum,  true,  false, time '08:00', time '17:00'),
  ('friday'::day_of_week_enum,    true,  true,  time '10:00', time '17:00'),
  ('saturday'::day_of_week_enum,  false, false, null, null),
  ('sunday'::day_of_week_enum,    false, false, null, null)
) as d(day, is_open, appointment_only, open_time, close_time);

-- ============================================================
-- ITEM MODELS + PER-UNIT INVENTORY
-- Each model picks a direct category and a general category
-- independently, per the confirmed v4 category rules.
-- ============================================================
insert into public.item_models (id, name, brand, model, purchase_price, location_id, description, direct_category_id, general_category_id, min_tier)
select
  gen_random_uuid(), v.name, v.brand, v.model, v.price,
  (select id from public.locations where name = v.loc),
  v.description,
  (select id from public.categories where name = v.direct_cat and kind = 'direct'),
  (select id from public.categories where name = v.general_cat and kind = 'general'),
  v.tier::student_tier
from (values
  ('Canon EOS R6 Mark II', 'Canon', 'EOS R6 Mark II', 2499.00, 'The Cage',
    'Full-frame mirrorless, 4K60 oversampled video, in-body stabilization.', 'Cameras', 'Camera Dept', 'beginner'),
  ('Blackmagic Pocket Cinema Camera 6K', 'Blackmagic Design', 'BMPCC 6K', 2635.00, 'The Cage',
    'Super 35 sensor, records Blackmagic RAW, EF lens mount.', 'Cameras', 'Camera Dept', 'intermediate'),
  ('Canon RF 24-70mm f/2.8L', 'Canon', 'RF 24-70mm f/2.8L IS USM', 2299.00, 'The Cage',
    'Standard zoom, constant f/2.8, image stabilization.', 'Lenses', 'Camera Dept', 'intermediate'),
  ('Aputure 300d Mark II', 'Aputure', '300d Mark II', 1000.00, 'Studio C',
    'Daylight-balanced LED point-source light, 300W.', 'Lights', 'Camera Dept', 'intermediate'),
  ('C-Stand Kit', 'Matthews', 'C-Stand 40"', 150.00, 'Studio C',
    'Grip stand with turtle base, boom arm, and sandbag.', 'Light Stands', 'Camera Dept', 'beginner'),
  ('Rode Wireless GO II', 'Rode', 'Wireless GO II', 300.00, 'Media Room',
    'Dual-channel wireless mic system, on-board recording.', 'Sound Equipment', 'Sound Dept', 'beginner'),
  ('Zoom H6 Recorder', 'Zoom', 'H6', 400.00, 'Studio C',
    '6-track portable recorder with interchangeable mic capsules.', 'Sound Equipment', 'Sound Dept', 'beginner'),
  ('Canon LP-E6NH Battery', 'Canon', 'LP-E6NH', 80.00, 'The Cage',
    'Rechargeable battery pack for EOS R-series bodies.', 'Batteries', 'Misc', 'beginner'),
  ('SanDisk Extreme Pro 128GB', 'SanDisk', 'Extreme Pro SDXC', 40.00, 'The Cage',
    'UHS-I V30 SD card, 128GB.', 'SD Cards', 'Misc', 'beginner')
) as v(name, brand, model, price, loc, description, direct_cat, general_cat, tier);

-- Per-unit inventory. Most units are in good condition; a couple are
-- deliberately caution/damaged so the frontend has real variety to
-- render (status dots, availability counts, the drawer's lock-note).
insert into public.item_units (item_model_id, unit_code, condition, condition_note)
select m.id, u.unit_code, u.condition::unit_condition, u.note
from public.item_models m
join (values
  ('Canon EOS R6 Mark II',              'A', 'good',   null),
  ('Canon EOS R6 Mark II',              'B', 'good',   null),
  ('Canon EOS R6 Mark II',              'C', 'good',   null),
  ('Blackmagic Pocket Cinema Camera 6K','A', 'good',   null),
  ('Blackmagic Pocket Cinema Camera 6K','B', 'caution','Viewfinder loose, still shoots fine.'),
  ('Canon RF 24-70mm f/2.8L',           'A', 'good',   null),
  ('Canon RF 24-70mm f/2.8L',           'B', 'good',   null),
  ('Aputure 300d Mark II',              'A', 'good',   null),
  ('Aputure 300d Mark II',              'B', 'good',   null),
  ('C-Stand Kit',                       'A', 'good',   null),
  ('C-Stand Kit',                       'B', 'good',   null),
  ('C-Stand Kit',                       'C', 'good',   null),
  ('C-Stand Kit',                       'D', 'good',   null),
  ('Rode Wireless GO II',               'A', 'good',   null),
  ('Rode Wireless GO II',               'B', 'damaged','Won''t power on, sent out for repair.'),
  ('Zoom H6 Recorder',                  'A', 'good',   null),
  ('Zoom H6 Recorder',                  'B', 'good',   null),
  ('Canon LP-E6NH Battery',             'A', 'good',   null),
  ('Canon LP-E6NH Battery',             'B', 'good',   null),
  ('Canon LP-E6NH Battery',             'C', 'good',   null),
  ('Canon LP-E6NH Battery',             'D', 'good',   null),
  ('Canon LP-E6NH Battery',             'E', 'good',   null),
  ('Canon LP-E6NH Battery',             'F', 'good',   null),
  ('SanDisk Extreme Pro 128GB',         'A', 'good',   null),
  ('SanDisk Extreme Pro 128GB',         'B', 'good',   null),
  ('SanDisk Extreme Pro 128GB',         'C', 'good',   null),
  ('SanDisk Extreme Pro 128GB',         'D', 'good',   null)
) as u(model_name, unit_code, condition, note) on m.name = u.model_name;
