// The entire ClickHouse client. No driver -- ClickHouse's HTTP interface takes raw SQL
// in the POST body and hands back one JSON object per line.
//
// This lives server-side and nowhere else. ClickHouse accepts arbitrary SQL over this
// interface and has no per-row permissions, so a credential that reached the phone would
// hand whoever extracted it the entire user table.

interface ClickHouseConfig {
  url: string;
  user: string;
  password: string;
}

/** Resolve credentials without making module import depend on external infrastructure. */
export function resolveClickHouseConfig(
  get: (key: string) => string | undefined,
): ClickHouseConfig {
  // Fail loudly at first USE rather than letting `undefined` reach fetch() -- a missing secret
  // otherwise surfaces as "Invalid URL: undefined/?default_format=JSON", which points nowhere
  // near the actual problem. This must not run at module import: operator-only functions import
  // this client before Deno.serve, and an eager throw prevents their service-role check from ever
  // returning 403. Authentication is a local boundary and must not depend on ClickHouse being up.
  const need = (key: string): string => {
    const value = get(key);
    if (!value) {
      throw new Error(
        `missing secret ${key} -- run: supabase secrets set --env-file .env.functions`,
      );
    }
    return value;
  };

  return {
    url: need("CLICKHOUSE_URL"), // https://xxx.clickhouse.cloud:8443
    user: need("CLICKHOUSE_USER"),
    password: need("CLICKHOUSE_PASSWORD"),
  };
}

let config: ClickHouseConfig | undefined;

function clickHouseConfig(): ClickHouseConfig {
  // Cache only a complete configuration. If an operator repairs a missing secret and Supabase
  // reuses the worker, a previous failed lookup must not poison that worker with partial state.
  return config ??= resolveClickHouseConfig((key) => Deno.env.get(key));
}

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
  const credentials = clickHouseConfig();
  const qs = new URLSearchParams({ default_format: "JSON" });
  for (const [k, v] of Object.entries(params)) qs.set(`param_${k}`, String(v));

  const res = await fetch(`${credentials.url}/?${qs}`, {
    method: "POST",
    headers: {
      "X-ClickHouse-User": credentials.user,
      "X-ClickHouse-Key": credentials.password,
    },
    body: sql,
  });

  const text = await res.text();
  if (!res.ok) throw new Error(`clickhouse ${res.status}: ${text}`);

  // A bare INSERT returns an empty body rather than a JSON envelope.
  if (!text.trim()) {
    return { rows: [], stats: { elapsed: 0, rows_read: 0, bytes_read: 0 } };
  }

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
  typeof x === "number"
    ? String(x)
    : `'${x.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
export const arr = (xs: readonly (string | number)[]) =>
  `[${xs.map(lit).join(",")}]`;

/**
 * Nested arrays, for Array(Array(Float32)) -- the venue query scores one venue against every
 * member in a single pass, so it passes all six member vectors as one parameter. arr() only
 * flattens one level, which fails as a ClickHouse parse error rather than a type error.
 */
export const arr2 = (xss: readonly (readonly number[])[]) =>
  `[${xss.map((xs) => arr(xs)).join(",")}]`;

/**
 * Population centroids, cached per function instance -- they change only on reseed.
 *
 * There are two, and using the wrong one is the most expensive silent bug in this system.
 * id=1 is the mean of profile text, id=2 the mean of venue text. They are different domains
 * with different means: centring venues on the profile mean leaves every venue carrying the
 * same domain-gap offset, which makes one venue win for every group. See docs/VENUE_PIPELINE
 * section 3.5.
 */
export const PROFILE_CENTROID = 1;
export const VENUE_CENTROID = 2;

const meanCache = new Map<number, number[]>();
export async function populationMean(
  id: number = PROFILE_CENTROID,
): Promise<number[]> {
  const hit = meanCache.get(id);
  if (hit) return hit;
  const { rows } = await ch<{ mean: number[] }>(
    "SELECT mean FROM embedding_mean WHERE id = {id:UInt8} LIMIT 1",
    { id },
  );
  if (!rows.length) {
    throw new Error(
      id === VENUE_CENTROID
        ? "venue centroid missing -- run scripts/ingest_venues.py"
        : "embedding_mean is empty -- run clickhouse/002_seed.sql",
    );
  }
  meanCache.set(id, rows[0].mean);
  return rows[0].mean;
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
      group_id: groupId ?? "00000000-0000-0000-0000-000000000000",
      name,
      props: JSON.stringify(props),
    },
  );
}
