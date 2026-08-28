-- ClickHouse schema. Run against ClickHouse Cloud before anything else.
--   clickhouse client --host <host> --secure --password <pw> < clickhouse/001_schema.sql
--
-- Split of responsibility with Postgres: Postgres owns anything read one row at a
-- time and required to be correct right now (users, groups, chat). ClickHouse owns
-- anything scanned across the whole population (the matching sweep, the event stream).
-- profile_vectors is therefore a DERIVED table -- Postgres is still the source of truth
-- for who a user is.

-- ~200 hand-written bios embedded for real via Voyage. Two jobs: they are the cluster
-- centres the synthetic population is generated around, and their centroid is what we
-- use for mean-centering (see embedding_mean).
CREATE TABLE IF NOT EXISTS archetypes
(
    id        UInt32,
    label     String,
    bio       String,
    embedding Array(Float32),
    tags      Array(String),
    energy    LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY id;

-- Embeddings are stored ALREADY MEAN-CENTERED. Raw embedding models are anisotropic --
-- every vector points into the same narrow cone, so every pair scores ~0.85 and the
-- nearest-neighbour ranking degenerates into noise. Subtracting the population centroid
-- restores the spread. Doing it at write time keeps the hot query a plain cosineDistance.
CREATE TABLE IF NOT EXISTS profile_vectors
(
    user_id      UUID,
    embedding    Array(Float32),          -- 256 dims, centered
    tags         Array(String),
    city         LowCardinality(String),
    availability Array(String),
    energy       LowCardinality(String),
    indoor       Bool,
    alcohol_ok   Bool,
    updated_at   DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
-- Ordered by user_id alone so re-embedding a profile replaces it instead of appending a
-- duplicate. We deliberately do NOT order by city: the match query is a full scan by
-- design, and a compound key would break dedup when someone moves.
ORDER BY user_id;

-- Single-row table holding the population centroid. Kept in the database rather than in
-- code so the edge function and the seed script cannot disagree about it.
CREATE TABLE IF NOT EXISTS embedding_mean
(
    id          UInt8 DEFAULT 1,
    mean        Array(Float32),
    n           UInt64,
    computed_at DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(computed_at)
ORDER BY id;

-- Append-only product funnel. Everything the app does emits a row here; the dashboard is
-- built entirely from this table.
CREATE TABLE IF NOT EXISTS events
(
    ts       DateTime64(3) DEFAULT now64(3),
    user_id  UUID,
    group_id UUID,
    name     LowCardinality(String),  -- signup|rsvp|notif_sent|notif_opened|attended|answered|number_shared
    props    String                    -- free-form JSON, kept as String so new fields need no migration
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (name, ts);
