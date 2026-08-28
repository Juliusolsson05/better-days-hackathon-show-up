# Show Up

Assigns people to small in-person groups. No browsing, no picking, no face photos.
The only decision is attend or don't. The intended endpoint is the group leaving the app
with each other's numbers.

Built for the ClickHouse **Better Days** hackathon — loneliness track.

## Why two databases

The matching step is genuinely an OLAP query: take one person's embedding and find the
nearest neighbours across the entire population, filtered on availability and geography.
That is a full scan, and it has to stay fast as a city grows. Postgres holds the state
that must be correct right now; ClickHouse holds everything that gets scanned in bulk.

```
                    anon key + RLS
   Flutter ─────────────────────────────► Supabase Postgres
      │                                       (OLTP: truth)
      │  user JWT                                  ▲
      └──────────► Edge Function ──────────────────┘
                        │  service role write-back
                        ├──────► ClickHouse Cloud   (OLAP: scan + event stream)
                        └──────► Voyage / Claude    (embed, extract, generate)
```

Flutter talks to Postgres directly — the anon key is public by design and RLS enforces
access per row. It never talks to ClickHouse: that interface accepts arbitrary SQL and has
no per-row permissions, so a credential inside the app binary would expose every profile.

## Layout

| Path | What lives there |
|---|---|
| `app/` | Flutter client (iOS + Android). Feature-first, one folder per screen flow. |
| `supabase/migrations/` | Postgres schema and every RLS policy. |
| `supabase/functions/` | The only server code. `_shared/` is skipped by deploy — the underscore matters. |
| `clickhouse/` | Schema, the million-row seed, and the demo queries. |
| `scripts/` | Archetype embedding, demo reset. |

## Setup

```bash
cp .env.example .env          # fill in, then:
supabase link --project-ref <ref>
supabase db push
supabase secrets set --env-file .env
supabase functions deploy

clickhouse client --host <host> --secure --password <pw> < clickhouse/001_schema.sql
python scripts/seed_archetypes.py
clickhouse client --host <host> --secure --password <pw> < clickhouse/002_seed.sql

cd app && flutter run \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

## Two things that will bite

**Embeddings are 256-dimensional and mean-centered.** Raw embeddings are anisotropic —
every vector points into the same narrow cone, so any two profiles score ~0.85 and the
nearest-neighbour ranking collapses into noise. `002_seed.sql` ends with a sanity check;
if `nearest` and `farthest` are within ~0.03 of each other, centering isn't working and
every match downstream is meaningless. The dimension is baked into the ClickHouse schema —
changing it means reseeding.

**Embeddings can't tell a stance from its opposite.** "I love hunting" and "I think hunting
is barbaric" embed almost identically, because embeddings capture what you're talking about,
not what you think about it. That's why `profile_vectors` carries tags alongside the vector:
the embedding is the recall step, the tags Claude extracts are the precision step. Removing
the tag filter will seat a vegan next to a hunter and report a great match.

## Demo notes

- No Android SDK on the build machine, so the push ladder (T-3d / T-1d / morning-of /
  10-min-away) runs through `flutter_local_notifications` on-device. Real FCM/APNs is a
  production line, not a today line.
- Sort out screen mirroring well before 5pm — that's how mobile demos die.
- `scripts/demo_reset.sh` exists so the run-through can be rehearsed repeatedly.
