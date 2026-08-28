-- Existing rows used second-precision insertion time as the ReplacingMergeTree version. A slow,
-- stale request inserted later could therefore replace a newer profile. The API now supplies the
-- strictly increasing Postgres submission version explicitly; changing the existing version
-- column in place preserves all derived rows and keeps this upgrade safe to rerun.
ALTER TABLE profile_vectors
    ADD COLUMN IF NOT EXISTS submission_id UUID
    DEFAULT toUUID('00000000-0000-0000-0000-000000000000')
    AFTER alcohol_ok;

ALTER TABLE profile_vectors
    MODIFY COLUMN updated_at DateTime64(6) DEFAULT now64(6);
