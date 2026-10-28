-- ============================================================
-- One-off catalog import -- 11 new Camera Dept items at The Cage,
-- requested 10/7 (Suzanne's rows, corrected: "Film Cage" -> "The Cage",
-- the location's real name).
--
-- Also adds a new "Misc" DIRECT category and tags all 11 items with
-- it -- Suzanne noticed the general categories already have a Misc
-- catch-all (Camera Dept, Sound Dept, Misc) but the direct categories
-- didn't (Batteries, Cameras, Lenses, Lights, Light Stands, SD Cards,
-- Sound Equipment), and these 11 items are exactly the case that gap
-- was missing: none of them are a battery, a camera, a lens, a light,
-- a light stand, an SD card, or sound equipment.
--
-- Safe to run more than once, in either order relative to a previous
-- run: a model that already exists is skipped (with a NOTICE) rather
-- than duplicated, but if it's missing the Misc tag -- e.g. because
-- this ran once before that category existed -- it gets backfilled
-- rather than left alone. The Misc category itself is only created if
-- it doesn't already exist. Also fails loudly up front if "The Cage"
-- or "Camera Dept" don't resolve, rather than silently inserting a
-- wrong or null reference.
--
-- Validated against a fresh local Postgres copy of the full schema
-- (all 29 migrations) before being handed over, both as a first run
-- and as a re-run against data this same script already created.
--
-- Run this in the Supabase SQL Editor against the real project --
-- neither of Claude's shells can reach *.supabase.co.
-- ============================================================
do $$
declare
  v_location_id uuid;
  v_general_category_id uuid;
  v_direct_category_id uuid;
  v_model_id uuid;
  v_existing_id uuid;
  item record;
  items jsonb := '[
    {"name": "1/4\"-20 Lens Support", "brand": null, "model": null, "quantity": 6},
    {"name": "15mm 10\" rod", "brand": null, "model": null, "quantity": 2},
    {"name": "15mm 12\" rod", "brand": null, "model": null, "quantity": 10},
    {"name": "15mm 18\" Rod", "brand": null, "model": null, "quantity": 8},
    {"name": "15mm 24\" Silver Rod", "brand": null, "model": null, "quantity": 4},
    {"name": "15mm 4\" Rod", "brand": null, "model": null, "quantity": 10},
    {"name": "15mm 8\" rod", "brand": null, "model": null, "quantity": 4},
    {"name": "90 degree HDMI adapter", "brand": null, "model": null, "quantity": 24},
    {"name": "90 degree USB-C adapter", "brand": null, "model": null, "quantity": 3},
    {"name": "AC (Assistant Camera) Kit", "brand": null, "model": null, "quantity": 2},
    {"name": "Accsoon CineEye2", "brand": "Accsoon", "model": "CineEye2", "quantity": 1}
  ]'::jsonb;
begin
  select id into v_location_id from public.locations where name = 'The Cage';
  if v_location_id is null then
    raise exception 'Location "The Cage" not found -- check the exact name in Supabase before re-running.';
  end if;

  select id into v_general_category_id from public.categories where name = 'Camera Dept' and kind = 'general';
  if v_general_category_id is null then
    raise exception 'Category "Camera Dept" (general) not found -- check the exact name in Supabase before re-running.';
  end if;

  select id into v_direct_category_id from public.categories where name = 'Misc' and kind = 'direct';
  if v_direct_category_id is null then
    insert into public.categories (name, kind, display_order)
    values ('Misc', 'direct', 8) -- one past the existing 7 direct categories
    returning id into v_direct_category_id;
    raise notice 'Created new direct category "Misc".';
  end if;

  for item in select * from jsonb_to_recordset(items) as x(name text, brand text, model text, quantity int)
  loop
    select id into v_existing_id
      from public.item_models
      where name = item.name
        and location_id = v_location_id
        and coalesce(brand, '') = coalesce(item.brand, '')
        and coalesce(model, '') = coalesce(item.model, '');

    if v_existing_id is not null then
      update public.item_models set direct_category_id = v_direct_category_id
        where id = v_existing_id and direct_category_id is null;
      raise notice 'Skipping "%": already exists (Misc tag backfilled if it was missing).', item.name;
      continue;
    end if;

    insert into public.item_models (name, brand, model, location_id, general_category_id, direct_category_id)
    values (item.name, item.brand, item.model, v_location_id, v_general_category_id, v_direct_category_id)
    returning id into v_model_id;

    insert into public.item_units (item_model_id, unit_code)
    select v_model_id, gs::text
    from generate_series(1, item.quantity) as gs;

    raise notice 'Added "%" -- % unit(s), tagged Misc.', item.name, item.quantity;
  end loop;
end $$;
