-- This deadline-safe seed intentionally derives people-shaped demo clusters from the venue
-- embeddings already in the service. The preferred production bootstrap uses Voyage-embedded
-- bios, but requiring a second vendor credential at demo time would leave every profile and
-- funnel surface empty. Reusing real vectors preserves the geometry the matcher exercises; the
-- labels and tags make the synthetic provenance explicit rather than pretending these are users.
INSERT INTO archetypes (id, label, bio, embedding, tags, energy)
SELECT
    toUInt32(row_number() OVER (ORDER BY cityHash64(venue_id)) - 1) AS id,
    concat('Demo interest cluster ', toString(id + 1)) AS label,
    concat('Synthetic demo cluster derived from ', taxonomy_primary, ' venues in ', locality) AS bio,
    embedding,
    arrayFilter(tag -> notEmpty(tag), [taxonomy_primary, basic_category, locality]) AS tags,
    ['low', 'medium', 'high'][(cityHash64(venue_id) % 3) + 1] AS energy
FROM venue_vectors FINAL
WHERE length(embedding) = 256
  -- Idempotency is more important than silently refreshing the demo population. profile_vectors
  -- relies on dense archetype IDs, so appending a second run would invalidate its modulo join.
  AND (SELECT count() FROM archetypes) = 0
ORDER BY cityHash64(venue_id)
LIMIT 200;

-- The normal profile seed centers human-bio embeddings and adds per-coordinate jitter. On the
-- smallest ClickHouse Cloud trial tier, materializing that million-by-256 array expression needs
-- more than the 7.2 GiB query ceiling. Demo profiles therefore reuse one of 200 real semantic
-- vectors verbatim: this remains useful nearest-neighbour data, compresses extremely well, and
-- avoids pretending random noise is meaningful. A zero centroid tells the online writer/query
-- path that this emergency corpus is intentionally uncentered; the normal seed replaces id=1.
INSERT INTO embedding_mean (id, mean, n)
SELECT 1, CAST(arrayMap(_ -> 0.0, range(256)) AS Array(Float32)), count()
FROM archetypes
HAVING count() > 0
   AND (SELECT count() FROM profile_vectors) = 0;

INSERT INTO profile_vectors
    (user_id, embedding, tags, city, availability, energy, indoor, alcohol_ok)
SELECT
    generateUUIDv4(),
    a.embedding,
    a.tags,
    ['SF', 'Oakland', 'Berkeley', 'Daly City'][(rand(num.number) % 4) + 1],
    [['fri_eve'], ['fri_eve', 'sat_eve'], ['sat_day', 'sat_eve'],
     ['fri_eve', 'sat_day', 'sun_day'], ['sat_eve']][(rand(num.number + 1) % 5) + 1],
    a.energy,
    (rand(num.number + 2) % 2) = 0,
    (rand(num.number + 3) % 4) > 0
FROM numbers(1000000) AS num
INNER JOIN archetypes AS a ON a.id = (num.number % (SELECT count() FROM archetypes))
WHERE (SELECT count() FROM profile_vectors) = 0;

-- Demo events are cumulative by one stable per-user score: somebody shown as sharing a number
-- necessarily also RSVP'd and attended. Independent random filters produce impossible funnels
-- that look impressive in a chart but collapse as soon as a judge follows one user journey.
INSERT INTO events (ts, user_id, group_id, name, props)
WITH
    number AS demo_ordinal,
    cityHash64(concat('show-up-demo-score-', toString(demo_ordinal))) % 100 AS journey_score,
    hex(MD5(concat('show-up-demo-user-', toString(demo_ordinal)))) AS user_hash,
    hex(MD5(concat('show-up-demo-group-', toString(intDiv(demo_ordinal, 5))))) AS group_hash,
    toUUID(concat(
        substring(user_hash, 1, 8), '-', substring(user_hash, 9, 4), '-',
        substring(user_hash, 13, 4), '-', substring(user_hash, 17, 4), '-',
        substring(user_hash, 21, 12)
    )) AS demo_user_id,
    toUUID(concat(
        substring(group_hash, 1, 8), '-', substring(group_hash, 9, 4), '-',
        substring(group_hash, 13, 4), '-', substring(group_hash, 17, 4), '-',
        substring(group_hash, 21, 12)
    )) AS demo_group_id,
    now64(3) - toIntervalMinute(demo_ordinal % (14 * 24 * 60)) AS journey_started_at,
    arrayJoin([
        tuple('group_formed', 0, 100),
        tuple('notif_sent', 30, 100),
        tuple('notif_opened', 90, 88),
        tuple('rsvp', 180, 76),
        tuple('attended', 360, 61),
        tuple('answered', 720, 52),
        tuple('number_shared', 900, 39)
    ]) AS stage
SELECT
    journey_started_at + toIntervalSecond(stage.2),
    demo_user_id,
    demo_group_id,
    stage.1,
    toJSONString(map(
        'demo_seed', 'true',
        'seed_distance', toString(round(0.03 + ((demo_ordinal % 40) / 1000), 3))
    ))
FROM numbers(12000)
WHERE journey_score < stage.3
  -- The marker keeps this script safe to retry even though events is an append-only fact table.
  -- UUID determinism alone cannot prevent duplicate facts because the table has no unique key.
  AND NOT EXISTS (
      SELECT 1
      FROM events
      WHERE JSONExtractString(props, 'demo_seed') = 'true'
      LIMIT 1
  );

SELECT
    (SELECT count() FROM archetypes) AS archetypes,
    (SELECT count() FROM profile_vectors) AS profiles,
    (SELECT count() FROM events WHERE JSONExtractString(props, 'demo_seed') = 'true') AS demo_events;

-- Plain views keep the judge-facing numbers inspectable from the ClickHouse table browser while
-- leaving the append-only facts as the only stored copy. Materializing 12k-user demo aggregates
-- would save milliseconds but create another refresh lifecycle during the tightest release path.
CREATE OR REPLACE VIEW demo_funnel_summary AS
SELECT
    indexOf(
        ['group_formed', 'notif_sent', 'notif_opened', 'rsvp', 'attended', 'answered', 'number_shared'],
        name
    ) AS stage_order,
    name AS stage,
    uniqExact(user_id) AS users,
    round(users * 100.0 / max(users) OVER (), 1) AS conversion_percent
FROM events
WHERE JSONExtractString(props, 'demo_seed') = 'true'
GROUP BY name;

CREATE OR REPLACE VIEW demo_daily_activity AS
SELECT
    toDate(ts) AS day,
    uniqExact(user_id) AS active_users,
    count() AS events,
    uniqExact(group_id) AS active_groups
FROM events
WHERE JSONExtractString(props, 'demo_seed') = 'true'
GROUP BY day
ORDER BY day;

CREATE OR REPLACE VIEW demo_profile_segments AS
SELECT
    city,
    energy,
    count() AS profiles,
    round(avg(toUInt8(indoor)) * 100, 1) AS indoor_percent,
    round(avg(toUInt8(alcohol_ok)) * 100, 1) AS alcohol_ok_percent
FROM profile_vectors
GROUP BY city, energy
ORDER BY city, energy;
