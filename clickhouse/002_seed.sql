-- Generates the synthetic population. Run AFTER scripts/seed_archetypes.py has filled
-- the archetypes table, otherwise this inserts nothing.
--
-- Why synthetic-around-real instead of pure random: uniformly random vectors are spread
-- evenly over the sphere, which makes "nearest neighbour" meaningless -- the matches
-- would be arbitrary and would not survive a judge asking why two people were grouped.
-- Clustering around ~200 genuinely embedded bios gives a million rows whose neighbours
-- are actually semantically related, for 200 API calls instead of a million.

-- Population centroid. Taken from the archetypes rather than from profile_vectors
-- because the synthetic profiles are archetype + zero-mean noise, so the two centroids
-- agree -- and this way the seed is a single pass instead of insert-then-rewrite.
TRUNCATE TABLE IF EXISTS embedding_mean;
INSERT INTO embedding_mean (mean, n)
SELECT CAST(avgForEach(embedding) AS Array(Float32)), count()
FROM archetypes;

TRUNCATE TABLE IF EXISTS profile_vectors;

INSERT INTO profile_vectors
    (user_id, embedding, tags, city, availability, energy, indoor, alcohol_ok)
SELECT
    generateUUIDv4(),
    -- Centered archetype + jitter. rand() is seeded with (row * 256 + i) so it varies
    -- per element AND per row; a bare rand() inside a lambda gets folded to one value.
    arrayMap(
        i -> (a.embedding[i + 1] - m.mean[i + 1])
             + (((rand(num.number * 256 + i) % 2000) / 1000.0) - 1.0) * 0.05,
        range(256)
    ),
    a.tags,
    ['SF', 'Oakland', 'Berkeley', 'Daly City'][(rand(num.number) % 4) + 1],
    -- Picked from whole combinations rather than filtered at random so nobody ends up
    -- with an empty availability array and silently unmatchable.
    [['fri_eve'], ['fri_eve', 'sat_eve'], ['sat_day', 'sat_eve'],
     ['fri_eve', 'sat_day', 'sun_day'], ['sat_eve']][(rand(num.number + 1) % 5) + 1],
    a.energy,
    (rand(num.number + 2) % 2) = 0,
    (rand(num.number + 3) % 4) > 0
FROM numbers(1000000) AS num
INNER JOIN archetypes AS a ON a.id = (num.number % (SELECT count() FROM archetypes))
CROSS JOIN (SELECT mean FROM embedding_mean LIMIT 1) AS m
SETTINGS select_sequential_consistency = 1;

-- Semantic sanity check. A distance-spread check is useless here: noise CREATES spread,
-- so an over-jittered population passes it while being pure noise. The only thing worth
-- asserting is that a profile's nearest neighbours came from its own archetype.
--
-- Want share_same_archetype close to 1.0. Below ~0.8 means the jitter is drowning the
-- signal and every match downstream is a random number generator.
SELECT
    count()                                  AS profiles,
    length(any(embedding))                   AS dims,
    round(avgIf(same, rn <= 10), 3)          AS share_same_archetype
FROM
(
    SELECT
        row_number() OVER (ORDER BY cosineDistance(p.embedding, r.embedding) ASC) AS rn,
        p.tags = r.tags AS same
    FROM profile_vectors AS p
    CROSS JOIN (SELECT embedding, tags FROM profile_vectors LIMIT 1) AS r
    LIMIT 50000
)
WHERE rn > 1;
