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
             + (((rand(num.number * 256 + i) % 2000) / 1000.0) - 1.0) * 0.3,
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
CROSS JOIN (SELECT mean FROM embedding_mean LIMIT 1) AS m;

-- Sanity check. If distances here are all bunched between ~0.84 and ~0.87 the centering
-- did not take effect and every match downstream will be noise.
SELECT
    count()                    AS profiles,
    length(any(embedding))     AS dims,
    round(min(d), 4)           AS nearest,
    round(max(d), 4)           AS farthest
FROM
(
    SELECT embedding, cosineDistance(embedding, (SELECT embedding FROM profile_vectors LIMIT 1)) AS d
    FROM profile_vectors
    LIMIT 50000
);
