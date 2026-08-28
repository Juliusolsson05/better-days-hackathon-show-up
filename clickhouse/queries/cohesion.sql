-- Show-up and number-share rate sliced by how tightly matched the group was.
--
-- The actual research question behind the product: does putting people who are MORE
-- alike together produce better outcomes, or is some spread better? Nobody can answer
-- this without the event stream, which is the argument for the OLAP half.

SELECT
    distance_bucket,
    count()                                          AS groups,
    round(avg(attended_frac), 3)                     AS show_up_rate,
    round(avg(shared_frac), 3)                       AS number_share_rate
FROM
(
    SELECT
        group_id,
        -- avg pairwise distance within the group, bucketed into deciles at write time
        -- by run-matching and stashed in props
        floor(anyIf(JSONExtractFloat(props, 'seed_distance'), name = 'group_formed') * 10) / 10 AS distance_bucket,
        countIf(name = 'attended')      / 6.0 AS attended_frac,
        countIf(name = 'number_shared') / 6.0 AS shared_frac
    FROM events
    WHERE group_id != toUUID('00000000-0000-0000-0000-000000000000')
    GROUP BY group_id
)
GROUP BY distance_bucket
ORDER BY distance_bucket;
