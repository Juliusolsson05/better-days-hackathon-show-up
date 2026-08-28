// The opening line is the first thing anybody reads in this product's main surface, and
// it is assembled from user-supplied tags. Every rule below is one that produced a wrong
// or embarrassing line when it was missing.
//
// Run: deno test supabase/functions/_shared/chat_test.ts

import { assertEquals, assertStringIncludes, assertThrows } from 'jsr:@std/assert@1';
import { openingLine, parseOpenChatRequest, type ChatMember } from './chat.ts';

const m = (id: string, ...tags: string[]): ChatMember =>
  ({ id, display_name: id, tags });

Deno.test('names the tags at least two people share', () => {
  const line = openingLine([
    m('a', 'climbing', 'music'),
    m('b', 'climbing', 'music'),
    m('c', 'pottery'),
    m('d', 'climbing'),
  ]);
  assertStringIncludes(line, 'climbing');
  assertStringIncludes(line, 'music');
  // Held by exactly one person: not a shared interest, and naming it singles them out.
  assertEquals(line.includes('pottery'), false);
});

Deno.test('counts the group, in words', () => {
  const six = [1, 2, 3, 4, 5, 6].map((i) => m(`u${i}`, 'climbing'));
  assertStringIncludes(openingLine(six), 'Six of you');
  assertStringIncludes(openingLine(six.slice(0, 4)), 'Four of you');
});

Deno.test('never leaks a stance tag into the room', () => {
  // stance: tags exist to keep opposed people out of the same group. They are a matching
  // mechanism, not an interest, and surfacing one discloses something to five strangers
  // that the user only ever gave us for filtering.
  const line = openingLine([
    m('a', 'stance:vegan', 'food'),
    m('b', 'stance:vegan', 'food'),
  ]);
  assertEquals(line.includes('stance'), false);
  assertEquals(line.includes('vegan'), false);
  assertStringIncludes(line, 'food');
});

Deno.test('caps at three interests so the line survives a lock screen', () => {
  const tags = ['climbing', 'music', 'food', 'films', 'books'];
  const line = openingLine([m('a', ...tags), m('b', ...tags)]);
  // Two separators means three items.
  assertEquals((line.match(/,/g) ?? []).length, 1);
  assertEquals((line.match(/ and /g) ?? []).length, 1);
});

Deno.test('falls back cleanly when nothing is shared', () => {
  // A real case: groups are assembled from embedding proximity, which does not guarantee
  // any two people wrote the same literal tag. The bug this guards is a line that ends
  // "you matched on" followed by nothing.
  const line = openingLine([m('a', 'kayaking'), m('b', 'origami')]);
  assertEquals(line.includes('matched on'), false);
  assertStringIncludes(line, 'Two of you');
});

Deno.test('one person listing a tag twice does not make it shared', () => {
  const line = openingLine([m('a', 'chess', 'chess'), m('b', 'baking')]);
  assertEquals(line.includes('chess'), false);
});

Deno.test('malformed open-chat requests cannot fall through to the bulk backfill path', () => {
  // The entrypoint used to map malformed JSON to {}, whose API meaning is "every group". The
  // parser cannot observe JSON syntax, but it owns the second boundary: scalars and invalid ids
  // fail before a service-role query can be selected.
  assertThrows(() => parseOpenChatRequest(null), Error, 'JSON object');
  assertThrows(() => parseOpenChatRequest([]), Error, 'JSON object');
  assertThrows(
    () => parseOpenChatRequest({ group_id: 'not-a-uuid' }),
    Error,
    'group_id must be a UUID',
  );
  assertEquals(parseOpenChatRequest({}), { groupId: null });
  assertEquals(
    parseOpenChatRequest({ group_id: '00000000-0000-4000-8000-000000000001' }),
    { groupId: '00000000-0000-4000-8000-000000000001' },
  );
});
