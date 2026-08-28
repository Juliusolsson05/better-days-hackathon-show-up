# The analytics dashboard

`dashboard/index.html` — a single static file, no build, no dependencies. It is the demo's
closing slide (`docs/DESIGN.md` §6): the funnel from *notified* to *left with each other's
numbers*, plus the ClickHouse scan cost, on screen.

## Why it is separate from the app

It runs on the presenter's laptop / the projector while the demo phone runs the Flutter
app. Baking it into the phone build would make the closing slide something you have to
screen-mirror. The `analytics` edge function already sets `Access-Control-Allow-Origin: *`
for exactly this — a browser page calling it directly.

## Running it

```bash
cd dashboard && python3 -m http.server 8777    # or any static host, or just open the file
```

Open it, and either paste the two values into the gate or pass them in the URL:

```
http://localhost:8777/?url=https://<ref>.supabase.co&key=<anon key>
```

- **URL** — the Supabase project URL (`http://127.0.0.1:54321` for the local stack).
- **Anon key** — public by design (`.env.example`); it is stored only in that browser's
  `localStorage`. The dashboard reads no protected table, so this is not a data-exposure
  risk.

The page polls every 15s so the numbers move as the audience RSVPs. The status dot goes
grey if an update is more than ~25s late — a wedged tab is visible from the back of the
room.

## One deploy detail

Supabase's function gateway wants a valid key even though `analytics/index.ts` itself does
no auth check. The page sends `Authorization: Bearer <anon key>` (a valid JWT), which
works whether or not the function is deployed with `verify_jwt` on. If you see 401s,
deploy it as:

```bash
supabase functions deploy analytics --no-verify-jwt
```

The page sends **only** the `Authorization` header — not `apikey` — because the function's
`Access-Control-Allow-Headers` is `authorization, content-type`, so an `apikey` header
would fail CORS preflight.

## What each panel reads

| Panel | Source | Notes |
|---|---|---|
| The funnel | `funnel`: `[{level, people}]` from `windowFunnel(notif_sent → rsvp → attended → number_shared)` | `level` is the furthest step a user reached, 0–4. The page folds these into **cumulative** bars (everyone who got *at least* this far) and marks each drop-off. |
| Match-tightness scale | `cohesion`: `[{bucket, n}]` — `group_formed` count per rounded `seed_distance` | Shows *where groups landed* on the tightness axis. A true per-bucket funnel (does a tighter match convert better?) needs the function to cross `windowFunnel` with this bucket — a follow-up on the edge function, not the page. |
| Events · last 7 days | `volume`: `[{name, n}]` | Raw event counts. |
| Footer | `scanned` = `funnel.stats` (ClickHouse `statistics` block) | `rows_read` and `elapsed`. `docs/DESIGN.md` §4.7: the database reporting its own scan cost rather than us claiming a number. |

## Follow-ups

- Per-bucket funnel (the real "tighter match → more numbers exchanged" claim) — needs a
  query change in `supabase/functions/analytics/index.ts`.
- If the event stream is empty the funnel shows an empty state; there is no seeded demo
  data path here (that lives in `clickhouse/002_seed.sql`).
