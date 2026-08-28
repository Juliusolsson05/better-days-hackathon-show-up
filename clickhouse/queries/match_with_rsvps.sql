-- The "OLAP and OLTP, like PB&J" query: live Postgres rows joined straight into the
-- ClickHouse scan, in one statement.
--
-- Caveat worth saying out loud when demoing this -- postgresql() pulls the ENTIRE remote
-- table on every call. Correct for rsvps (hundreds of rows this week), wrong for anything
-- large. In production this is ClickPipes CDC instead.

SELECT
    p.user_id,
    cosineDistance(p.embedding, {vec:Array(Float32)}) AS d,
    p.tags,
    p.energy
FROM profile_vectors AS p
INNER JOIN postgresql(
    {pg_host:String},      -- db.<ref>.supabase.co:5432
    {pg_db:String},
    'rsvps',
    {pg_user:String},
    {pg_pass:String}
) AS r ON r.user_id = p.user_id
WHERE r.status = 'confirmed'
  AND p.city = {city:String}
ORDER BY d ASC
LIMIT 40
FORMAT JSON;
