// Runtime contract for the client-to-ClickHouse event seam.
//
// TypeScript describes calls authored in this repository, but `track` is an HTTP endpoint and
// receives untyped JSON from old clients, modified clients, and curl. Keep the validation pure so
// malformed traffic can be proven without importing an entrypoint that starts Deno.serve.

export interface TrackingEvent {
  name: string;
  group_id?: string | null;
  props: Record<string, unknown>;
}

export class TrackingRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TrackingRequestError";
  }
}

const ALLOWED = new Set([
  "notif_opened",
  "rsvp",
  "chat_opened",
  "chat_first_message",
  "venue_voted",
  "attended",
  "answered",
  "number_shared",
]);

// These names claim that an authoritative product row exists. The track edge function must read
// that row back with its server credential before emitting anything; membership validation alone
// would still let a modified phone manufacture conversion facts about its real group.
const DURABLE_FACTS = new Set([
  "rsvp",
  "chat_first_message",
  "venue_voted",
  "attended",
  "answered",
  "number_shared",
]);

export const isDurableFactName = (name: string): boolean =>
  DURABLE_FACTS.has(name);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BATCH = 20;
const MAX_NAME_LENGTH = 64;
const MAX_PROPS_JSON_LENGTH = 4096;

function record(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TrackingRequestError(`${label} must be a JSON object`);
  }
  return value as Record<string, unknown>;
}

function event(value: unknown): TrackingEvent {
  const raw = record(value, "event");
  if (
    typeof raw.name !== "string" || raw.name.length === 0 ||
    raw.name.length > MAX_NAME_LENGTH
  ) {
    // Unknown but well-shaped names are handled as partial batch rejections below. A non-string
    // or unbounded value is a malformed protocol message and must not be reflected into the
    // response, logs, or ClickHouse query parameters.
    throw new TrackingRequestError(
      `event name must be 1-${MAX_NAME_LENGTH} characters`,
    );
  }

  const groupId = raw.group_id;
  if (
    groupId !== undefined && groupId !== null &&
    (typeof groupId !== "string" || !UUID.test(groupId))
  ) {
    throw new TrackingRequestError("event group_id must be a UUID or null");
  }

  const props = raw.props === undefined ? {} : record(raw.props, "event props");
  // Props remain open-ended because each funnel stage has different metadata, but open-ended
  // cannot mean unbounded. This endpoint is reachable by every authenticated user and every byte
  // becomes a ClickHouse parameter; a small cap keeps one analytics append from becoming a cheap
  // memory/request-amplification path without constraining any current Flutter event.
  if (JSON.stringify(props).length > MAX_PROPS_JSON_LENGTH) {
    throw new TrackingRequestError(
      `event props must be at most ${MAX_PROPS_JSON_LENGTH} JSON characters`,
    );
  }

  return {
    name: raw.name,
    group_id: groupId as string | null | undefined,
    props,
  };
}

export function parseTrackingRequest(input: unknown): {
  accepted: TrackingEvent[];
  rejected: string[];
} {
  const body = record(input, "body");
  let incoming: unknown[];

  if ("events" in body) {
    // The old cast let a string reach `.filter()`, turning a caller error into a 500 after auth.
    // Presence, rather than nullish coalescing, is intentional: `{events:null,name:"rsvp"}` is an
    // ambiguous malformed batch, not permission to silently reinterpret it as the single form.
    if (!Array.isArray(body.events)) {
      throw new TrackingRequestError("events must be an array");
    }
    incoming = body.events;
  } else if ("name" in body) {
    incoming = [{
      name: body.name,
      group_id: body.group_id,
      props: body.props,
    }];
  } else {
    throw new TrackingRequestError("request must contain name or events");
  }

  if (incoming.length === 0) {
    throw new TrackingRequestError("request must contain at least one event");
  }
  if (incoming.length > MAX_BATCH) {
    throw new TrackingRequestError(
      `request may contain at most ${MAX_BATCH} events`,
    );
  }

  const parsed = incoming.map(event);
  return {
    accepted: parsed.filter((item) => ALLOWED.has(item.name)),
    // Preserve the existing forward-compatibility behavior: one name introduced by a newer app
    // does not discard the valid events beside it. Only structural corruption rejects the batch.
    rejected: parsed.filter((item) => !ALLOWED.has(item.name)).map((item) =>
      item.name
    ),
  };
}
