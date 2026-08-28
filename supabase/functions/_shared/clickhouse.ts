// The entire ClickHouse client. No driver -- ClickHouse's HTTP interface takes raw SQL
// in the POST body and hands back one JSON object per line.
//
// This lives server-side and nowhere else. ClickHouse accepts arbitrary SQL over this
// interface and has no per-row permissions, so a credential that reached the phone would
// hand whoever extracted it the entire user table.

// Fail loudly at first use rather than letting `undefined` reach fetch() -- a missing
// secret otherwise surfaces as "Invalid URL: undefined/?default_format=JSON", which
// points nowhere near the actual problem.
function need(key: string): string {
  const v = Deno.env.get(key);
  if (!v) throw new Error(`missing secret ${key} -- run: supabase secrets set --env-file .env.functions`);
  return v;
}

const URL_ = need('CLICKHOUSE_URL');   // https://xxx.clickhouse.cloud:8443
const USER = need('CLICKHOUSE_USER');
const PASS = need('CLICKHOUSE_PASSWORD');

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

/**
 * ClickHouse substitutes param_* by running the target type's *quoted-text* deserializer
 * over the value, which for Array(String) requires SQL single quotes. JSON.stringify
 * produces double quotes and the query fails to parse -- so build the literal by hand.
 * Numeric arrays are unaffected either way, but go through the same path for consistency.
 */
const lit = (x: string | number) =>
  typeof x === 'number' ? String(x) : `'${x.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
export const arr = (xs: readonly (string | number)[]) => `[${xs.map(lit).join(',')}]`;

/** The population centroid, cached per function instance -- it changes only on reseed. */
let meanCache: number[] | null = null;
export async function populationMean(): Promise<number[]> {
  if (meanCache) return meanCache;
  const { rows } = await ch<{ mean: number[] }>('SELECT mean FROM embedding_mean LIMIT 1');
  if (!rows.length) throw new Error('embedding_mean is empty -- run clickhouse/002_seed.sql');
  meanCache = rows[0].mean;
  return meanCache;
}

/**
 * async_insert batches single-row inserts server-side. One HTTP INSERT per event is the
 * thing ClickHouse engineers tell people not to do -- this turns a criticism into a
 * design decision, and we do not need the write acknowledged before continuing.
 */
export async function emit(
  name: string,
  userId: string,
  groupId: string | null,
  props: Record<string, unknown> = {},
) {
  await ch(
    `INSERT INTO events (user_id, group_id, name, props)
     SETTINGS async_insert = 1, wait_for_async_insert = 0
     VALUES ({user_id:UUID}, {group_id:UUID}, {name:String}, {props:String})`,
    {
      user_id: userId,
      group_id: groupId ?? '00000000-0000-0000-0000-000000000000',
      name,
      props: JSON.stringify(props),
    },
  );
}
