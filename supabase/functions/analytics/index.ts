// Feeds the judge-facing dashboard. Reads only ClickHouse -- this is the OLAP half
// earning its place: none of these questions can be answered from Postgres without a
// table scan per slice.

import { ch } from '../_shared/clickhouse.ts';

// A browser dashboard fails preflight without these.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const [funnel, cohesion, volume] = await Promise.all([
      ch(`SELECT level, count() AS people FROM (
            SELECT user_id, windowFunnel(604800)(toDateTime(ts),
              name = 'notif_sent', name = 'rsvp', name = 'attended', name = 'number_shared'
            ) AS level
            FROM events WHERE ts > now() - INTERVAL 30 DAY GROUP BY user_id
          ) GROUP BY level ORDER BY level`),
      ch(`SELECT round(JSONExtractFloat(props, 'seed_distance'), 1) AS bucket, count() AS n
          FROM events WHERE name = 'group_formed'
          GROUP BY bucket ORDER BY bucket`),
      ch(`SELECT name, count() AS n FROM events
          WHERE ts > now() - INTERVAL 7 DAY GROUP BY name ORDER BY n DESC`),
    ]);

    return Response.json({
      funnel: funnel.rows,
      cohesion: cohesion.rows,
      volume: volume.rows,
      scanned: funnel.stats,
    }, { headers: CORS });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500, headers: CORS });
  }
});
