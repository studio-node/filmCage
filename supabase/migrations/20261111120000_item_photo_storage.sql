-- ============================================================
-- ITEM PHOTO STORAGE
-- Suzanne's ask (11/11): Browse Equipment cards should show a real
-- photo per item model instead of the placeholder camera icon, and
-- there needs to be a way to upload one from the Add Items / Edit
-- Items screens. item_models.picture_url has existed since the very
-- first migration but nothing has ever written to it -- this
-- migration adds the one missing piece: somewhere to actually store
-- the file.
--
-- A new public Storage bucket, 'item-photos'. Public so a plain
-- <img :src="picture_url"> works with no auth header, same as any
-- other public Storage bucket -- there's no sensitive content here,
-- just equipment photos. Upload/replace/delete is staff+ only,
-- matching who can already add/edit items in item_models itself.
-- Read is open to everyone (and, since the bucket is public, to a
-- bare <img> tag with no session at all).
-- ============================================================

insert into storage.buckets (id, name, public)
values ('item-photos', 'item-photos', true)
on conflict (id) do nothing;

create policy "item_photos_read_all"
  on storage.objects for select
  using (bucket_id = 'item-photos');

create policy "item_photos_write_staff"
  on storage.objects for insert
  with check (
    bucket_id = 'item-photos'
    and public.current_user_role() in ('staff', 'supervisor', 'admin')
  );

create policy "item_photos_update_staff"
  on storage.objects for update
  using (
    bucket_id = 'item-photos'
    and public.current_user_role() in ('staff', 'supervisor', 'admin')
  )
  with check (
    bucket_id = 'item-photos'
    and public.current_user_role() in ('staff', 'supervisor', 'admin')
  );

create policy "item_photos_delete_staff"
  on storage.objects for delete
  using (
    bucket_id = 'item-photos'
    and public.current_user_role() in ('staff', 'supervisor', 'admin')
  );
