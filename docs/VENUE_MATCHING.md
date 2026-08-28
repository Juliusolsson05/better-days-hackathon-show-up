# Venue matching — mapping groups to Yelp venues

How a formed group gets 2–3 venue options to vote on, and where those options come from.

---

## 1. The insight: venues are just another vector table

We already have machinery that takes a 256-dimensional embedding and finds its nearest
neighbours across a large table in ClickHouse. A venue is a piece of text — name,
categories, review excerpts — so it can live in exactly the same shape.

**Matching a group to a venue is the same query as matching a person to a group.** Nothing
new is needed: same embedding model, same dimension, same centroid, same `cosineDistance`,
same database.

```
   6 member embeddings ──► mean ──► group centroid
                                        │
                                        ▼
                    cosineDistance against venue_vectors
                    filtered on: open at event time, distance,
                                 price, alcohol, accessibility
                                        │
                                        ▼
                        top ~30 candidates ──► diversify ──► 3 options
                                                                │
                                                                ▼
                                              Claude writes one line per option
                                                                │
                                                                ▼
                                                  posted into the group chat as a vote
```

## 2. Why this replaces asking Claude to pick a venue

The current `planGroup` in `supabase/functions/_shared/claude.ts` asks Claude to "pick a
real venue in the named city". That has a failure mode that will eventually embarrass us:
**the model can invent a venue that does not exist**, or name one that closed. Sending six
people to a nonexistent bar is the worst possible bug in this product.

Grounding venue selection in real Yelp rows removes that entirely. Claude's job narrows
from *recall a venue* to *write one line about this specific real venue for this specific
group*, which is what it is actually good at, and which cannot hallucinate an address.

This also fits the PRD change: we need **2–3 options for the group to vote on**, not one
pick. Retrieval naturally returns a ranked list; a single LLM call naturally returns one
answer.

---

## 3. Getting the data

### 3.1 Yelp Fusion API — the legitimate path

Yelp Fusion exposes what we need:

| Endpoint | Use |
|---|---|
| `/v3/businesses/search` | Venues by location + category + price + open-at |
| `/v3/events` | Actual events (search by location, category, date range) |
| `/v3/events/featured` | Community-manager-picked event for a location |
| `/v3/categories` | The full category taxonomy, with aliases |

An API key is generated automatically when you create an app, so access is minutes not days.
There is a free trial; paid tiers start around **$7.99 per 1000 calls with a 300 call/day
quota**, which is the constraint that shapes the whole design below.

### 3.2 Scraping is the wrong call

It violates Yelp's terms, it is behind bot protection, and a judge asking "where does your
venue data come from?" is a question you want a clean answer to. It is also slower to build
than the API.

### 3.3 The design that makes the quota irrelevant: pull once, cache forever

**Do not call Yelp at request time.** A 300/day quota and a live external dependency during
a demo on venue wifi is a bad combination.

Instead, run a one-time ingest that pulls a few hundred SF venues across the categories our
archetypes actually map to, writes them to `clickhouse/venues.jsonl`, commits it, and loads
it into ClickHouse. After that the app never talks to Yelp at all.

This gives three things:
- The demo has no external dependency and cannot be rate-limited on stage.
- The dataset is reproducible — everyone on the team has the same venues.
- The category taxonomy is downloadable as a static JSON file, so mapping costs zero calls.

```
scripts/ingest_yelp.py  ──►  clickhouse/venues.jsonl  ──►  venue_vectors (ClickHouse)
      (run once, ~300 calls)         (committed)                 (embedded)
```

### 3.4 Fallbacks if Yelp access stalls

| Source | Free tier | Trade-off |
|---|---|---|
| **Google Places** | Recurring monthly credit | Good coverage, weaker category taxonomy for interests |
| **Foursquare Places** | Generous free tier | Excellent taxonomy, thinner review text to embed |
| **OpenStreetMap / Overpass** | Free, no key | No quality signal, no reviews, no hours reliability |
| **Eventbrite** | Free API | Real *events* rather than venues — complements Yelp rather than replacing it |

If Yelp blocks for any reason, Foursquare is the closest substitute for this design because
the embedding input is mostly the category path plus name.

---

## 4. Schema

```sql
CREATE TABLE IF NOT EXISTS venue_vectors
(
    venue_id     String,                  -- yelp business or event id
    source       LowCardinality(String),  -- 'yelp_business' | 'yelp_event'
    name         String,
    embedding    Array(Float32),          -- 256 dims, mean-centered with the SAME centroid
    categories   Array(String),           -- yelp category aliases
    city         LowCardinality(String),
    lat          Float64,
    lng          Float64,
    price        UInt8,                   -- 1-4, 0 = unknown
    rating       Float32,
    review_count UInt32,
    serves_alcohol Bool,
    open_slots   Array(String),           -- 'fri_eve','sat_day',... precomputed from hours
    wheelchair   Bool,
    updated_at   DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY venue_id;
```

**The centroid must be the same one used for profiles.** Both vectors have to live in the
same centered space or the distances between them are meaningless. `embedding_mean` is
already a table for exactly this reason — read it, don't recompute it per-table.

---

## 5. What text to embed

This is the part that determines whether the matching is any good. A venue's name alone is
nearly signal-free ("Kinship" tells you nothing).

Build a document per venue:

```
Kinship
Categories: cocktail bars, tapas, wine bars
Neighborhood: Mission District
What people say: "quiet enough to actually talk", "small plates", "no TVs",
                 "good for a group", "cozy back room"
```

The review excerpts are the highest-signal part, because they describe **what it is like to
be there**, which is the actual matching dimension. "Quiet enough to actually talk" is the
difference between a good venue for a talk-oriented group and a bad one. Categories alone
cannot express that.

Yelp returns up to 3 review excerpts per business. Use them.

---

## 6. The query

```sql
-- Group centroid is computed in the edge function as the element-wise mean of the
-- members' embeddings, then passed in as a parameter.
SELECT
    venue_id, name, categories, price, rating, lat, lng,
    cosineDistance(embedding, {centroid:Array(Float32)}) AS d
FROM venue_vectors
WHERE city = {city:String}
  AND hasAny(open_slots, {slot:Array(String)})
  AND (serves_alcohol = {alcohol_ok:Bool} OR serves_alcohol = false)
  AND greatCircleDistance(lng, lat, {lng:Float64}, {lat:Float64}) < {radius_m:Float64}
  AND rating >= 3.5
  AND review_count >= 20
ORDER BY d ASC
LIMIT 30
FORMAT JSON;
```

`greatCircleDistance` is built into ClickHouse — no PostGIS, no extension, no extra table.
The group's location anchor is the centroid of its members' locations.

**Hard filters vs the vector.** The same discipline as person matching applies: the
embedding decides *taste*, the WHERE clause decides *feasibility*. A wonderful venue that
is closed on Friday is not a candidate, and no amount of cosine similarity should be able
to override that.

---

## 7. Diversifying the three options

Returning the top 3 by distance gives three cocktail bars. That is a bad vote — the group
is choosing between things that are the same, and the vote stops meaning anything.

Take the top 30 and pick 3 under a constraint:

1. **First option** — the closest match. The group's centre of gravity.
2. **Second option** — the closest candidate whose top-level category differs from the
   first's.
3. **Third option** — the closest candidate differing from both, biased toward a different
   *mode* (if the first two are drinks, prefer an activity: bouldering gym, arcade, walking
   tour).

This makes the vote a real decision — *do we want to sit and talk, or do a thing?* — which
is exactly the axis groups actually disagree on and the reason voting exists in the PRD at
all.

---

## 8. Claude's role, narrowed

One call per group, after retrieval, with the three real venues as input:

- Write one line per option, aimed at *this* group's shared interests
  ("no TVs and a back room — you'll actually be able to hear each other").
- Suggest the activity framing for the option that needs one.
- **Not** to choose. The group votes.

Structured output with a schema of exactly three options keeps it from returning two or
four, and the venue ids are echoed back so a hallucinated name cannot survive — validate
that every returned `venue_id` was one we sent in, and drop any that wasn't.

---

## 9. Events vs venues

Yelp `/v3/events` returns real scheduled events with a start time. These are strictly better
than a bar when one matches the group's interests — a climbing gym's intro night beats a
generic cocktail bar for a group of climbers, and the shared activity does the small-talk
work the product is otherwise trying to solve with assigned questions.

Treat them as the same table with `source = 'yelp_event'`, but rank events **above**
businesses when the distance is close, because a scheduled event provides structure that a
venue does not.

The constraint is supply: there may be no relevant event on the group's date. So the
candidate set is *events first, businesses to fill*, and the voting message can mix the two.

---

## 10. Build order

Roughly 2 hours of work, and none of it is on the critical path for the core demo — do it
after matching works end to end.

1. `scripts/ingest_yelp.py` — pull ~300 SF venues across our archetype categories to
   `venues.jsonl`. **Run once, commit the output.**
2. Extend `seed_archetypes.py` to also embed venues (same model, same dims, same centroid)
   and load `venue_vectors`.
3. `clickhouse/queries/venue_match.sql` — the query above.
4. `pick-venues` edge function, or fold it into `run-matching`: centroid → retrieve →
   diversify → Claude one-liners → write a vote message into the group chat.
5. Vote UI in the chat, anonymous tally.

**[hackathon shortcut]** If time runs short, skip Yelp entirely and hand-curate 20 SF venues
into `venues.jsonl` by hand. The retrieval, the diversification, the vote, and the demo are
all identical — the only thing lost is breadth, and nobody in the room can tell. Do not let
an external API be the reason the venue flow doesn't ship.

---

Sources:
- [Yelp Places API — getting started](https://docs.developer.yelp.com/docs/places-intro)
- [Yelp Fusion — categories resource](https://docs.developer.yelp.com/docs/resources-categories)
- [Yelp Fusion — all categories endpoint](https://docs.developer.yelp.com/reference/v3_all_categories)
- [Yelp Fusion changelog](https://docs.developer.yelp.com/changelog)
- [Yelp Fusion API pricing coverage](https://appdevelopermagazine.com/yelp-fusion-api-outrageous-new-pricing/)
