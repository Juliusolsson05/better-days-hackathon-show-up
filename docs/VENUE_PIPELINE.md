# Venue pipeline — implementation plan

How a formed group gets 2–3 real venue options to vote on.

**This supersedes `VENUE_MATCHING.md`.** That document proposed pulling ~300 venues from
Yelp once, committing `venues.jsonl`, and embedding it. That plan is not legally available
to us, and the retrieval algorithm it sketched has a failure mode that would have made every
group get the same recommendation. Both are corrected here. §1 is the blocker, §2 is the
corrected architecture, §3 is the matching algorithm, §4 is how it is isolated in the tree.

---

## 1. The blocker: Yelp content cannot be stored or embedded

Yelp's API Terms of Use, in the operative clauses:

> …cache, record, pre-fetch, or otherwise store any portion of the Yelp Content for a period
> longer than **twenty-four (24) hours** from receipt.

> …use it to update or **create your own database of business listing information**.

> …create derivative works based on the Yelp Content for the purpose of **training,
> developing, enhancing, or fine-tuning any Generative AI Models**.

Three separate clauses, and our previous plan violated all three:

| What we planned | Which clause it breaks |
|---|---|
| Commit `venues.jsonl` to the repo | 24-hour cache limit |
| Load it into `venue_vectors` and keep it | "your own database of business listing information" |
| Embed the review text into vectors | derivative works / GenAI clause |

An embedding **is** a derivative work of the text it was computed from, and a vector table
persisted in ClickHouse **is** a database of business listings. There is no reading of these
terms where a committed, embedded Yelp corpus is permitted.

There is a second, independent reason the old plan does not work: **the quota is too small
to build a corpus anyway.** The trial is 300 calls/day (5,000 over 30 days), review excerpts
are a separate call per business, capped at 3 reviews of 160 characters each, and the reviews
endpoint requires the Enhanced or Premium plan. Pulling 300 venues *with* review text is 600
calls — twice the daily quota — to obtain at most 480 characters of text per venue.

So: even setting the licence aside, Yelp cannot be the corpus. It is too expensive per row,
too thin per row, and legally unstorable.

**This is worth internalising rather than working around.** The instinct will be to cache it
anyway "just for the demo." Don't. Judges include engineers from companies with real legal
functions, the terms are public, and "we ignored the licence" is a worse answer than any
technical shortcoming. The corrected design below is also genuinely better, so there is
nothing to trade off.

---

## 2. Corrected architecture: an owned corpus plus an ephemeral enrichment layer

Two sources with completely different legal and technical characters, kept strictly apart.

```
   OWNED (Apache 2.0 / CDLA)                 EPHEMERAL (Yelp, ≤24h)
   ─────────────────────────                 ──────────────────────
   Overture Maps places                      /v3/businesses/{id}
        │  bbox = Bay Area                        │  live, at display time
        ▼                                         ▼
   venue_vectors (ClickHouse)               in-memory / TTL cache only
   name, category, geo, embedding           hours, rating, price, noise,
        │                                   ambience, wheelchair access
        │  cosineDistance scan                    │
        ▼                                         │
   candidate venues ────────────────────────► enriched for display ──► group chat vote
```

### 2.1 The owned corpus: Overture Maps places

[Overture Maps](https://docs.overturemaps.org/guides/places/) is the right spine:

- **Licence**: CDLA Permissive 2.0, with the Foursquare-sourced subset under Apache 2.0.
  Both permit storage, derivative works, and commercial use. We can embed it and keep it.
- **Access**: public S3 in the AWS Registry of Open Data — no account, no key, no auth.
  `s3://overturemaps-us-west-2/release/2026-08-19.0/theme=places/type=place/*`
- **Scale**: >100M global POIs; a Bay Area bbox is a small slice.
- **Fields we care about**: `id` (GERS, stable across releases), `names`, `basic_category`
  (~280 cognitively-basic labels), `taxonomy.hierarchy`, `confidence` (0–1 existence score),
  `addresses`, `websites`, `socials`, `phones`, `geometry`.
- **ClickHouse has a documented ingestion path** for this data, which is a nice thing to be
  able to say at a ClickHouse hackathon.

Note `confidence`: Overture scores how likely a place still exists. Filtering `confidence >
0.7` removes most closed and phantom POIs, which is the single cheapest quality win available.

Note also the schema transition: `categories` is **deprecated and removed in the September
2026 release** — use `basic_category` and `taxonomy`. Pin the release string
(`2026-08-19.0`) in code so a mid-project schema change cannot surprise us.

### 2.2 The ephemeral layer: Yelp, live and unstored

Yelp is genuinely better than Overture at exactly one thing, and it is the thing that decides
whether an evening works: **what it is like to be in the room.** The `/v3/businesses/search`
`attributes` parameter exposes, among others:

- `noise_level`: `quiet` | `average` | `loud` | `very_loud`
- `ambience`: `casual`, `classy`, `divey`, `hipster`, `intimate`, `romantic`, `touristy`,
  `trendy`, `upscale`
- `liked_by`: `twenties`, `thirties`, `students`, `young_professionals`, `vegetarians`,
  `vegans`, `dates`, `travelers`, …
- accessibility: `wheelchair_accessible`, `gender_neutral_restrooms`, `open_to_all`
- practical: `open_at` (unix ts), `price` (1–4), `outdoor_seating`, `happy_hour`

`noise_level=quiet` is precisely the "quiet enough to actually hear each other" signal we
hand-wrote into the mock. `wheelchair_accessible` and `open_to_all` are the accessibility
gaps flagged in `DESIGN.md` §4.14.

**But it is fetched at display time, held in memory, and never written to ClickHouse or
Postgres.** Several of these attributes are Premium-plan gated (`outdoor_seating`,
`happy_hour`, `dogs_allowed` and others), so treat every one of them as optional and design
for their absence.

### 2.3 What each source may and may not do

This table is the contract. §4 enforces it in the type system.

| | Overture (owned) | Yelp (ephemeral) |
|---|---|---|
| Persist to ClickHouse / Postgres | ✅ | ❌ **never** |
| Embed into a vector | ✅ | ❌ **never** |
| Commit to the repo | ✅ | ❌ **never** |
| Hold in memory for a request | ✅ | ✅ |
| Cache with TTL | ✅ | ✅ **< 24h only** |
| Show to a user | ✅ | ✅ *with attribution + link* |
| Feed to an LLM prompt | ✅ | ⚠️ display-copy only, never training |

Yelp's Display Requirements also mandate attribution and that the link back to the Yelp
listing is not removed. A "via Yelp" line under the venue card discharges this and costs
nothing.

### 2.4 If Yelp access does not happen today

The enrichment layer is optional by construction. With no Yelp key the pipeline still
returns three real, correctly-located, correctly-categorised venues from Overture — it just
cannot say how loud they are. Ship the Overture path first and treat Yelp as an upgrade that
lands or does not.

---

## 3. The matching algorithm

### 3.1 The trap: do not retrieve by group centroid

The obvious approach — average the six members' embeddings, find the nearest venue — is the
"Average" strategy from the group-recommender-systems literature, and it fails here in two
compounding ways.

**Failure one: averaging is the wrong aggregator for diverse groups.** The literature is
explicit that the average strategy performs well only when preferences are similar, and
degrades when they are diverse. Our groups are *deliberately* diverse — `run-matching`
spreads members across energy levels on purpose. We engineered the exact condition under
which averaging is documented to fail.

**Failure two: high-dimensional centroids are hubs.** Vectors near the centroid of a
distribution tend to be the nearest neighbour of a very large fraction of all other vectors —
"centrality-driven hubness". A group centroid is close to the global centroid, so the venue
nearest to it is the venue nearest to *everything*: the most generic bar in the city.

Together these produce a specific, recognisable demo failure: **every group gets the same
three venues, and they are all boring.** It will look like a caching bug. It is not.

### 3.2 The fix: aggregate over scores, not over vectors

Score each candidate venue against each member individually, then aggregate the **scores**.
This keeps every member's actual position in the space instead of collapsing six people into
a point that represents none of them.

```
for each candidate venue v:
    s_i = 1 - cosineDistance(member_i.embedding, v.embedding)   for i in 1..n

    avg          = mean(s)                      # group fit
    least_misery = min(s)                       # nobody is dragged along
    score(v)     = 0.5 * avg + 0.5 * least_misery
```

This is **average-without-misery**, the consensus strategy from the group recsys literature,
and it is the right one for this product specifically. Show Up's promise is that you can turn
up alone and not have a bad night. A venue that delights four people and bores two is a worse
outcome, by our own product thesis, than one that suits all six reasonably well. The
`least_misery` term encodes that promise numerically.

Implementable in one ClickHouse query — pass the member vectors as an `Array(Array(Float32))`
and use `arrayMap` + `arrayReduce`:

```sql
SELECT
    venue_id, name,
    arrayMap(m -> 1 - cosineDistance(embedding, m), {members:Array(Array(Float32))}) AS s,
    0.5 * arrayAvg(s) + 0.5 * arrayMin(s) AS score
FROM venue_vectors
WHERE city = {city:String}
  AND greatCircleDistance(lng, lat, {clng:Float64}, {clat:Float64}) < {radius_m:Float64}
  AND confidence > 0.7
ORDER BY score DESC
LIMIT 50
FORMAT JSON
```

One scan, no centroid, every member represented. `greatCircleDistance` is built into
ClickHouse — no PostGIS, no extension.

### 3.3 The geo anchor is a min-max problem, not a centroid

The same reasoning applies to location, where it is even more obvious. The geographic
centroid of six people's homes can easily be a spot none of them can reach. Anchor instead on
**minimising the worst individual travel distance** — pick the point (or filter the radius)
that keeps the furthest member's journey acceptable. Least misery again, in metres.

For the hackathon: anchor on the members' centroid but hard-filter on
`max_i(distance(member_i, venue)) < 8km`, which is the cheap version of the same idea.

### 3.4 Full retrieval pipeline

```
  1. GEO PREFILTER      bbox / greatCircleDistance          ~50k → ~2k
  2. HARD FILTERS       confidence, category allowlist,     ~2k  → ~500
                        open at event time (Yelp, if avail)
  3. VECTOR SCORE       avg-without-misery, per member      ~500 → 50
  4. FUSION             RRF over {vector, popularity,       50 ranked
                        category-match} rankings
  5. RERANK             Voyage rerank-2.5 on a synthesised  50 → 10
                        group description
  6. DIVERSIFY          MMR-style: different basic_category  10 → 3
                        and different *mode* (sit vs do)
  7. PITCH              one Claude call: one line per venue  3 + copy
                        written for this group
  8. ENRICH             Yelp live: hours, noise, access      display only
```

**On step 4 (fusion).** Reciprocal Rank Fusion combines rankings that have incomparable score
scales — cosine similarity, review counts, category-match booleans — by operating on *ranks*
rather than scores:

```
RRF(v) = Σ_r  1 / (k + rank_r(v))          k = 60
```

`k = 60` is the standard value; the optimum is famously flat across roughly [20, 100], so it
is not a knob worth tuning today. RRF is the default hybrid ranking method in OpenSearch,
Elasticsearch, Azure AI Search and Weaviate, so it is also a defensible thing to name on
stage.

**On step 5 (rerank).** A bi-encoder embedding comparison is fast but coarse. A cross-encoder
reranker reads the query and the candidate together and is substantially more accurate.
`rerank-2.5` shares the same 200M free-token allowance as the embedding models, so at our
volume it costs nothing. The "query" is a short synthesised group description — *"six people
into climbing, records and baking; Friday evening; prefer to talk over doing"* — which is a
much richer signal than any single vector.

**On step 6 (diversify).** Returning the top 3 by score gives three cocktail bars, and the
vote becomes meaningless because the options are the same. Enforce that the three differ on
`basic_category`, and bias the third toward a different *mode*: if the first two are
sit-and-talk, make the third do-a-thing. That turns the vote into the real question — *do we
want to sit and talk, or do something?* — which is the axis groups actually disagree on and
the reason the PRD has a vote at all.

### 3.5 What text to embed

Venue name alone is nearly signal-free — "Kinship" tells you nothing. Build a document:

```
Kinship
Category: cocktail bar
Also: tapas, wine bar
Neighborhood: Mission District, San Francisco
```

Thin, but honest and legally clean. Category taxonomy plus name plus neighbourhood is enough
for topical matching; it is not enough for vibe matching, which is what the Yelp attribute
layer supplies as *filters* rather than as embedded text.

**Same model, same dimension, same centroid as profiles.** 256-dim `voyage-4`,
`input_type: null`, and the population mean from `embedding_mean` subtracted. Venues and
people must live in the same centered space or the distances between them are meaningless.
This is the single most likely thing to get silently wrong.

---

## 4. Code isolation

The user asked how to isolate this properly. The answer is unusually clean here, because
**the licence boundary and the module boundary are the same line.**

### 4.1 The organising principle

Two record types that never mix, enforced by the type system rather than by a comment:

```ts
/** Apache 2.0 / CDLA. May be persisted, embedded, committed. */
type OwnedVenue = {
  readonly _brand: 'owned'
  venueId: string          // Overture GERS id
  name: string
  basicCategory: string
  taxonomy: string[]
  lat: number; lng: number
  confidence: number
  website?: string
}

/** Yelp. In-memory only, <24h, display-only. Has no persistence path by construction. */
type EphemeralEnrichment = {
  readonly _brand: 'ephemeral'
  readonly expiresAt: number      // now + 24h, enforced on read
  yelpUrl: string                 // attribution link, must be rendered
  rating?: number
  price?: 1|2|3|4
  noiseLevel?: 'quiet'|'average'|'loud'|'very_loud'
  ambience?: string[]
  wheelchairAccessible?: boolean
  isOpenAt?: boolean
}
```

Every persistence function accepts `OwnedVenue` and nothing else. There is no overload, no
union, and no `any` on that path. `EphemeralEnrichment` is structurally incapable of reaching
ClickHouse because no writer takes its shape. A compliance rule that lives in a comment gets
violated at 4pm by someone under time pressure; one that fails to compile does not.

### 4.2 Directory layout

```
supabase/functions/
├── _shared/
│   ├── clickhouse.ts              (exists)
│   ├── voyage.ts                  (exists — add rerank())
│   ├── claude.ts                  (exists — planGroup shrinks, see 4.4)
│   └── venues/                    ← the new bounded context
│       ├── types.ts               OwnedVenue, EphemeralEnrichment, VenueCandidate
│       ├── ports.ts               VenueCorpus, VenueEnricher  (interfaces only)
│       ├── retrieve.ts            the 8-step pipeline, source-agnostic
│       ├── aggregate.ts           avg-without-misery, RRF, MMR diversification
│       └── adapters/
│           ├── clickhouse_corpus.ts   VenueCorpus  → venue_vectors
│           ├── yelp_enricher.ts       VenueEnricher → live Yelp, TTL, no writes
│           ├── null_enricher.ts       VenueEnricher → returns {} (no Yelp key)
│           └── fixture_corpus.ts      VenueCorpus  → 20 hand-curated SF venues
└── pick-venues/
    └── index.ts                   thin: auth, load group, call retrieve, write options

clickhouse/
├── 003_venues.sql                 venue_vectors DDL
└── queries/venue_match.sql        the avg-without-misery scan

scripts/
├── ingest_overture.py             S3/DuckDB → bbox → venues.parquet  (run once)
└── embed_venues.py                venues.parquet → Voyage → venue_vectors
```

### 4.3 The ports

Two interfaces, three adapters, and the pipeline depends only on the interfaces:

```ts
export interface VenueCorpus {
  /** Owned data only. Implementations MUST NOT return licence-restricted content. */
  nearest(args: {
    memberEmbeddings: number[][]
    lat: number; lng: number; radiusM: number
    limit: number
  }): Promise<VenueCandidate[]>
}

export interface VenueEnricher {
  /** Display-only. Never persisted. Returns {} when unavailable — never throws. */
  enrich(venues: OwnedVenue[], at: Date): Promise<Map<string, EphemeralEnrichment>>
}
```

Three properties fall out of this that matter today:

1. **`fixture_corpus.ts` unblocks the UI immediately.** Twenty hand-written SF venues, no S3,
   no embedding, no ClickHouse. Whoever is building the vote card can work against it this
   minute while the Overture ingest is still running.
2. **`null_enricher.ts` makes Yelp genuinely optional.** No key, no plan, no problem — the
   flow degrades to "no noise-level shown" rather than breaking.
3. **The pipeline is testable without any network.** `retrieve.ts` takes both ports as
   arguments; a test wires two fakes and asserts on the ranking.

### 4.4 What shrinks elsewhere

`planGroup` in `_shared/claude.ts` currently asks Claude to name a venue from memory. That
must go — a language model can invent a bar that does not exist, and sending six people to a
nonexistent address is the worst bug this product can have. Its job narrows to: given three
**real, retrieved** venues, write one line each aimed at this group.

Validate the returned ids against the ids that were sent in and drop anything that does not
match, exactly as `run-matching` now validates `plan.questions`. Grounding plus id validation
means hallucination is structurally impossible rather than merely unlikely.

---

## 5. Build stages

Each stage ends with something checkable. Do not start a stage before the previous one's
check passes.

| # | Stage | Verify by |
|---|---|---|
| 0 | `fixture_corpus.ts` + `types.ts` + `ports.ts` | Vote card renders 3 venues in the app |
| 1 | `003_venues.sql`; `ingest_overture.py` for the SF bbox | `SELECT count() FROM venues` > 5000 |
| 2 | `embed_venues.py` — same model/dims/centroid as profiles | `length(any(embedding)) = 256`; a known bar's top-10 neighbours are plausible |
| 3 | `aggregate.ts` — avg-without-misery + RRF + MMR | Unit test: two disjoint members do **not** both get their top pick |
| 4 | `retrieve.ts` wired to `clickhouse_corpus` | Two different groups get **different** venue sets ← the anti-hubness check |
| 5 | `pick-venues` edge function writes `venue_options` | Rows appear; chat shows the vote |
| 6 | `yelp_enricher.ts` (optional) | Noise level and hours render, with "via Yelp" attribution |
| 7 | Rerank step | Compare top-3 before/after on one group; keep if better |

Stage 4's check is the important one and the easiest to skip. **Run the matcher for two
deliberately different groups and confirm the venue lists differ.** If they do not, something
has collapsed to a centroid and the whole feature is decorative.

Stages 0–2 are the critical path. Stages 6 and 7 are strictly upside and should be cut
without hesitation if the core flow is not solid.

---

## 6. Failure modes, in the order they will bite

1. **Different embedding space for venues and people.** Different model, dimension, or a
   missing centroid subtraction. Distances become meaningless but nothing errors. *Guard:*
   assert `length(embedding) = 256` on insert, and check one known-good pair by hand.
2. **Every group gets identical venues.** Centroid retrieval and hubness (§3.1). *Guard:*
   stage-4 check above.
3. **Three variations of the same place.** No diversification — the vote becomes theatre.
   *Guard:* assert three distinct `basic_category` values.
4. **A recommended venue is closed or does not exist.** *Guard:* Overture `confidence > 0.7`,
   plus Yelp `open_at` when the enricher is available.
5. **Yelp quota exhausted mid-demo.** 300 calls/day on trial, and the rehearsal loop burns
   them fast. *Guard:* `null_enricher` fallback, and a short in-memory TTL cache so
   re-running the same group does not re-fetch.
6. **Overture schema drift.** `categories` is removed in the September 2026 release.
   *Guard:* pin `2026-08-19.0` in the ingest script; read `basic_category`, not `categories`.
7. **Someone caches Yelp to "make the demo reliable."** The one failure with legal rather
   than technical consequences. *Guard:* §4.1 — no function that writes accepts that type.

---

## 7. Cost

| Component | Cost today | Note |
|---|---|---|
| Overture Maps | **$0** | Public S3, open data registry, no account |
| Voyage embeddings | **$0** | 200M free tokens; a Bay Area slice is a rounding error |
| Voyage rerank-2.5 | **$0** | Same 200M free-token allowance |
| Claude (pitch copy) | cents | One call per group |
| ClickHouse Cloud | $0 | Trial tier |
| Yelp | $0 trial / $7.99 per 1k | Optional layer only |

The whole pipeline runs at zero marginal cost, and the one paid component is the one that is
optional by construction.

---

Sources:
- [Yelp API Terms of Use](https://terms.yelp.com/developers/api_terms/20250113_en_us/)
- [Yelp — business search reference](https://docs.developer.yelp.com/reference/v3_business_search)
- [Yelp — events search reference](https://docs.developer.yelp.com/reference/v3_events_search)
- [Yelp — rate limiting](https://docs.developer.yelp.com/docs/places-rate-limiting)
- [Yelp — plans](https://docs.developer.yelp.com/docs/plans)
- [Overture Maps — places guide](https://docs.overturemaps.org/guides/places/)
- [Overture Maps — attribution and licensing](https://docs.overturemaps.org/attribution/)
- [Foursquare Open Source Places (Apache 2.0)](https://opensource.foursquare.com/os-places/)
- [ClickHouse — Foursquare places dataset](https://clickhouse.com/docs/getting-started/example-datasets/foursquare-places)
- [ClickHouse — exact and approximate vector search](https://clickhouse.com/docs/engines/table-engines/mergetree-family/annindexes)
- [Group recommender systems: aggregation, satisfaction and group attributes](https://link.springer.com/chapter/10.1007/978-1-4899-7637-6_22)
- [Algorithms for group recommendation (TU Graz)](https://ase.sai.tugraz.at/wp-content/uploads/sites/34/2014/01/grouprecommendersystemschapter2.pdf)
- [Reciprocal Rank Fusion explained](https://blog.serghei.pl/posts/reciprocal-rank-fusion-explained/)
- [Voyage AI — rerank-2.5](https://openrouter.ai/voyageai/rerank-2.5)
- [Voyage AI — pricing and free tokens](https://docs.voyageai.com/docs/pricing)
