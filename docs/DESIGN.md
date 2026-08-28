# Show Up — technical design

Point-in-time design document written during the ClickHouse **Better Days** hackathon
(San Francisco, 28 Aug 2026, loneliness track). It records what the product is, what the
system does, and every technical problem we know about — including the ones we are
choosing not to solve today.

This document is deliberately honest about what is real and what is stubbed. Anything
marked **[hackathon shortcut]** is a thing we would build properly with more than a day.

---

## 1. The product

### 1.1 The thesis

Half of American adults report being lonely, and it is worst among the young. Every
product built at this problem so far is a marketplace: profiles, photos, browsing,
choosing, matching, messaging. That shape has three failure modes.

1. **Choice is the tax.** Browsing people is work, and it is work that feels like being
   judged and judging. Most people bounce before they ever meet anyone.
2. **Photos make it romantic.** The moment faces are on screen, the product is read as
   dating, and the population self-selects accordingly.
3. **Messaging is a trap.** Chat becomes the product instead of the doorway, and people
   text for weeks and never meet.

Show Up removes all three. There is no browsing, no picking, and no face photos. You are
assigned to a group of six. The only decision you make is **attend or don't**.

The endpoint is not engagement. The endpoint is six people leaving with each other's
phone numbers and never opening the app again. We treat that as success, and we measure it.

### 1.2 The user journey

**Signup**
- ID verification. **[hackathon shortcut]** stubbed behind a flag; in production this is
  Stripe Identity or Persona.
- Pick interest tags from a predefined list, plus write your own (pokemon, anime, whatever).
- One free-text field: *what are you passionate about*. This is the field the matching
  actually runs on.
- Photos allowed, but not of your face.
- Availability and location.

**Matching**
- An LLM turns each profile into an embedding plus structured tags (topic, energy,
  indoor/outdoor, alcohol, talk-vs-activity, and stance flags).
- Match on the embedding; filter on tags, availability and geography.
- Auto-assigned to a group of six, first event that week.
- The AI picks the venue and activity to suit the group.

**In the app**
- Group chat, once assigned.
- A map showing the venue and the details of the meetup.

**Before**
- A push ladder: T-3d, T-1d, morning-of, 10-minutes-away.

**During**
- Each person gets one **main pair** and a generated question tied to their pair's own
  passion. *"Ask Jake what he thinks about X."*

**After**
- Each person is asked what stuck with them from their pair's answer. Mutual and disclosed —
  you see theirs once you have written yours.
- Then a button: share your number with the group. Not all-or-nothing. If you share, you
  see everyone else who shared. From there the group can leave the app, which is the
  intended endpoint.

### 1.3 What we are deliberately not building

- No profile browsing. There is no screen anywhere that lists people you have not been
  matched with, and no RLS policy that would permit one.
- No swiping, liking, or rating.
- No face photos.
- No algorithmic feed.
- No retention mechanics. We are not trying to make the app sticky.

---

## 2. System architecture

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

### 2.1 Why two databases

This is not compliance with a hackathon rule that we then justified backwards. The
matching step is genuinely an OLAP query.

"Find the people nearest to this person, filtered on availability and geography" is a
scan across the entire population. It touches every row, returns forty, and has to stay
fast as a city grows. That is a columnar workload.

Everything else in the product is the opposite: read one row, be correct right now, use a
foreign key. That is Postgres.

| | Postgres (Supabase) | ClickHouse Cloud |
|---|---|---|
| Holds | users, profiles, groups, memberships, RSVPs, chat, reflections, number shares | profile vectors, archetypes, population centroid, event stream |
| Access pattern | single row, transactional | full scan, aggregate |
| Written by | the app directly, and edge functions | edge functions only |
| Read by | the app directly (RLS-protected) | edge functions only |

`profile_vectors` is a **derived** table. Postgres remains the source of truth for who a
user is; ClickHouse holds a denormalised copy shaped for the scan.

### 2.2 Why the client can never touch ClickHouse

ClickHouse's HTTP interface accepts arbitrary SQL and has no row-level security. A
credential shipped inside the Flutter binary is extractable, and whoever extracts it can
read every profile in the database or drop the table.

Supabase is the opposite by design: the anon key is public, and RLS enforces access per
row. So the architecture is asymmetric on purpose — the app talks to Postgres directly,
and everything involving ClickHouse or an LLM goes through one small server function that
holds the secrets.

This is the single most important structural constraint in the system. Every other
decision follows from it.

### 2.3 Repository layout

| Path | Contents |
|---|---|
| `app/` | Flutter client, feature-first (`lib/features/{onboarding,group,chat,after}`) |
| `supabase/migrations/` | Postgres schema and every RLS policy |
| `supabase/functions/` | The only server code. `_shared/` is skipped by deploy — the underscore is load-bearing |
| `clickhouse/` | DDL, the million-row seed, and the demo queries |
| `scripts/` | Archetype embedding, demo reset |
| `docs/` | This document |

---

## 3. The matching pipeline

### 3.1 From free text to a group

```
   passion text + tags
          │
          ├──► Voyage voyage-4 ──► 256-dim vector ──► subtract population mean
          │                                                    │
          └──► Claude opus-5 ──► structured tags               │
                                       │                       │
                                       ▼                       ▼
                              ClickHouse profile_vectors (vector + tags)
                                       │
                                       ▼
                        cosineDistance scan, filtered on tags/availability/city
                                       │
                                       ▼
                        greedy group formation (seed + 5, spread on energy)
                                       │
                                       ▼
                        Claude opus-5 ──► venue, activity, per-person questions
                                       │
                                       ▼
                              Postgres groups + group_members
```

### 3.2 The division of labour between the two models

Anthropic has **no embeddings endpoint** — Claude does not produce vectors. So the pipeline
is split, and the split turns out to be the right design anyway:

- **Voyage (`voyage-4`, 256 dims)** produces the vector. This is the **recall** step: it
  finds the topic neighbourhood, casting a wide net over everyone in the general area.
- **Claude (`claude-opus-5`)** produces the structured tags. This is the **precision**
  step: it narrows the neighbourhood to people who would actually enjoy each other.

Neither works alone. Section 4.2 explains why.

---

## 4. Technical challenges

These are ranked by how much damage they do if we get them wrong.

### 4.1 Anisotropy — everything looks identical

**The problem.** Embedding models do not spread their output evenly through the vector
space. Vectors bunch into a narrow cone. The practical consequence is that any two
profiles score around 0.85 cosine similarity, unrelated ones score 0.84, and the
nearest-neighbour ranking degenerates into noise.

This is a documented and well-studied property. In extreme cases — mean-pooled BERT, GPT-2's
last layer — two *random* inputs come out nearly identical.

**Why it hits us especially hard.** Our profiles are the worst case for this: one or two
sentences, all answering the same prompt, in the same register. Short, topically clustered,
formulaic. The natural spread is tiny before anisotropy even gets involved.

**The failure mode is silent.** Nothing errors. The matcher returns forty rows in a
confident order. The groups look plausible in the UI. They are noise, and you only find
out when someone reads the profiles in a group and they have nothing to do with each other.

**Our fix: mean-centering.** Compute the population centroid and subtract it from every
vector. Now we measure how someone differs from *the typical user of this app*, rather than
from the average of all English text.

Implementation decisions:
- Centering happens **at write time**, not query time, so the hot query stays a plain
  `cosineDistance` with nothing to forget.
- The centroid lives in a ClickHouse table (`embedding_mean`), not in code, so the seed
  script and the edge function cannot disagree about it.
- For the synthetic population the centroid is computed from the **archetypes** rather than
  from `profile_vectors`. The synthetic profiles are archetype + zero-mean noise, so the two
  centroids agree, and this makes the seed a single pass instead of insert-then-rewrite.

**How we detect regression.** `clickhouse/002_seed.sql` ends with a sanity check reporting
the nearest and farthest distance across a 50k sample. If those two numbers are within
~0.03 of each other, centering is not working and every match downstream is meaningless.
This check exists precisely because the failure is otherwise invisible.

### 4.2 Embeddings cannot tell a stance from its opposite

**The problem.** Consider:

> "I love hunting, I go every fall with my dad."
> "I'm vegan and I think hunting is barbaric."

These embed almost identically. Embeddings capture *what you are talking about*, not *what
you think about it*. Antonym pairs routinely score higher than genuinely similar sentences,
because opposites appear in the same contexts — that is exactly what makes them opposites.

**Why this matters more here than in search.** In a retrieval system this is an annoyance.
In a system that puts six strangers at a table for an evening, it is the difference between
a good night and a hostile one. A pure-embedding matcher will confidently seat a passionate
vegan next to a passionate hunter, having concluded they are an excellent match, because
they both wrote passionately about meat.

**Our fix: structured stance extraction.** `extractTags` in `supabase/functions/_shared/claude.ts`
returns a `stance_flags` array — positions held strongly enough that pairing this person
with someone holding the opposite view would ruin the evening. Those are written into
`profile_vectors.tags` with a `stance:` prefix and filtered on in the match query.

This is why the table carries tags *and* a vector. Dropping the tag filter does not produce
an error; it produces confidently wrong groups, which is worse.

### 4.3 Six identical people is a bad group

**The problem.** If we take the five literal nearest neighbours, we get six people who are
effectively the same person. That is a dull evening, and it is also information-free: nobody
learns anything, and nobody has a reason to exchange numbers.

There is a real tension here. Too similar and there is nothing to talk about. Too different
and there is nothing in common to start from.

**Our fix.** Over-fetch and then spread. `run-matching` pulls the nearest 40 rather than the
nearest 5, then makes two passes: the first prefers candidates with an *unseen* energy level,
the second fills whatever is left. Same topic neighbourhood, varied temperament.

**What we are not doing.** Optimal group partitioning is NP-hard. We are greedy, we do not
backtrack, and we accept that the last group of a sweep is worse than the first. Nobody is
going to check, and a correct-but-unfinished matcher is worth nothing at 5pm.

### 4.4 Symmetric vs asymmetric embedding

**The problem.** Voyage's `input_type` has three settings: `"query"`, `"document"`, and
`null`. The first two exist for asymmetric search — a short query hunting through long
documents — and they apply different internal prompts.

We are not doing search. We compare people to people, which is symmetric.

**Our fix.** `input_type: null`, uniformly, everywhere. Using `"query"` for one side and
`"document"` for the other would quietly degrade every match with no error to show for it.
This is recorded in `_shared/voyage.ts` because it is exactly the kind of thing someone
"fixes" later by copying a RAG tutorial.

### 4.5 The dimension is a one-way door

**The problem.** 1M rows × 1024 dims × 4 bytes = 4 GB scanned per query. On a trial-tier
service that is not a demo-able number. And the dimension is written into the ClickHouse
schema, so changing it means re-seeding everything.

**Our fix.** 256 dimensions. voyage-4 embeddings are Matryoshka — the first *k* entries of
the full vector form a valid *k*-dimensional embedding on their own, with slight and, at our
scale, irrelevant quality loss. 256 dims puts a million profiles at ~1 GB and the scan in
the tens of milliseconds.

Decided early and written down in three places (`voyage.ts`, `001_schema.sql`,
`seed_archetypes.py`) because discovering the mismatch at 3pm costs a reseed.

### 4.6 Seeding a million profiles without a million API calls

**The problem.** The ClickHouse story needs a population large enough that scanning it is
impressive. Embedding a million bios is neither affordable nor fast.

**The naive fix is worse than the problem.** Generating a million uniformly random vectors
takes seconds — and produces a dataset where nearest-neighbour is meaningless, because
random points on a high-dimensional sphere are all roughly equidistant. The matches would be
arbitrary, and the first judge who asks "why were these two grouped?" ends the demo.

**Our fix.** Embed ~200 genuinely-written archetype bios through Voyage (200 API calls,
seconds, cents). Then generate a million synthetic profiles inside ClickHouse as
*archetype + jitter*, clustered around those real points. The result is a million rows whose
neighbours are actually semantically related, and the explanation survives scrutiny.

**The sharp edge.** A bare `rand()` inside an `arrayMap` lambda gets constant-folded — every
element of the vector, and potentially every row, gets the same value. The seed therefore
seeds `rand()` with `(row_number * 256 + i)` so it varies per element *and* per row. This is
deterministic, which is a feature: the same seed produces the same demo data.

### 4.7 Brute force is the right answer

**The decision.** No vector index. A full `cosineDistance` scan over the whole table.

**Why.** At our row count it returns in tens of milliseconds. It removes an index to
misconfigure under time pressure. And "no index, one million rows, full scan, 47ms" is a
better sentence to say to a ClickHouse engineer than a hand-tuned HNSW that they will
immediately ask harder questions about.

The demo query uses `FORMAT JSON`, whose response carries a `statistics` block with
`elapsed` and `rows_read`. Those numbers go on screen under the group reveal — the database
reporting on itself rather than us claiming a number.

### 4.8 Joining live Postgres rows into the scan

ClickHouse's `postgresql()` table function reads a remote Postgres table at query time,
which lets a single statement join live RSVP state against the vector scan. That is the
"OLAP and OLTP, like PB&J" framing executing literally.

**The caveat, which we will state out loud when demoing it:** `postgresql()` pulls the
*entire* remote table on every call. That is correct for `rsvps` (hundreds of rows this
week) and wrong for anything large. In production this is ClickPipes CDC. Knowing the
limitation reads better than not knowing it.

### 4.9 Deduplicating profile updates

`profile_vectors` uses `ReplacingMergeTree(updated_at)` ordered by `user_id`, so editing a
profile overwrites rather than accumulating rows.

**The sharp edge:** ReplacingMergeTree deduplicates during background merges, not on read.
Between a re-embed and the next merge, a user can legitimately have two rows and appear
twice in a candidate list. Options are `FINAL` (correct, slower) or deduplicating in the
edge function (cheap at forty rows).

**[hackathon shortcut]** We are not handling this today. Profiles are written once during
the demo, so the window never opens. It is written down here so it is a known gap rather
than a surprise.

The ordering key is `user_id` alone, deliberately. Adding `city` would help nothing — the
match query is a full scan by design — and would break deduplication the moment someone moves.

### 4.10 The phone-number reciprocity gate

**The problem.** "If you share, you see everyone else who shared" is the most sensitive
operation in the product. If the client decides who sees what, the numbers have already
been sent to the device and the gate is decorative.

**Our fix.** It is an RLS policy, enforced by Postgres:

```sql
create policy "reciprocal disclosure only" on number_shares for select
  using (exists (
    select 1 from number_shares mine
    where mine.group_id = number_shares.group_id and mine.user_id = auth.uid()
  ));
```

Share yours and the rows become visible. Don't and the query returns nothing. There is no
code path, in the app or in an edge function, that can return a phone number to someone who
has not shared one.

The same pattern gates `reflections`: you see what your pair wrote about you only once you
have written yours.

### 4.11 Realtime chat

Supabase realtime requires the table to be added to the `supabase_realtime` publication.
Without it, `supabase.from('messages').stream()` returns the initial rows and then silently
never updates again — no error, just a chat that does not chat. The `alter publication`
statement is the last line of `0001_init.sql` for that reason.

### 4.12 Push notifications, and the machine we are building on

**The constraint.** The build machine has Xcode but no Android SDK. Installing Android
Studio and the SDK over venue wifi is a 30–60 minute gamble we are not taking. So the demo
runs on a physical iPhone.

**The consequence.** Real server-driven push on iOS requires an APNs key, which requires a
paid Apple Developer account. Real FCM/APNs is therefore out today.

**Our fix.** The entire push ladder (T-3d, T-1d, morning-of, 10-min-away) runs through
`flutter_local_notifications`, scheduled on-device. It needs no paid account, no FCM
project, and no network at demo time — which is an advantage in a room with 400 people on
the same wifi. From the audience it is indistinguishable from server push.

**[hackathon shortcut]** The "10 minutes away" trigger is genuinely geofenced in the product
concept. Background geofencing on iOS is painful and battery-hostile. We ship it as a timed
notification relative to event start.

### 4.13 Cold start

**The problem.** The product does not work with fifteen users. Groups of six matched on
interest need a pool deep enough that the sixth-nearest person is still actually similar.
Below that threshold the matcher returns whoever is available, which is a worse experience
than not matching at all.

**[hackathon shortcut]** Not solved. Worth naming honestly if a judge asks: the real answer
is launching one neighbourhood at a time and holding people in a waitlist until the pool
clears a threshold, not launching a city.

`run-matching` returns `unmatched` alongside `groups` so the shortfall is at least visible
rather than silent.

### 4.14 Safety, and what we are not pretending to have solved

This product puts strangers in a room together and then helps them exchange phone numbers.
That deserves more than a shrug.

What exists in the design:
- ID verification at signup **[hackathon shortcut — stubbed]**.
- Phone numbers are opt-in, reciprocal, and never visible to someone who has not shared.
- Group chat is scoped to the group and disappears with it.
- No face photos, which removes the appearance-based selection dynamic entirely.

What does not exist and would be required before real users:
- Reporting and blocking. There is no way to report a person or leave a group.
- Venue vetting. The AI picks a venue; nothing verifies it is a public, safe, accessible place.
- Any handling of a person in crisis. A loneliness product will attract people who are
  genuinely unwell, and there is no escalation path.
- Age and alcohol verification beyond a self-reported flag.

We would rather list these than imply they are handled.

---

## 5. Cost

| Component | Today | Note |
|---|---|---|
| Voyage embeddings | $0 | 200M free tokens per account; we use a rounding error of that |
| Claude | cents | One structured extraction per signup, one plan per group |
| ClickHouse Cloud | $0 | Trial tier |
| Supabase | $0 | Free tier |

The seeding strategy is what keeps this at zero: 200 real embedding calls instead of a
million.

---

## 6. Demo plan and the risks in it

**The order that matters.** Matching first, UI last. The matching is what makes the idea
work or not, and it is the only part that cannot be faked on stage.

1. Schema, seed, and the matching query — verified against real data
2. `submit-profile` and `run-matching` edge functions
3. Flutter: signup → matched group → chat → map
4. Local notifications, then the after-event flow
5. The analytics dashboard

**Known risks:**

| Risk | Mitigation |
|---|---|
| Screen mirroring fails at 5:05 | Test the iPhone-to-projector path before 4:45, not at 5:04 |
| Demo account already in a group from testing | `scripts/demo_reset.sh` — rehearse the full run three times |
| Venue wifi collapses under 400 people | Local notifications need no network; seed data is already in ClickHouse |
| Matches look random | The centering sanity check in `002_seed.sql` catches this before the UI exists |
| Signing not set up for the physical iPhone | Set the Xcode team early; free personal team is sufficient |

**The closing slide** is the `windowFunnel` query: notified → RSVP'd → attended → exchanged
numbers, sliced by how tightly the group was matched. That is the argument that this is not
just an app but a measurable claim about what actually produces friendship — and it is a
question that cannot be answered without the OLAP half.
