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

# Somewhere six strangers could plausibly spend an evening.
#
# This is an EXACT allowlist, read off the real taxonomy, not a substring match. Substring
# matching was tried first and was wrong in both directions: "garden" admitted
# nursery_and_gardening_store, "gym" admitted every Bushido Fitness Center, "dance" admitted
# a children's ballet academy, while performing_arts_venue and social_club were missed
# entirely. The corpus is overwhelmingly not social -- of ~37k open SF places the largest
# categories are health_care, hair_salon and doctors_office -- so precision matters more
# than recall here.
SOCIAL_TAXONOMIES = frozenset({
    # drink
    "bar", "cocktail_bar", "wine_bar", "sports_bar", "gay_bar", "dive_bar", "beer_bar",
    "tapas_bar", "pub", "irish_pub", "gastropub", "brewery", "brewpub", "taproom",
    "winery", "distillery", "lounge", "speakeasy",
    # coffee and sweet
    "coffee_shop", "cafe", "tea_room", "bubble_tea_shop", "ice_cream_shop", "dessert_shop",
    "bakery", "creamery", "juice_bar",
    # eat (the cuisine family is handled by the _restaurant suffix rule below)
    "restaurant", "sandwich_shop", "delicatessen", "food_hall", "steakhouse", "diner",
    # do
    "music_venue", "theatre_venue", "performing_arts_venue", "comedy_club", "movie_theater",
    "cinema", "dance_club", "night_club", "karaoke_bar", "arcade", "bowling_alley",
    "billiards", "escape_room", "mini_golf", "climbing_gym", "bouldering_gym",
    "pottery_studio", "board_game_cafe",
    # look
    "art_gallery", "museum", "art_museum", "history_museum", "science_museum", "aquarium",
    "zoo", "botanical_garden", "bookstore",
    # outdoors and gather
    "park", "public_plaza", "beach", "social_club", "event_venue",
})


def is_social(taxonomy: str | None, basic: str | None) -> bool:
    """Exact match, plus a suffix rule so every cuisine (sushi_, thai_, ...) is covered."""
    label = (taxonomy or basic or "").lower()
    if not label:
        return False
    return label in SOCIAL_TAXONOMIES or label.endswith("_restaurant")


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
        "venue_id", "name", "taxonomy_primary", "basic_category",
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


def embed(texts):
    """input_type is null, matching the profile path in _shared/voyage.ts."""
    out = []
    for i in range(0, len(texts), 128):
        res = requests.post(
            "https://api.voyageai.com/v1/embeddings",
            headers={"Authorization": f"Bearer {VOYAGE_KEY}"},
            json={
                "input": texts[i:i + 128],
                "model": "voyage-4",
                "input_type": None,
                "output_dimension": DIMS,
            },
            timeout=180,
        )
        res.raise_for_status()
        out.extend(d["embedding"] for d in res.json()["data"])
        if (i // 128) % 10 == 0:
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
    social = [v for v in venues if is_social(v["taxonomy_primary"], v["basic_category"])]
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
