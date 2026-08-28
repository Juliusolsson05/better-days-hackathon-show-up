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
   <http://127.0.0.1:54324>. A restored session reconstructs whether the user is onboarding,
   waiting, or already matched.
2. **`OnboardingScreen`** — name, phone, required photo (gallery), chat emoji, fixed interests
   + your own, passion free-text, availability.
3. **`SupabaseRepository.submitProfile`** — uploads the photo to
   `photos/<uid>/profile.jpg` (upsert), then calls the `submit-profile` edge function
   with `photo_url`. The function upserts `profiles`, embeds via Voyage, extracts tags
   via Claude, and writes `profile_vectors`.

## Photo storage

Migration `0002_product_contracts.sql` creates the private `photos` bucket and its policies.
Profiles store the object path, not a permanent public URL; groupmates receive a short-lived
signed URL only after RLS confirms shared membership.

## Open decisions

- **City** is hardcoded to `SF` in `OnboardingScreen._submit`.
- Phone normalisation assumes an SF/US user when ten local digits are entered. Replace the
  `normalizeSfPhone` seam with country-aware parsing when city selection is built.
