// Unit tests for the pure parts of the venue pipeline.
//
//   deno test --allow-env supabase/functions/_shared/venues_test.ts
//
// clickhouse.ts reads its secrets at module load and throws when they are missing, so the
// env is populated before the dynamic imports below. Everything tested here is pure -- no
// network, no ClickHouse -- which is the point: these are the two functions whose failure
// modes are silent rather than loud.

import { assertEquals, assertThrows } from 'jsr:@std/assert@1';

for (const k of ['CLICKHOUSE_URL', 'CLICKHOUSE_USER', 'CLICKHOUSE_PASSWORD']) {
  Deno.env.set(k, 'test');
}
Deno.env.set('ANTHROPIC_API_KEY', 'test');
Deno.env.set('VOYAGE_API_KEY', 'test');

const { arr, arr2 } = await import('./clickhouse.ts');
const { diversify, validateVenuePitches } = await import('./venues.ts');

Deno.test('arr quotes strings and leaves numbers bare', () => {
  // ClickHouse parses Array(String) params with the quoted-text deserializer, which needs
  // SQL single quotes. JSON.stringify would emit double quotes and fail to parse.
  assertEquals(arr(['fri_eve', 'sat_day']), "['fri_eve','sat_day']");
  assertEquals(arr([1, 2.5]), '[1,2.5]');
  assertEquals(arr(["it's"]), "['it\\'s']");
});

Deno.test('arr2 nests one level deeper for Array(Array(Float32))', () => {
  // The venue query passes every member vector as one parameter. arr() only flattens one
  // level, so using it here produces a ClickHouse parse error rather than a type error.
  assertEquals(arr2([[1, 2], [3, 4]]), '[[1,2],[3,4]]');
  assertEquals(arr2([]), '[]');
  assertEquals(arr2([[]]), '[[]]');
});

const v = (id: string, kind: string, score: number) => ({
  venue_id: id,
  name: id,
  taxonomy_primary: kind,
  address: '',
  locality: 'San Francisco',
  lat: 0,
  lng: 0,
  score,
  s: [score],
});

Deno.test('diversify returns different KINDS of place, not just the top n', () => {
  // Three cocktail bars is not a decision, and a vote between them is theatre. This is the
  // whole reason the step exists.
  const rows = [
    v('a', 'cocktail_bar', 0.9),
    v('b', 'cocktail_bar', 0.89),
    v('c', 'wine_bar', 0.88),
    v('d', 'climbing_gym', 0.5),
  ];
  const out = diversify(rows, 3);
  assertEquals(out.map((r) => r.venue_id), ['a', 'c', 'd']);
});

Deno.test('diversify backfills when the candidates are too homogeneous', () => {
  // A thin candidate set must still yield n options rather than silently returning fewer.
  const rows = [
    v('a', 'cocktail_bar', 0.9),
    v('b', 'cocktail_bar', 0.8),
    v('c', 'cocktail_bar', 0.7),
  ];
  const out = diversify(rows, 3);
  assertEquals(out.length, 3);
  assertEquals(out[0].venue_id, 'a');
});

Deno.test('diversify never repeats a venue', () => {
  const rows = [v('a', 'bar', 0.9), v('b', 'bar', 0.8)];
  const out = diversify(rows, 5);
  assertEquals(new Set(out.map((r) => r.venue_id)).size, out.length);
});

Deno.test('arr2 rejects nothing structurally -- length is the caller contract', () => {
  // retrieve() checks vector length against DIMS; arr2 itself is dimension-agnostic, so a
  // wrong-length vector must fail there rather than silently producing bad SQL here.
  assertEquals(arr2([[1, 2, 3]]), '[[1,2,3]]');
  assertThrows(() => JSON.parse('[[1,2'), SyntaxError);
});

Deno.test('venue copy must cover the exact retrieved candidate set before persistence', () => {
  const complete = validateVenuePitches(
    ['a', 'b'],
    [
      { venue_id: 'a', pitch: '  Good for talking.  ' },
      { venue_id: 'b', pitch: 'A shared activity.' },
    ],
  );
  assertEquals([...complete], [
    ['a', 'Good for talking.'],
    ['b', 'A shared activity.'],
  ]);

  // A parsed Claude object may still omit, duplicate, or invent ids. Every one previously
  // produced an apparently successful ballot with empty durable copy for at least one option.
  assertThrows(
    () => validateVenuePitches(['a', 'b'], [{ venue_id: 'a', pitch: 'Only one.' }]),
    Error,
    'omitted a candidate',
  );
  assertThrows(
    () => validateVenuePitches(['a'], [{ venue_id: 'invented', pitch: 'No.' }]),
    Error,
    'unknown venue id',
  );
  assertThrows(
    () => validateVenuePitches(['a'], [{ venue_id: 'a', pitch: '   ' }]),
    Error,
    'empty copy',
  );
});
