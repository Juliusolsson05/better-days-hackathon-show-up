// The entire ClickHouse client. No driver -- ClickHouse's HTTP interface takes raw SQL
// in the POST body and hands back one JSON object per line.
//
// This lives server-side and nowhere else. ClickHouse accepts arbitrary SQL over this
// interface and has no per-row permissions, so a credential that reached the phone would
// hand whoever extracted it the entire user table.

const URL_ = Deno.env.get('CLICKHOUSE_URL')!;   // https://xxx.clickhouse.cloud:8443
const USER = Deno.env.get('CLICKHOUSE_USER')!;
const PASS = Deno.env.get('CLICKHOUSE_PASSWORD')!;

export interface ChResult<T> {
  rows: T[];
  /** Straight from ClickHouse -- this is what goes on screen during the demo. */
  stats: { elapsed: number; rows_read: number; bytes_read: number };
}

/**
 * Params are sent as param_* on the query string and referenced as {name:Type} in the
 * SQL. Never interpolate: the embedding and tags originate in user input.
 */
export async function ch<T = Record<string, unknown>>(
  sql: string,
  params: Record<string, string | number | boolean> = {},
): Promise<ChResult<T>> {
  const qs = new URLSearchParams({ default_format: 'JSON' });
  for (const [k, v] of Object.entries(params)) qs.set(`param_${k}`, String(v));

  const res = await fetch(`${URL_}/?${qs}`, {
    method: 'POST',
    headers: { 'X-ClickHouse-User': USER, 'X-ClickHouse-Key': PASS },
    body: sql,
  });

  const text = await res.text();
  if (!res.ok) throw new Error(`clickhouse ${res.status}: ${text}`);

  // A bare INSERT returns an empty body rather than a JSON envelope.
  if (!text.trim()) return { rows: [], stats: { elapsed: 0, rows_read: 0, bytes_read: 0 } };

  const parsed = JSON.parse(text);
  return {
    rows: parsed.data ?? [],
    stats: {
      elapsed: parsed.statistics?.elapsed ?? 0,
      rows_read: parsed.statistics?.rows_read ?? 0,
      bytes_read: parsed.statistics?.bytes_read ?? 0,
    },
  };
}

/** Arrays have to reach ClickHouse as JSON literals, not as JS arrays stringified by URLSearchParams. */
export const arr = (xs: readonly (string | number)[]) => JSON.stringify(xs);

/** The population centroid, cached per function instance -- it changes only on reseed. */
let meanCache: number[] | null = null;
export async function populationMean(): Promise<number[]> {
  if (meanCache) return meanCache;
  const { rows } = await ch<{ mean: number[] }>('SELECT mean FROM embedding_mean LIMIT 1');
  if (!rows.length) throw new Error('embedding_mean is empty -- run clickhouse/002_seed.sql');
  meanCache = rows[0].mean;
  return meanCache;
}

export async function emit(
  name: string,
  userId: string,
  groupId: string | null,
  props: Record<string, unknown> = {},
) {
  await ch(
    `INSERT INTO events (user_id, group_id, name, props)
     VALUES ({user_id:UUID}, {group_id:UUID}, {name:String}, {props:String})`,
    {
      user_id: userId,
      group_id: groupId ?? '00000000-0000-0000-0000-000000000000',
      name,
      props: JSON.stringify(props),
    },
  );
}
