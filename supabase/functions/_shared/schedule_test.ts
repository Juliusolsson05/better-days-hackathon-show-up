import { assertEquals, assertThrows } from 'jsr:@std/assert@1.0.14';
import { nextSlot } from './schedule.ts';

Deno.test('keeps Friday evening at 7pm during Pacific daylight time', () => {
  assertEquals(
    nextSlot('fri_eve', new Date('2026-08-28T20:00:00Z')),
    '2026-08-29T02:00:00.000Z',
  );
});

Deno.test('keeps Friday evening at 7pm during Pacific standard time', () => {
  assertEquals(
    nextSlot('fri_eve', new Date('2026-12-04T20:00:00Z')),
    '2026-12-05T03:00:00.000Z',
  );
});

Deno.test('uses the following week once this local slot has passed', () => {
  assertEquals(
    nextSlot('fri_eve', new Date('2026-08-29T03:00:00Z')),
    '2026-09-05T02:00:00.000Z',
  );
});

Deno.test('rejects a schedule name the product does not understand', () => {
  assertThrows(() => nextSlot('monday_lunch'), Error, 'unknown availability slot');
});
