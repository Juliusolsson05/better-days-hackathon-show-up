# Signup against the real backend

The app defaults to `MockRepository` and needs nothing. To run the signup flow against
Supabase (email OTP → photo upload → `submit-profile`):

```bash
cd app && flutter run \
  --dart-define=USE_SUPABASE=true \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_ANON_KEY=<anon key from `supabase start`>
```

Without `USE_SUPABASE=true`, `main()` never calls `Supabase.initialize` and the app is
mock-only — the auth screen does not appear.

## What the flow does

1. **`AuthScreen`** — `signInWithOtp(email, shouldCreateUser: true)`, then `verifyOTP`
   with the six-digit code. Local stack: codes land in Inbucket at
   <http://127.0.0.1:54324>. A restored session skips straight to onboarding.
2. **`OnboardingScreen`** — name, photo (gallery), chat emoji, fixed interests + your
   own, passion free-text, availability.
3. **`SupabaseRepository.submitProfile`** — uploads the photo to
   `photos/<uid>/profile.jpg` (upsert), then calls the `submit-profile` edge function
   with `photo_url`. The function upserts `profiles`, embeds via Voyage, extracts tags
   via Claude, and writes `profile_vectors`.

## One-time setup: the photo bucket

`submit-profile` and the storage upload assume a public `photos` bucket. It is not in a
migration yet (schema `0002` is still a draft). Create it once:

```sql
insert into storage.buckets (id, name, public) values ('photos', 'photos', true)
on conflict (id) do nothing;

create policy "own photo upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own photo update" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos are public" on storage.objects for select
  using (bucket_id = 'photos');
```

## Open decisions

- **Photo required?** The PRD says yes; the widget test and mock demo treat it as
  optional, so `_valid` in `OnboardingScreen` does not block on it. Flip one clause to
  enforce it once the team agrees (and update `app/test/widget_test.dart`).
- **City** is hardcoded to `SF` in `OnboardingScreen._submit`.
- The group / chat / vote / after-meetup methods on `SupabaseRepository` throw
  `UnimplementedError` — they need the `0002` schema promoted out of `drafts/`.
