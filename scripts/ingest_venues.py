#!/usr/bin/env python3
"""Build the venue corpus: Overture Maps -> SF bbox -> embed -> ClickHouse.

    pip install requests duckdb
    python scripts/ingest_venues.py

Runs in ~15 minutes end to end, most of it embedding. The Overture extract itself takes
about 15 seconds: the parquet files carry bbox row-group statistics, so DuckDB prunes the
9.8 GiB remote dataset down to the rows inside the bounding box and never transfers the rest.

Why Overture and not Yelp: Overture places is CDLA Permissive 2.0 / Apache 2.0, so it may be
stored, embedded and committed. Yelp's terms forbid caching its content beyond 24 hours,
forbid building a natural-language retrieval system over it, and forbid submitting any of it
to a generative model. A committed vector index of Yelp venues breaches all three.
See docs/VENUE_PIPELINE.md section 1.
"""

import json
import os
import sys
import time

import duckdb
import requests

VOYAGE_KEY = os.environ["VOYAGE_API_KEY"]
CH_URL = os.environ["CLICKHOUSE_URL"]
CH_USER = os.environ["CLICKHOUSE_USER"]
CH_PASS = os.environ["CLICKHOUSE_PASSWORD"]

DIMS = 256  # must match _shared/voyage.ts and clickhouse/001_schema.sql
VENUE_CENTROID_ID = 2  # id=1 is the profile centroid; see section 3.5

# Pinned. `categories` is deprecated in favour of basic_category + taxonomy and disappears in
# a later release, so an unpinned path would change schema underneath us mid-project.
RELEASE = "2026-08-19.0"
S3_PLACES = (
    f"s3://overturemaps-us-west-2/release/{RELEASE}/theme=places/type=place/*.parquet"
)

# San Francisco. Widen for the wider Bay Area; the extract time scales with the box, not the
# dataset.
BBOX = (-122.52, -122.35, 37.70, 37.83)  # xmin, xmax, ymin, ymax

# --- Is this somewhere six strangers could spend an evening? ---------------------------
#
# Classified on Overture's taxonomy TREE, not on a hand-written list of leaf labels.
#
# Three earlier attempts hand-curated leaves and each one was wrong, because the SF slice has
# 1,231 distinct leaves and no human reads them all: substrings admitted a gardening store and
# a children's ballet academy while missing performing_arts_venue; the exact list that
# replaced it invented "climbing_gym", so every real climbing gym in the city was absent from
# a corpus later asked to find somewhere for climbers. The actual label is rock_climbing_spot.
#
# The tree has 14 roots. Deciding at the root is exhaustive by construction -- no leaf can be
# overlooked -- reviewable, and stable: leaves added in a future Overture release inherit the
# right answer automatically instead of silently falling out of the corpus.
#
# Counts below are from the SF slice at release 2026-08-19.0, via /tmp/taxonomy_tree.csv.
SOCIAL_ROOTS = frozenset({
    "food_and_drink",          # 7,381 - restaurants, bars, cafes. Social almost by definition.
    "arts_and_entertainment",  # 1,214 - galleries, music venues, cinemas, arcades.
    "sports_and_recreation",   # 1,326 - parks, climbing, bowling. Also gyms; see below.
    "cultural_and_historic",   # 1,073 - museums and cultural centres. Mostly worship; see below.
    "geographic_entities",     #    95 - beaches, piers, botanical gardens.
})

# Leaves inside a social root that are still not a place to send six strangers. Each of these
# was read off the real vocabulary rather than imagined.
EXCLUDED_LEAVES = frozenset({
    # Not an evening out.
    "fast_food_restaurant",
    # Classes and training: you attend these alone, on a schedule, and they are not a
    # conversation. This is the whole reason `gym` cannot be admitted wholesale -- 252 of them.
    "gym", "boxing_gym", "yoga_studio", "pilates_studio", "dance_studio", "martial_arts_club",
    "gymnastics_center", "boot_camp", "boxing_class", "cycling_class", "barre_class",
    "qi_gong_studio", "fitness_trainer", "swimming_instructor", "swimming_lessons",
    # Membership clubs and teams -- you cannot simply turn up.
    "amateur_sport_team", "soccer_club", "fishing_club", "lawn_bowling_club", "fencing_club",
    "table_tennis_club", "sport_or_recreation_club", "choir", "veterans_organization",
    "fraternal_organization",
    # Venues that need a ticketed event to mean anything.
    "stadium_arena", "baseball_stadium", "soccer_stadium", "football_stadium",
    "tennis_stadium", "fairgrounds", "auditorium", "ticket_office_or_booth",
    # For children.
    "playground", "petting_zoo", "childrens_museum",
    # Services that happen to sit under an entertainment root.
    "psychic_advising", "astrological_advising", "lottery_vendor",
    # Adult venues and gambling: wrong setting for strangers matched by an algorithm.
    "adult_entertainment_venue", "strip_club", "casino", "bingo_hall", "shooting_range",
    # Places of worship. Excluded as a class, not a judgement: a religious setting is not
    # neutral ground for six people matched on hobbies, and stance is exactly what the
    # embedding cannot see.
    "christian_place_of_worship", "baptist_place_of_worship", "roman_catholic_place_of_worship",
    "buddhist_place_of_worship", "jewish_place_of_worship", "pentecostal_place_of_worship",
    "muslim_place_of_worship", "hindu_place_of_worship", "mormon_place_of_worship",
    "place_of_worship", "religious_organization", "religious_school",
    # Landmarks you look at rather than spend time in. historic_site alone is 429 rows in SF,
    # overwhelmingly plaques and facades, and would dominate the corpus.
    "historic_site", "monument", "sculpture_statue", "street_art", "bridge",
    # Dog parks are for dogs.
    "dog_park",
})


def is_social(hierarchy_root: str | None, taxonomy: str | None) -> bool:
    """Root decides inclusion; a leaf can only opt out, never opt in.

    Places with no taxonomy at all (~732 in SF) are dropped: with neither a root nor a leaf
    there is nothing to classify on, and guessing from the name is how this went wrong before.
    """
    if not hierarchy_root or hierarchy_root not in SOCIAL_ROOTS:
        return False
    return (taxonomy or "") not in EXCLUDED_LEAVES


def extract():
    """Pull the bbox out of Overture. Read-only, public, no credentials."""
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs; SET s3_region='us-west-2';")
    xmin, xmax, ymin, ymax = BBOX
    print(f"extracting {RELEASE} for bbox {BBOX} ...", file=sys.stderr)
    rows = con.execute(
        f"""
        SELECT
            id                        AS venue_id,
            names.primary             AS name,
            taxonomy.primary          AS taxonomy_primary,
            -- The root of the taxonomy tree. This, not the leaf, decides whether a place is
            -- somewhere a group could meet -- see is_social().
            taxonomy.hierarchy[1]     AS taxonomy_root,
            basic_category,
            -- POI bboxes are degenerate (xmin == xmax), so bbox doubles as the point and we
            -- avoid needing the spatial extension just to unpack a geometry blob.
            bbox.xmin                 AS lng,
            bbox.ymin                 AS lat,
            confidence,
            COALESCE(addresses[1].freeform, '') AS address,
            COALESCE(addresses[1].locality, '') AS locality
        FROM read_parquet('{S3_PLACES}')
        WHERE bbox.xmin BETWEEN {xmin} AND {xmax}
          AND bbox.ymin BETWEEN {ymin} AND {ymax}
          AND confidence > 0.7
          -- Not optional. confidence scores whether a place EXISTS, not whether it still
          -- trades: it lets through 49% of permanently-closed venues, which in SF is ~1,036
          -- of them. Sending six strangers to a closed bar is this product's worst bug.
          AND operating_status = 'open'
          AND names.primary IS NOT NULL
        """
    ).fetchall()
    cols = [
        "venue_id", "name", "taxonomy_primary", "taxonomy_root", "basic_category",
        "lng", "lat", "confidence", "address", "locality",
    ]
    out = [dict(zip(cols, r)) for r in rows]
    print(f"  {len(out)} open, confident places", file=sys.stderr)
    return out


# Overture's `locality` is city-level, not neighbourhood-level: 8,292 of 8,394 SF social
# venues carry the literal string "San Francisco", with the rest being case and formatting
# variants of it. Normalised here for display only -- see document() for why it is kept out
# of the embedded text.
_SF_VARIANTS = {"sf", "san francisco", "san francisco, ca", "san francisco, ca, us"}


def clean_locality(raw: str) -> str:
    s = (raw or "").strip()
    return "San Francisco" if s.lower() in _SF_VARIANTS or not s else s


def document(v: dict) -> str:
    """The text that gets embedded.

    Name plus category, and deliberately nothing else. Name alone is nearly signal-free --
    "Kinship" tells you nothing -- so the category carries most of the meaning, and
    taxonomy_primary is used over basic_category because basic_category collapses every
    cocktail bar, wine bar and dive bar in the city into the single token "bar".

    The neighbourhood is deliberately NOT included. It reads like useful context, but
    Overture's locality is city-level: it is the same string for 98.8% of this corpus, so it
    adds no way to tell two venues apart while contributing an identical component to every
    vector -- which is the shared-offset anisotropy the pipeline works to avoid elsewhere.
    """
    kind = (v["taxonomy_primary"] or v["basic_category"] or "venue").replace("_", " ")
    return f"{v['name']}\nCategory: {kind}"


# Seconds to wait between embedding requests. The free tier is limited per minute, and
# reactive backoff alone does not work here: bursting exhausts the window, then every retry
# arrives inside the same exhausted window and the run dies having embedded nothing. Pacing
# proactively keeps every request inside the allowance instead of racing it.
EMBED_INTERVAL_S = 21.0


def embed(texts, batch=500):
    """input_type is null, matching the profile path in _shared/voyage.ts.

    Paced rather than burst. Venue documents are ~15 tokens each, so a 500-item batch is
    ~7.5k tokens -- comfortably inside both the model's context and a conservative
    per-minute token allowance. This corpus is then ~17 requests and about six minutes.

    Still retries on 429, honouring Retry-After when Voyage sends it, as a safety net for
    a tighter account limit than the pacing assumes.
    """
    out = []
    for i in range(0, len(texts), batch):
        chunk = texts[i:i + batch]
        if i:
            time.sleep(EMBED_INTERVAL_S)
        for attempt in range(8):
            res = requests.post(
                "https://api.voyageai.com/v1/embeddings",
                headers={"Authorization": f"Bearer {VOYAGE_KEY}"},
                json={
                    "input": chunk,
                    "model": "voyage-4",
                    "input_type": None,
                    "output_dimension": DIMS,
                },
                timeout=180,
            )
            if res.status_code == 429:
                wait = float(res.headers.get("Retry-After", min(60, 2 ** attempt)))
                print(f"  rate limited, sleeping {wait:.0f}s", file=sys.stderr)
                time.sleep(wait)
                continue
            res.raise_for_status()
            out.extend(d["embedding"] for d in res.json()["data"])
            break
        else:
            raise SystemExit(f"voyage kept rate limiting at item {i}")
        print(f"  embedded {len(out)}/{len(texts)}", file=sys.stderr)
    return out


def ch(sql, body=None):
    res = requests.post(
        CH_URL,
        headers={"X-ClickHouse-User": CH_USER, "X-ClickHouse-Key": CH_PASS},
        data=(sql if body is None else sql + "\n" + body).encode(),
        timeout=600,
    )
    if not res.ok:
        raise SystemExit(f"clickhouse {res.status_code}: {res.text}")
    return res.text


def main():
    venues = extract()
    social = [v for v in venues if is_social(v["taxonomy_root"], v["taxonomy_primary"])]
    print(f"  {len(social)} social venues", file=sys.stderr)
    if not social:
        raise SystemExit("no social venues matched -- read the taxonomy before filtering it")

    print(f"embedding {len(social)} venues ...", file=sys.stderr)
    raw = embed([document(v) for v in social])

    # The venue centroid, computed over THIS corpus and stored separately from the profile
    # centroid at id=1. Venue text and profile text are different domains with different
    # means; centring venues on the profile mean leaves every venue carrying the same offset,
    # which makes a single venue rank first for every group, silently. Section 3.5.
    mean = [sum(col) / len(raw) for col in zip(*raw)]
    centered = [[x - m for x, m in zip(vec, mean)] for vec in raw]

    ch(f"ALTER TABLE embedding_mean DELETE WHERE id = {VENUE_CENTROID_ID}")
    ch(
        "INSERT INTO embedding_mean (id, mean, n) FORMAT JSONEachRow",
        json.dumps({"id": VENUE_CENTROID_ID, "mean": mean, "n": len(raw)}),
    )

    ch("TRUNCATE TABLE IF EXISTS venue_vectors")
    payload = "\n".join(
        json.dumps({
            "venue_id": v["venue_id"],
            "name": v["name"],
            "taxonomy_primary": v["taxonomy_primary"] or "",
            "basic_category": v["basic_category"] or "",
            "address": v["address"],
            "locality": clean_locality(v["locality"]),
            "lat": v["lat"],
            "lng": v["lng"],
            "confidence": v["confidence"],
            "is_social": True,
            "embedding": vec,
        })
        for v, vec in zip(social, centered)
    )
    ch("INSERT INTO venue_vectors FORMAT JSONEachRow", payload)

    n = ch("SELECT count() FROM venue_vectors").strip()
    dims = ch("SELECT length(any(embedding)) FROM venue_vectors").strip()
    print(f"loaded {n} venues at {dims} dims", file=sys.stderr)
    if int(dims) != DIMS:
        raise SystemExit(f"expected {DIMS} dims, got {dims}")

    # The gate. A climbing-shaped query must surface climbing-shaped venues; if it returns a
    # nail salon, the centring is wrong and every downstream result is noise with no error to
    # show for it. Cheap to run, and the only check that catches section 3.5 going wrong.
    probe = embed(["Interests: climbing, bouldering, outdoors\n\n"
                   "Passionate about: route reading and spending all day on one problem."])[0]
    probe = [x - m for x, m in zip(probe, mean)]
    top = ch(
        "SELECT name, taxonomy_primary FROM venue_vectors "
        f"ORDER BY cosineDistance(embedding, {json.dumps(probe)}) ASC LIMIT 5 FORMAT TSV"
    )
    print("\nsanity check -- nearest venues to a climbing profile:", file=sys.stderr)
    print(top, file=sys.stderr)
    print("if those are nail salons, the centroid is wrong -- see VENUE_PIPELINE.md 3.5",
          file=sys.stderr)


if __name__ == "__main__":
    main()
