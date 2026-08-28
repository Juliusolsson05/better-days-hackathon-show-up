# Show Up

Small groups of solo attendees, matched by interest, meeting in person.

Built for the ClickHouse **Better Days** hackathon — loneliness track.

---

# PRD: Solo Meetups

## Problem

People skip things they want to do because going alone feels awkward. The barrier isn't
lack of interest or lack of options, it's the discomfort of showing up by yourself.

## User

Anyone who avoids going out alone. Not defined by life stage or personality label. "New to
the city" is a marketing angle, not the user definition.

## Solution

Small groups of 4 to 6 solo attendees, matched by interest. Everyone came alone, so no one
is the odd one out. Each attendee gets an assigned question to ask one specific person,
turning open-ended small talk into one concrete task.

## Decisions taken

- Solo only. Not shareable, no plus-ones.
- Groups reshuffle each meetup. Continuity is a v2 question.
- The group chat is the product surface. Everything before the meetup happens inside it.

## How it works

**1. Signup** — User picks from a fixed interest set and uploads a photo. Both are required.
Interests are the matching input. Photo is what makes the group feel like people rather
than names.

**2. Matching** — System forms a group of 4 to 6 from interest overlap and availability.
Manual override in early cities.

**3. The group forms, which means the group chat opens** — Group formation and group chat
are the same event. There is no separate lobby, roster screen, or pre-chat state. Once
matched, users land in a live chat with their group. Tapping the group name shows members
and photos, the way WhatsApp or Instagram group info works. There is no standalone profile
page.

**4. Venue voting, inside the chat** — The app posts 2 or 3 venue options into the chat as a
message. Members vote on it there. Voting is anonymous, so only the tally and the result are
visible, never who voted for what. No one feels responsible for the outcome. No voting
deadline in MVP.

**5. Assigned questions** — Before the meetup, each person privately receives one
lighthearted question and the name of one group member to ask it to. Matching guarantees
every member is someone's target, so no one is left out. Questions are never revealed to
the group.

**6. The meetup**

**7. Post-meetup flow** — One flow, three steps:
- *What did you learn?* From your assigned question. If your target didn't show, a fallback
  screen asks what you learned about anyone else instead.
- *Attendance.* Mark who showed up.
- *Contact exchange.* Select who you'd share your number with.

**8. Contact exchange** — Numbers become visible only on mutual selection. No notifications
and no signal about who selected whom, so being unselected is invisible. It lives as a
section inside the group, visible only to people you've mutually matched with. Persists
indefinitely.

**9. After the meetup** — The group chat stays alive. No archiving in MVP.

**10. Flaking** — Attendance comes from the group's votes. The app acknowledges the no-show
to that user privately. No penalty, no effect on the group. They're placed in the next
meetup as normal.

---

## Architecture

The matching step is genuinely an OLAP query: take one person's embedding and find the
nearest neighbours across the entire population, filtered on availability and geography.
That is a full scan, and it has to stay fast as a city grows. Postgres holds the state that
must be correct right now; ClickHouse holds everything that gets scanned in bulk.

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

| Path | What lives there |
|---|---|
| `app/` | Flutter client (iOS + Android). Feature-first, one folder per screen flow. |
| `supabase/migrations/` | Postgres schema and every RLS policy. |
| `supabase/functions/` | The only server code. `_shared/` is skipped by deploy — the underscore matters. |
| `clickhouse/` | Schema, the million-row seed, and the demo queries. |
| `scripts/` | Archetype embedding, demo reset. |
| `docs/` | Design, infrastructure, push notifications, venue matching. |

## Setup

```bash
cp .env.example .env          # fill in, then:
supabase link --project-ref <ref>
supabase db push
supabase secrets set --env-file .env.functions
supabase functions deploy

clickhouse client --host <host> --secure --password <pw> < clickhouse/001_schema.sql
python scripts/seed_archetypes.py
clickhouse client --host <host> --secure --password <pw> < clickhouse/002_seed.sql

cd app && flutter run \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

Full checklist, including the two steps that fail silently: `docs/INFRASTRUCTURE.md`.

## Two things that will bite

**Embeddings are 256-dimensional and mean-centered.** Raw embeddings are anisotropic —
every vector points into the same narrow cone, so any two profiles score ~0.85 and the
nearest-neighbour ranking collapses into noise. `002_seed.sql` ends with a sanity check; if
`nearest` and `farthest` are within ~0.03 of each other, centering isn't working and every
match downstream is meaningless. The dimension is baked into the ClickHouse schema —
changing it means reseeding.

**Embeddings can't tell a stance from its opposite.** "I love hunting" and "I think hunting
is barbaric" embed almost identically, because embeddings capture what you're talking about,
not what you think about it. That's why `profile_vectors` carries tags alongside the vector:
the embedding is the recall step, the tags Claude extracts are the precision step.

---

## Implementation deltas

The PRD above supersedes the earlier spec. Migration `0002_product_contracts.sql` is the
database contract for the current rules. Private assignments, phone numbers, ballots, and
one-way contact selections are separated at that boundary so a modified client cannot reveal
them. Current state:

| PRD says | State | Where |
|---|---|---|
| Groups of **4 to 6** | done | `run-matching` `MIN_GROUP`/`MAX_GROUP` |
| App posts **2-3 venue options**, group votes **anonymously** | database + app protocol done | `venue_options`, `venue_votes`, `venue_tally()` |
| Contact exchange on **mutual selection**, unselected is invisible | database + app protocol done | `contact_selections`, `mutual_contacts()` |
| Attendance from the **group's votes** | database + app protocol done | `attendance_votes`, `attendance_result()` |
| Photo **required**, faces are the point | done | private `photos` bucket + signed groupmate URLs |
| Group chat opens **at formation**, is the only surface | done | `app/lib/features/group/` |
| No standalone profile page | done - keep it that way | - |
| Groups **reshuffle** each meetup | not built | `run-matching` |

Venue retrieval remains an independent deployment step: its output persists through
`replace_venue_options()`, which validates 2-3 grounded choices and posts the vote into chat.
Until that pipeline runs for a group, its legacy model-selected venue is shown only as a rollout
fallback.
