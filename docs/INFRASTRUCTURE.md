# Infrastructure

What we run, what we deliberately don't, and how the pieces authenticate to each other.

---

## 1. The whole inventory

| Service | Used for | Notes |
|---|---|---|
| **Supabase Auth** | Identity | Email OTP today, phone OTP remains a production option — see §2 |
| **Supabase Postgres** | OLTP source of truth | Users, groups, chat, RSVPs, private assignments, ballots, mutual contacts |
| **Supabase Realtime** | Group chat | `postgres_changes` on `messages` |
| **Supabase Storage** | Profile photos | Private bucket, signed URLs |
| **Supabase Edge Functions** | All server code | Deno. Holds every secret |
| **`pg_cron`** | The weekly matching sweep | Calls `run-matching` on a schedule |
| **ClickHouse Cloud** | OLAP | Vectors, archetypes, population centroid, event stream |
| **Voyage AI** | Embeddings | `voyage-4`, 256 dims, 200M free tokens |
| **Anthropic** | Tag extraction, venue, questions | `claude-opus-5` |

**Not used, deliberately:**

| Thing | Why not |
|---|---|
| `pgvector` | See §9 — the interesting question, and we should have an answer ready |
| Firebase | Would be a second auth system to wire, and cannot satisfy the ClickHouse+Postgres requirement |
| FCM / APNs | No paid Apple account; the ladder is on-device today (see `PUSH_NOTIFICATIONS.md`) |
| A separate API server | The edge functions are the whole backend; a third deployable is a third thing to break |
| Supabase Vault | Function secrets are sufficient at this scale |

---

## 2. Authentication

### 2.1 The decision

**Email OTP for the hackathon.** `signInWithOtp()` followed by `verifyOTP()` creates a real
row in `auth.users` and issues the JWT that every RLS policy uses. Local codes land in Inbucket;
the hosted project must have enough SMTP quota for the small demo cohort.

The reasoning is about demo risk, not about laziness:

| Option | Blocker |
|---|---|
| **Phone OTP** | Needs an SMS provider (Twilio/Vonage) configured and funded. Real setup, real cost, and an SMS that has to arrive on stage over venue wifi. |
| **Email OTP** | Built and testable entirely in-app. Hosted SMTP remains a rehearsal risk, so demo accounts should be created before stage time. |
| **Email + password** | Works, no external service, but adds two fields and a keyboard to the first screen of a product whose whole pitch is "the only decision is attend or don't". |
| **Anonymous** | Lowest-friction fallback, but a cleared app loses the only credential that owns the user's private profile and contact selections. |

Email sign-in must be enabled in the Supabase dashboard. Local development exposes codes at
<http://127.0.0.1:54324>.

### 2.2 The phone number is profile data, not a credential

This is worth stating because it looks like a contradiction: the product's climax is
sharing your phone number, but the phone number is not how you log in.

Decoupling them is correct regardless of the hackathon. `profiles.phone` is column-revoked from
direct groupmate reads and disclosed only by `mutual_contacts()` after two selections agree. Making it also
the auth credential would conflate "how the system knows you" with "what you're willing to
give a stranger", and would mean you cannot use the app without being reachable.

### 2.3 The JWT flow

```
Flutter                          Edge Function                    Postgres
  │                                    │                             │
  ├─ signInWithOtp() / verifyOTP() ────┼────────────────────────────►│ auth.users row
  │◄─ JWT ─────────────────────────────┼─────────────────────────────┤
  │                                    │                             │
  ├─ from('profiles').select() ────────┼────────────────────────────►│ RLS: auth.uid()
  │                                    │                             │
  └─ functions.invoke(                 │                             │
       'submit-profile',               │                             │
       headers: Authorization: JWT) ──►│                             │
                                       ├─ createClient(anon, {       │
                                       │    Authorization: JWT })────►│ RLS still applies
                                       └─ ch(...) ──► ClickHouse     │
```

Three distinct credentials, and mixing them up is the classic way to open a hole:

| Credential | Held by | Bypasses RLS | Used for |
|---|---|---|---|
| **anon key** | The Flutter app (public by design) | No | All direct client reads/writes |
| **user JWT** | The Flutter app, per session | No | Identifying the caller to an edge function |
| **service role key** | Edge functions only, never the app | **Yes** | `run-matching` writing groups for people who are not the caller |

`submit-profile` deliberately builds its Supabase client from the **anon key plus the
caller's JWT**, not the service role. That way a user cannot write a profile for somebody
else by passing a different id — RLS rejects it. The service role appears in exactly one
place, `run-matching`, because that function legitimately acts as the system.

### 2.4 RLS is the entire security model

The Flutter app talks to Postgres directly with a key that is published in the app binary.
That is safe *only* because every table has RLS enabled and a policy that scopes rows to
`auth.uid()`.

The consequence for the team: **adding a table without policies in the same migration
publishes it to the internet.** There is no second line of defence.

Two policies encode product rules rather than mere access control, and both are in
`supabase/migrations/0001_init.sql`:

- **`number_shares`** — you can read the group's numbers only if you have shared yours.
- **`reflections`** — you can read what your pair wrote about you only once you have
  written yours.

Both must live in the database. If the client decides, the data has already reached the
device and the gate is decorative.

There is also, deliberately, **no policy anywhere that lets a user list people they have not
been matched with.** There is no browse in this product, so the database cannot serve one.

### 2.5 Production

Phone OTP via Twilio, with the number reused as both credential and (optionally) the shared
contact. ID verification (Stripe Identity or Persona) sits between sign-up and profile
creation, gating `profiles.verified_at`. Neither is built today.

---

## 3. Postgres

One migration, `supabase/migrations/0001_init.sql`, containing the schema and every policy.

- `profiles.id` references `auth.users(id)` with `on delete cascade`, so account deletion
  removes the profile.
- `profiles.embedded_at` is null until `submit-profile` has successfully written the vector
  to ClickHouse. `run-matching` filters on it, so a profile that failed to embed is
  invisible to matching rather than silently unmatched.
- `groups.cohesion` stores the average pairwise distance within the group, which is what
  `clickhouse/queries/cohesion.sql` slices outcomes by.
- `shares_group_with()` is `security definer` so it can read `group_members` without
  recursing through that table's own policy.

Migrations run with `supabase db push`. There is no second environment — one project, and
the reset path is `scripts/demo_reset.sh`, not a migration rollback.

---

## 4. Realtime

Group chat is `postgres_changes` on `messages`:

```dart
supabase.from('messages').stream(primaryKey: ['id'])
    .eq('group_id', groupId)
    .order('created_at')
    .listen(render);
```

**The gotcha that costs an hour:** the table must be added to the `supabase_realtime`
publication or the stream returns the initial rows and then silently never updates again.
No error, no warning — a chat that does not chat. The `alter publication` is the last line
of the migration for this reason.

Realtime respects RLS, so a user only receives changes for rows they could have selected.
No additional filtering is needed server-side.

---

## 5. Storage

One private bucket, `photos`.

- Uploads are keyed `{user_id}/profile.jpg` so an upsert replaces the one current identity photo
  instead of accumulating abandoned objects.
- Reads go through signed URLs with a short expiry rather than making the bucket public.
- Only groupmates can generate a signed URL for a given photo.

**The "clear photo of you" rule is client-enforced only.** We do not run image classification on
upload. A determined user can upload anything. **[hackathon shortcut]** — in production this is
a vision/moderation check in the upload path.

---

## 6. Edge functions

Three functions, all Deno, all in `supabase/functions/`.

| Function | Auth | Calls out to | Triggered by |
|---|---|---|---|
| `submit-profile` | User JWT | Voyage, Anthropic, ClickHouse | End of onboarding |
| `run-matching` | Service role | Anthropic, ClickHouse | `pg_cron`, or a demo button |
| `analytics` | None today | ClickHouse | Dashboard |

**`_shared/` — the underscore is load-bearing.** Supabase deploys every directory under
`functions/` as its own function. A leading underscore marks a directory as shared code and
skips it. Rename it `shared/` and deployment fails with a confusing error about a missing
entrypoint.

**`analytics` is currently unauthenticated.** That is fine for a judge-facing dashboard
containing only aggregates, and not fine for anything else. Worth stating out loud rather
than discovering later.

Deployment:

```bash
supabase functions deploy                      # all three
supabase functions deploy run-matching         # or one
supabase functions logs run-matching --tail    # the only debugging you get
```

Cold start is real (a second or two). It is invisible in `submit-profile`, which the user
expects to take a moment, and irrelevant for `run-matching`, which is a batch job.

---

## 7. Scheduling

`pg_cron` runs inside Postgres and calls the matching function over HTTP:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('weekly-matching', '0 12 * * 1', $$
  select net.http_post(
    url     := 'https://<ref>.supabase.co/functions/v1/run-matching',
    headers := '{"Authorization": "Bearer <service_role_key>", "Content-Type": "application/json"}'::jsonb,
    body    := '{"city":"SF","slot":"fri_eve"}'::jsonb
  );
$$);
```

For the demo the same function is called directly by `scripts/demo_reset.sh`, so the cron
job is a production detail rather than something the demo depends on.

---

## 8. ClickHouse Cloud

Reached only over its HTTPS interface (port 8443), only from edge functions, using
`X-ClickHouse-User` / `X-ClickHouse-Key` headers. No driver — the interface takes raw SQL in
the POST body and returns JSON.

All parameters go through ClickHouse's `{name:Type}` syntax with `param_*` on the query
string. Never interpolated: the embedding and tags originate in user input, and ClickHouse
will happily execute whatever SQL it is handed.

Setup order matters and is not obvious:

```
clickhouse/001_schema.sql   →  scripts/seed_archetypes.py  →  clickhouse/002_seed.sql
     (tables)                      (200 real embeddings)         (1M synthetic profiles)
```

Running the seed before the archetypes exist inserts nothing and reports success.

---

## 9. "Why not just use pgvector?"

A judge will ask this. The honest answer has three parts, and the honest answer is better
than a defensive one.

**At our current scale, pgvector would work.** For a few thousand users in one city,
Postgres with an HNSW index answers this query fine, and one database is simpler than two.
Pretending otherwise would be easy to see through.

**The workload's shape is analytical, not transactional.** Matching is not a lookup, it is a
full-population sweep that runs on a schedule and touches every row. Pushing it into the
OLTP database means the batch job competes for the same connections and buffer pool serving
live chat. Separating them is the standard reason OLAP systems exist.

**The event stream is the part Postgres genuinely handles badly.** The funnel and cohesion
queries scan every event and aggregate. In Postgres that is a growing table competing with
transactional traffic, and each new slice needs another index. In ClickHouse it is a
`windowFunnel` over a columnar table, and adding a dimension costs nothing.

The load-bearing sentence: **the vectors could live in either, the event stream really
wants ClickHouse, and once ClickHouse is there the scan belongs next to the analytics.**

---

## 10. Secrets

```
.env.example        committed, names only, no values
.env                gitignored
```

| Secret | Lives in |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | The Flutter app, via `--dart-define`. Public by design |
| `SUPABASE_SERVICE_ROLE_KEY` | Function secrets only. **Never** in the app |
| `CLICKHOUSE_URL/USER/PASSWORD` | Function secrets only |
| `VOYAGE_API_KEY`, `ANTHROPIC_API_KEY` | Function secrets only |

```bash
supabase secrets set --env-file .env.functions
```

The two public values reach Flutter via `--dart-define` rather than a committed constants
file, so the app can be pointed at a different project without a code change:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://xxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ...
```

**If a service role key ever reaches the client, every RLS policy in this document becomes
decorative.** That is the one mistake with no recovery short of rotating the key.

---

## 11. Setup checklist

Roughly in dependency order. Items marked ⚠ are the ones that fail quietly.

- [ ] Create Supabase project, note the ref
- [ ] ⚠ Enable **email OTP** and verify hosted SMTP quota before rehearsal
- [ ] `supabase link --project-ref <ref>`
- [ ] `supabase db push`
- [ ] ⚠ Verify `messages` is in the `supabase_realtime` publication
- [ ] Verify migration `0002` created the private `photos` bucket and storage policies
- [ ] Create ClickHouse Cloud service, note the HTTPS endpoint and password
- [ ] Fill `.env` from `.env.example`
- [ ] `supabase secrets set --env-file .env`
- [ ] `supabase functions deploy`
- [ ] Run `clickhouse/001_schema.sql`
- [ ] ⚠ Run `scripts/seed_archetypes.py` **before** the seed SQL
- [ ] Run `clickhouse/002_seed.sql` and **read its final sanity check** — if nearest and
      farthest are within ~0.03, mean-centering is broken and every match is noise
- [ ] ⚠ Set the Xcode signing team so a build reaches the physical iPhone
- [ ] `flutter run` with both `--dart-define`s
