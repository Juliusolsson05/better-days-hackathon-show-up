-- Reproduce the manual state operators were told to create before Storage lived in migrations.
-- A clean 0001 database is not a sufficient upgrade test: it omits the exact public policy that
-- makes privacy depend on migration cleanup rather than only on the new desired-state DDL.

insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do update set public = excluded.public;

create policy "own photo upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own photo update" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos are public" on storage.objects for select
  using (bucket_id = 'photos');

insert into auth.users (id)
values ('00000000-0000-4000-8000-000000000099');

insert into public.profiles (
    id, display_name, passion, tags, city, availability, photo_url, embedded_at
)
values (
    '00000000-0000-4000-8000-000000000099',
    'Legacy Photo User',
    'A sufficiently long legacy passion',
    array['legacy'],
    'SF',
    array['fri_eve'],
    'http://127.0.0.1:54321/storage/v1/object/public/photos/' ||
      '00000000-0000-4000-8000-000000000099/profile.jpg',
    now()
);
