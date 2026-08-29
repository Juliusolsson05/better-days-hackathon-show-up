import { assertEquals, assertThrows } from "jsr:@std/assert@1";

import { isDurableFactName, parseTrackingRequest } from "./tracking.ts";

const groupId = "00000000-0000-4000-8000-000000000001";

Deno.test("tracking parser preserves the Flutter single and offline-batch contracts", () => {
  assertEquals(parseTrackingRequest({ name: "rsvp", group_id: groupId }), {
    accepted: [{ name: "rsvp", group_id: groupId, props: {} }],
    rejected: [],
  });

  assertEquals(
    parseTrackingRequest({
      events: [
        { name: "venue_voted", group_id: groupId, props: { option_id: "one" } },
        { name: "future_client_event" },
      ],
    }),
    {
      accepted: [{
        name: "venue_voted",
        group_id: groupId,
        props: { option_id: "one" },
      }],
      rejected: ["future_client_event"],
    },
  );

  assertEquals(
    parseTrackingRequest({ name: "notif_sent", group_id: groupId }),
    {
      accepted: [],
      rejected: ["notif_sent"],
    },
  );
  assertEquals(isDurableFactName("rsvp"), true);
  assertEquals(isDurableFactName("notif_opened"), false);
});

Deno.test("malformed tracking payloads fail before membership or ClickHouse work", () => {
  // Each shape previously survived the TypeScript cast and failed later as a 500 (`filter is not
  // a function`, property access on null, Postgres UUID parsing, or oversized ClickHouse input).
  assertThrows(
    () => parseTrackingRequest(null),
    Error,
    "body must be a JSON object",
  );
  assertThrows(
    () => parseTrackingRequest({ events: "rsvp" }),
    Error,
    "events must be an array",
  );
  assertThrows(
    () => parseTrackingRequest({ events: [null] }),
    Error,
    "event must be a JSON object",
  );
  assertThrows(() => parseTrackingRequest({ name: 7 }), Error, "event name");
  assertThrows(
    () => parseTrackingRequest({ name: "rsvp", group_id: "not-a-uuid" }),
    Error,
    "group_id must be a UUID",
  );
  assertThrows(
    () => parseTrackingRequest({ name: "rsvp", props: [] }),
    Error,
    "event props must be a JSON object",
  );
  assertThrows(
    () =>
      parseTrackingRequest({ name: "rsvp", props: { text: "x".repeat(4097) } }),
    Error,
    "event props must be at most",
  );
  assertThrows(
    () => parseTrackingRequest({ events: Array(21).fill({ name: "rsvp" }) }),
    Error,
    "at most 20 events",
  );
});
