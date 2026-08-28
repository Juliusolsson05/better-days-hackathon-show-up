// ClickHouse query contracts used by the judge-facing dashboard.
//
// Keeping the non-trivial aggregation here makes its meaning testable without importing an
// Edge Function entrypoint (which would start Deno.serve) or requiring a live ClickHouse corpus.

/** Number of formed groups in each match-distance bucket. */
export const COHESION_QUERY = `
  SELECT round(JSONExtractFloat(props, 'seed_distance'), 1) AS bucket,
         uniqExact(group_id) AS n
  FROM events
  WHERE name = 'group_formed'
  GROUP BY bucket
  ORDER BY bucket
`;
