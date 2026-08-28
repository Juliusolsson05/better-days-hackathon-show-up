-- The closing slide. windowFunnel walks each user through the product in order and
-- reports how far they got, within a 7-day window.
--
-- This is the query that turns "we built an app" into "we can tell you which matching
-- strategy produces friendship" -- level 4 is the only outcome the product actually
-- cares about.

SELECT
    level,
    count() AS people
FROM
(
    SELECT
        user_id,
        windowFunnel(604800)(
            ts,
            name = 'notif_sent',
            name = 'rsvp',
            name = 'attended',
            name = 'number_shared'
        ) AS level
    FROM events
    WHERE ts > now() - INTERVAL 30 DAY
    GROUP BY user_id
)
GROUP BY level
ORDER BY level;
