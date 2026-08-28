# Venue pipeline — implementation plan

How a formed group gets 2–3 real venue options to vote on inside the group chat.

## Current integration tranche

Issues #20 and #21 finish the boundary that the first corpus/retrieval tranche deliberately
left open. The live 9,076-row corpus is already verified and is therefore **an input to this
work, not something this work rebuilds**.

The implementation order is:

1. Make profile seeding replace only centroid `id = 1`; a profile bootstrap must never erase
   the independent venue centroid at `id = 2`.
2. Promote only the venue-voting portion of the old draft as migration `0003`. Do not carry
   along the unrelated `cohesion` rename: changing an established matching contract merely to
   obtain voting tables couples two failure domains again.
3. Persist generated options through one service-role-only Postgres function. The function
   owns both the options and their chat card in one transaction, and returns the existing rows
   on retry so a timeout cannot create a second ballot or pay for another retrieval.
4. Cast ballots through a database function rather than a client table upsert. This is what
   makes the cross-group option invariant enforceable and lets the database select a winner
   only after every current group member has voted. Ties resolve by displayed position so the
   result is deterministic and replayable.
5. Read options, the caller's private ballot, and the anonymous tally through the Flutter
   repository seam. The phone never receives anyone else's ballot.
6. Commit the group, its members, and their pending RSVPs through one service-only database
   function. Venue generation begins only after that transaction succeeds, and a failed venue
   call is reported and retried independently instead of duplicating or half-creating a group.

The existing `groups.venue` JSON remains as a backwards-compatible fallback for groups made
before this migration. New real options take precedence whenever they exist. Removing that
legacy column belongs in a later migration after every deployed caller has moved; doing it in
the integration change would turn a reversible rollout into a flag day.

Supersedes `VENUE_MATCHING.md`. Revised after two adversarial reviews, both of which ran real
tests rather than arguing: DuckDB against the live Overture bucket, and the proposed SQL
against a real ClickHouse. **Every number in this document was measured, not estimated.**

---

## 0. What is verified

```
Overture places, release 2026-08-19.0 — public S3, no credentials, no account
  9.8 GiB across 16 unpartitioned parquet files
  SF bbox extract:  59,063 places in ~15 s   (bbox row-group stats prune the scan)

  45,860  confidence > 0.7
  37,107  confidence > 0.7 AND operating_status = 'open'
   9,076  social, classified on the taxonomy tree (section 2.1)
```

Also verified by running it, not by reading it:

| | |
|---|---|
| ClickHouse Cloud | service live, 5 tables, `venue_vectors` loaded at 256 dims |
| Voyage `voyage-4` | 256-dim vectors; needs paced batching, see below |
| Claude `claude-opus-5` | `pitchVenues` returns group-aware copy, id guard holds |
| `deno check` + tests | 7 functions, 6 unit tests, via `scripts/check.sh` |
| PostgREST FK hint | `profiles!group_members_user_id_fkey` — verified against the live DB |

**Two runtime bugs that type-checking could not see**, both found only by executing:
`client.messages.parse` does not exist in the pinned SDK (structured output is under `beta`),
and `betaZodOutputFormat` calls `z.toJSONSchema`, which requires **zod 4** — zod 3 satisfies
the type signature but not the runtime. Both would have thrown from inside a request.

**Voyage rate limits by the minute.** Embedding this corpus is ~19 requests; bursting them
exhausts the window, and then every retry lands inside the same exhausted window, so the run
dies having embedded nothing. Reactive backoff cannot recover from a limit it has already
saturated — the ingest paces proactively at 21s between batches instead.

The ClickHouse SQL in §3.2, executed against a live server: nested
`{members:Array(Array(Float32))}` params work over HTTP, `cosineDistance` accepts a
lambda-bound array, `arrayAvg`/`arrayMin` are real, and `greatCircleDistance(lon,lat,lon,lat)`
returns 559,254 m for SF→LA — argument order correct.

**The corpus is not the schedule risk the previous revision implied. Stage 1 is ~15 minutes.**

---

## 1. Why Yelp cannot be the corpus

Three clauses, in the order that actually settles it:

**5(a) — the 24-hour rule.** No caching, recording, pre-fetching or storing of Yelp Content
beyond 24 hours from receipt. This alone ends the argument, whatever you call the artefact.

**9.3 — the retrieval-system clause.** Extends the model prohibition to *"any other databases,
models, or systems designed for processing, understanding, or generating output based on
natural language."* A vector index over Yelp text is squarely that.

**9.4 — no LLM ingestion, with no purpose qualifier.** *"Submit or ingest **any** Yelp Content
into **any** Generative AI Model (e.g., prompts that contain any Yelp Content)."* There is no
display-copy exemption. Any Yelp-derived field reaching a Claude prompt is a breach —
including a `noise_level` used to write a venue pitch.

> **Corrected from the previous revision.** It argued from 9.1 ("derivative works for the
> purpose of training… Generative AI Models") on the theory that an embedding is a derivative
> work. That is overreach: embedding for retrieval is not training, and an embedding model is
> not a Generative AI Model under the agreement's own definition. The conclusion was right,
> the reasoning was weak. Lead with 5(a) and 9.3.
>
> It also argued the quota made a corpus infeasible. It doesn't — the trial is 5,000 calls
> over 30 days, so 600 calls is 12% of it. Drop that argument; it is the attackable half of an
> otherwise unattackable case.

**The one carve-out that is real:** 5(a) permits *"storing Yelp business IDs which you may use
solely for back-end matching purposes"* — indefinitely. An Overture-GERS → Yelp-ID map is
expressly allowed, and halves the call count if enrichment is ever built.

**Non-commercial analysis rescues nothing.** That carve-out requires Yelp Content be displayed
*"in the aggregate as an analytical output, and not individually."* Show Up displays individual
venues. Do not let anyone spend time on this at 3pm.

---

## 2. The corpus: Overture Maps

- **Licence**: Places is CDLA Permissive 2.0 (Meta, Microsoft, PinMeTo and others), with the
  Foursquare subset Apache 2.0 and AllThePlaces CC0. Storable, embeddable, commercial-safe.
- **Access**: `s3://overturemaps-us-west-2/release/2026-08-19.0/theme=places/type=place/*`
  — public, unauthenticated, in the AWS Registry of Open Data.
- **Pin the release string.** `categories` is deprecated in favour of `basic_category` +
  `taxonomy`; it still exists in this release, so pinning is prudence, not urgency.

### 2.1 Use `taxonomy.primary` for the embed text, `taxonomy.hierarchy[1]` to classify

Two different fields for two different jobs.

**For the embedded document, use `taxonomy.primary`.** `basic_category` is far too coarse —
it collapses all 152 SF cocktail bars, every wine bar and every dive bar into the single token
`bar`, which makes them indistinguishable in the vector space. `taxonomy.primary` separates
them (`cocktail_bar`, `wine_bar`, `sushi_restaurant`, `ramen_restaurant`).

**For deciding what belongs in the corpus at all, use the tree.** Overture's taxonomy is
hierarchical, and the root level is where classification belongs:

| root | places (SF) | in corpus |
|---|---|---|
| `food_and_drink` | 7,381 | ✅ |
| `sports_and_recreation` | 1,326 | ✅ |
| `arts_and_entertainment` | 1,214 | ✅ |
| `cultural_and_historic` | 1,073 | ✅ |
| `geographic_entities` | 95 | ✅ |
| `services_and_business` | 9,100 | ❌ |
| `health_care` · `shopping` · `lifestyle_services` · `education` · `lodging` · … | 15,286 | ❌ |

Root decides inclusion; a leaf can only **opt out**, never opt in.

> **This replaced three hand-curated leaf lists, each of which was wrong.** Substring matching
> admitted a nursery and gardening store, 252 fitness centres and a children's ballet academy
> while missing `performing_arts_venue` and `social_club`. The exact list that replaced it
> invented the label `climbing_gym`, which does not exist — so Mission Cliffs, Dogpatch
> Boulders and Benchmark Climbing were all absent from a corpus then asked to find somewhere
> for a group of climbers, and the semantic gate returned an art gallery. The real label is
> `rock_climbing_spot`.
>
> The failure was the method. The SF slice has **1,231 distinct leaves**, and nobody reads
> 1,231 of anything carefully, so each pass fixed the cases that had already embarrassed it
> and missed the rest. Deciding at the root is exhaustive by construction — a leaf cannot be
> overlooked because no leaf is consulted for inclusion — reviewable at 14 lines instead of
> 1,231, and stable: leaves added in a future release inherit the right answer instead of
> silently dropping out.

The exclusions within social roots are chosen by reading the real vocabulary: gyms and
studios (a class is not a conversation), stadiums (need a ticketed event), places of worship
(not neutral ground for people matched on hobbies), `historic_site` (429 of SF's are plaques).

**The vocabulary is committed and the classifier is replayed over it.**
`clickhouse/taxonomy_tree.csv` holds every root/leaf pair with counts;
`scripts/verify_taxonomy.py` runs `is_social()` across all of them and asserts the eight
labels that must be admitted and the eight that must not. Each assertion is one of the bugs
above. Run it after any change to the classifier — a list this long cannot be checked by
reading it.

Result: **9,076 of 37,107** open, confident SF places.

### 2.2 `confidence > 0.7` is not the closed-venue guard

The previous revision called it "the single cheapest quality win available." Measured, it
isn't:

| `operating_status` | rows | survive `confidence > 0.7` |
|---|---|---|
| `open` | 41,496 | 37,107 (89%) |
| `permanently_closed` | 2,097 | **1,036 (49%)** |
| null | 15,391 | 7,653 (50%) |

Confidence scores *existence*, not *operation*. It leaves 1,036 permanently-closed SF venues in
the corpus. Sending six strangers to a closed bar is this product's worst possible bug.

```sql
WHERE confidence > 0.7 AND operating_status = 'open'   -- 37,153 SF places, zero known-closed
```

One clause. Non-negotiable.

### 2.3 Yelp is out of scope today

Not "optional, build it if there's time" — **out**. The compliance surface in §1, especially
9.4, exists only if the source is in the build, and enrichment is the largest time sink in the
plan for the smallest demo gain. If it is ever built: display layer only, post-generation,
never into a prompt, never persisted except the business ID.

---

## 3. The matching algorithm

### 3.1 Score per member, then aggregate — and justify it honestly

Do not retrieve by the centroid of member embeddings. Score each venue against each member and
aggregate the **scores**:

```
s_i    = 1 - cosineDistance(member_i, venue)
score  = 0.5 * mean(s) + 0.5 * min(s)
```

**The honest justification is the product, not the geometry.** Show Up promises you can turn up
alone and not have a bad night. A venue that delights four people and bores two is worse, by
our own thesis, than one that suits all six. The `min` term is that promise as arithmetic.

Verified: a venue scoring 1.0 / 0.0 across two members ranks **below** one scoring 0.707 /
0.707 — 0.25 against 0.707. It does what it claims.

> **Two claims removed. Do not put either on stage.**
>
> *"High-dimensional centroids are hubs."* Misapplied. Hubness is a property of the database
> points, independent of how you query; querying by centroid does not create it and per-member
> scoring does not remove it. The concept being reached for was centroid *concentration* — and
> that is largely defused here anyway, because the vectors are mean-centred and cosine is
> scale-invariant, so a shorter centroid ranks identically. "Hubness" is exactly the word a
> judge who knows retrieval will pull on.
>
> *"Averaging fails for diverse groups."* The cited diversity is `run-matching` spreading
> members across energy levels — but `energy` is a categorical column, not a dimension of the
> embedding, and members are selected as the seed's nearest neighbours *in that embedding*. In
> the space where averaging happens, groups are deliberately homogeneous: the documented
> condition under which Average performs **well**.

**Name it correctly.** `0.5·avg + 0.5·min` is a blend of the Average and Least Misery
strategies. It is **not** "average without misery" — in the literature that means averaging
while *excluding* items where any member falls below a misery threshold. If you prefer the real
thing, it is cleaner and fits the hard-filter discipline better:

```sql
WHERE arrayMin(s) >= {floor:Float64} ORDER BY arrayAvg(s) DESC
```

A hard misery floor states "nobody has a bad night" better than a weight that lets a high
average buy out one miserable member.

### 3.2 The query

```sql
SELECT venue_id, name, taxonomy_primary,
       arrayMap(m -> 1 - cosineDistance(embedding, m), {members:Array(Array(Float32))}) AS s,
       0.5 * arrayAvg(s) + 0.5 * arrayMin(s) AS score
FROM venue_vectors
WHERE greatCircleDistance(lng, lat, {clng:Float64}, {clat:Float64}) < {radius_m:Float64}
  AND is_social
ORDER BY score DESC
LIMIT 50
FORMAT JSON
```

One scan, six member vectors, no centroid, no index. `FORMAT JSON` carries the `statistics`
block — put `elapsed` and `rows_read` on screen.

**`arr()` in `_shared/clickhouse.ts` only flattens one level.** Passing `Array(Array(Float32))`
needs an `arr2()` helper. Two lines, and it is the first thing that will fail.

### 3.3 The geo anchor is a fixed city centre

The previous revision anchored on "the centroid of members' locations" and proposed minimising
the worst individual travel. **Neither is implementable: members have no coordinates.**
`profiles` has `city text` and nothing else; the only lat/lng in the schema lives inside
`groups.venue`, written *after* matching.

For today `{clng}/{clat}` are a constant — SF city centre — with a radius. Min-max travel is
post-hackathon and depends on adding location to signup, which is **not** a today change.

### 3.4 Pipeline, after cuts

```
  1. GEO + STATUS FILTER   radius, operating_status, is_social     37k → ~2k
  2. VECTOR SCORE          avg / least-misery blend, per member    ~2k → 50
  3. DIVERSIFY             distinct taxonomy_primary                50 → 3
  4. PITCH                 one Claude call, returned ids validated  3 + copy
```

**RRF is cut.** It was specified over `{vector, popularity, category-match}`, but Overture has
no popularity signal of any kind — the source that provided `rating` and `review_count` left
with Yelp, and the fusion step that consumed them stayed behind. Category-match is a boolean,
so as a ranking it is one large tie. If fusion is ever wanted, `confidence` is the honest
substitute for popularity.

**Reranking is cut.** A cross-encoder earns its keep by *reading* the candidate. The venue
document is a name, a category and a neighbourhood. There is nothing there the bi-encoder did
not already get, and you cannot rerank your way out of a thin corpus.

**Diversification is the step that makes the vote real.** Three cocktail bars is not a
decision. Enforce distinct `taxonomy_primary`, and bias the third toward a different *mode* —
if the first two are sit-and-talk, make the third do-a-thing. That turns the vote into the
question groups actually disagree on.

### 3.5 Embedding: same model and dimension, **different centroid**

```
Kinship
Category: cocktail bar
Neighborhood: Mission District, San Francisco
```

- **Same model, same 256 dims** as profiles. Non-negotiable.
- **Centre venues by the venue-corpus mean — not `embedding_mean`.**

> **This is the correction that matters most, and the previous revision had it backwards.** It
> said venues must share the profile centroid or "the distances between them are meaningless."
> That assertion *causes* the failure it warns about.
>
> `embedding_mean` is the centroid of ~200 archetype bios — people describing hobbies. Venue
> text is a different domain with its own mean `m_v`. Subtracting the profile centroid `c`
> leaves every venue carrying a shared offset `(m_v − c)`, so for any query the numerator gains
> a term identical across all venues, and ranking is driven substantially by `‖v̂‖` — which is
> minimised by the venue nearest the *profile* centroid. **The same venue, for every group,
> silently.** Per-member scoring does not help: the offset is shared by every member equally.
>
> Fix: compute a venue-corpus mean at ingest, store it as a second row in `embedding_mean`
> (`id = 2`), and have the venue path read that one. ~5 lines.

Also consider `input_type`. Person↔person is symmetric, which is why `voyage.ts` correctly uses
`null`. Person↔venue is the asymmetric query/document case that parameter exists for. Nothing
errors either way, so this is a quality question rather than a correctness one — but it is free
to get right.

---

## 4. Code structure

**Two files of new server code. No bounded context, no ports, no adapters.**

```
clickhouse/003_venues.sql                  venue_vectors DDL
scripts/ingest_venues.py                   Overture → bbox → embed → insert  (one script)
supabase/functions/_shared/venues.ts       types, query, ranking       (~80 lines)
supabase/functions/pick-venues/index.ts    auth, load group, retrieve, pitch  (~120 lines)
```

> **The previous revision proposed an eight-file `_shared/venues/` package with two ports and
> four adapters. That was ceremony.** One real implementation behind an interface is a synonym,
> not an abstraction. Two of the four adapters served the enrichment layer, now cut.
> `fixture_corpus.ts` would have duplicated `app/lib/data/mock_repository.dart`, which already
> works and already renders through `venue_vote_card.dart`. And it is stylistically foreign:
> the whole ClickHouse client is one 103-line file, the whole LLM layer is 91 lines, and
> `run-matching` inlines everything with no ports anywhere.

### The branded-type idea does not work here

The previous revision claimed the licence boundary could be enforced by the type system —
`OwnedVenue` versus `EphemeralEnrichment`, with no persistence function accepting the latter.
Nice idea; it fails three ways:

1. **Nothing type-checks this repo.** No CI, no `deno check` anywhere, and function deploys
   bundle rather than verify. "Fails to compile" is false when nothing compiles it.
2. **It guards the wrong door.** The persistence primitive is `ch(sql: string, params)` — it
   takes a string. ``ch(`INSERT … '${yelp.name}'`)`` type-checks perfectly.
3. **It cannot see the real leak.** Yelp attribute → Claude prompt → `pitch` string →
   persisted. A pitch is a `string`; no type notices, and clause 9.4 is breached at the prompt,
   before persistence is even reached.

The compliance problem disappears when the non-compliant source is not in the build. Keep §1 as
the *reason* Overture is the corpus — it is a genuinely good answer to a judge — and put it in
the writeup, not the type system.

---

## 5. Build order

Prerequisites first, because each can consume the whole afternoon:

- [ ] **`.env.functions` keys are empty.** `VOYAGE_API_KEY`, `ANTHROPIC_API_KEY` and
      `CLICKHOUSE_PASSWORD` have no values. Nothing below works until they do.
- [ ] `SELECT count() FROM profile_vectors` and `SELECT length(mean) FROM embedding_mean` — if
      ClickHouse is empty, that is the afternoon and venues are irrelevant.
- [ ] **Settle with the other agent: does the demo run on `MockRepository` or Supabase?**
      Everything branches on this. If Mock, never touch `repository.dart` or `migrations/` and
      the collision risk goes to zero.

| # | Time | Work |
|---|---|---|
| 1 | 15 min | `ingest_venues.py`: Overture → SF bbox → `operating_status='open'` → `taxonomy.primary`. Needs `duckdb` with **`httpfs` and `spatial`** — `ST_X`/`ST_Y` fail without spatial. |
| 2 | 20 min | `003_venues.sql`; embed; store the **venue** centroid as `embedding_mean id=2`. |
| 3 | **gate** | **Take one obviously climbing-shaped profile and confirm a bouldering gym outranks a nail salon.** If it doesn't, it is §3.5. |
| 4 | 30 min | `pick-venues`: query, diversify, Claude pitch, validate returned ids against the ids sent. |
| 5 | 20 min | Get the output into the app by the cheapest honest route given the Mock/Supabase answer. |
| 6 | rest | Stop building. Rehearse. Write the ClickHouse story down. |

**Stage 3 is the real gate, not "do two groups get different venues".** That check passes
whether or not the centroid bug is fixed, because the lists differ marginally regardless. A
semantic check — does a climber get a climbing gym — is the one that exposes §3.5.

---

## 6. Failure modes

1. **Every group gets the same bland venue.** Venues centred with the profile centroid (§3.5).
   Silent, no error. *Gate:* stage 3.
2. **A recommended venue is closed.** `confidence` alone leaves 1,036 closed SF venues.
   *Gate:* `operating_status = 'open'`.
3. **Nothing renders in the app.** The pipeline returns perfect venues to `curl` while the demo
   phone runs `MockRepository` and `SupabaseRepository.currentGroup()` still throws
   `UnimplementedError`. *Gate:* the Mock/Supabase decision, made first, not at 4pm.
4. **Three variations of the same place.** No diversification — the vote is theatre.
   *Gate:* assert distinct `taxonomy_primary`.
5. **`arr()` cannot express a nested array.** First thing that fails. *Gate:* write `arr2()` up front.
6. **A category filter matching nothing.** The vocabulary was guessed rather than read (§2.1).
7. **Promoting `0002_product_model.sql.draft` to get `venue_options`.** It also renames
   `groups.cohesion` → `seed_distance`, which **breaks `run-matching`** mid-sweep, on another
   agent's critical path. If the tables are needed, write a new migration containing only
   `venue_options`, `venue_votes`, `messages.kind`, `venue_tally()` and their policies.

---

## 7. Cost

Overture $0 · Voyage embeddings $0 (200M free tokens) · Claude cents per group · ClickHouse
trial $0. Yelp not used.

---

Sources: [Yelp API Terms](https://terms.yelp.com/developers/api_terms/20250113_en_us/) ·
[Overture places guide](https://docs.overturemaps.org/guides/places/) ·
[Overture licensing](https://docs.overturemaps.org/attribution/) ·
[ClickHouse vector search](https://clickhouse.com/docs/engines/table-engines/mergetree-family/annindexes) ·
[Voyage pricing](https://docs.voyageai.com/docs/pricing) ·
[Group recommender aggregation strategies](https://link.springer.com/chapter/10.1007/978-1-4899-7637-6_22)
