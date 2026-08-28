-- The demo query. Full scan over the whole population, no vector index.
--
-- Brute force is a deliberate choice, not a shortcut: at this row count it returns in
-- tens of milliseconds, it removes an index to misconfigure under time pressure, and
-- "no index, full scan, 47ms" is a better thing to say on stage than a tuned HNSW.
--
-- Parameters are passed as param_* on the query string -- never interpolated. The
-- embedding and tags originate in user input and ClickHouse will run whatever SQL it
-- is handed.
--
-- FORMAT JSON is what makes the demo: the response carries a statistics block with
-- elapsed / rows_read, which is the number that goes on screen under the group reveal.

SELECT
    user_id,
    cosineDistance(embedding, {vec:Array(Float32)}) AS d,
    tags,
    energy,
    indoor
FROM profile_vectors
WHERE city = {city:String}
  AND hasAny(availability, {avail:Array(String)})
  AND alcohol_ok = {alcohol_ok:Bool}
  AND user_id != {self:UUID}
ORDER BY d ASC
LIMIT 40
FORMAT JSON;
