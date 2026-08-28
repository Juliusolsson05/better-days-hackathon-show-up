-- Venue corpus. Run after 001_schema.sql, then load with scripts/ingest_venues.py.
--
-- Source is Overture Maps places (CDLA Permissive 2.0 / Apache 2.0), which may be stored,
-- embedded and committed. Yelp is deliberately NOT the corpus: its terms forbid caching
-- beyond 24 hours, forbid building a natural-language retrieval system over its content,
-- and forbid submitting any of it to a generative model. See docs/VENUE_PIPELINE.md.

CREATE TABLE IF NOT EXISTS venue_vectors
(
    venue_id         String,                  -- Overture GERS id, stable across releases
    name             String,
    taxonomy_primary LowCardinality(String),  -- cocktail_bar, sushi_restaurant, music_venue
    basic_category   LowCardinality(String),  -- coarser fallback when taxonomy is null
    address          String,
    locality         LowCardinality(String),
    lat              Float64,
    lng              Float64,
    confidence       Float32,
    -- Whether this is somewhere six strangers could plausibly spend an evening. Computed at
    -- ingest from the taxonomy, because the corpus is overwhelmingly dentists and law firms:
    -- only ~6.7k of 37k open SF places are social.
    is_social        Bool,
    -- 256 dims, centred on the VENUE corpus mean (embedding_mean id=2), never the profile
    -- mean. Centring on the profile mean leaves a shared offset that makes one venue rank
    -- first for every group -- silently. See docs/VENUE_PIPELINE.md section 3.5.
    embedding        Array(Float32),
    updated_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
-- Keyed on venue_id alone so re-ingesting a release replaces rows rather than duplicating
-- them. Not ordered by locality: the match query is a full scan by design, and a compound
-- key would break dedup for any venue whose address is corrected between releases.
ORDER BY venue_id;

-- embedding_mean already exists from 001_schema.sql, holding the profile centroid at id=1.
-- The venue centroid is inserted at id=2 by the ingest script. Nothing to create here; this
-- comment exists so the two-centroid rule is discoverable from the schema.
