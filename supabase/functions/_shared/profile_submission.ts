/**
 * The public request contract for submit-profile.
 *
 * Flutter validation is only a usability aid: a caller can invoke an Edge Function without
 * running the app at all. Keeping this parser dependency-free gives the protocol one cheap,
 * deterministic boundary before an invalid request can create a partial Postgres profile or
 * spend money on Voyage and Claude.
 */
export interface ProfileSubmission {
  display_name: string;
  avatar: string;
  passion: string;
  tags: string[];
  city: string;
  availability: string[];
  phone: string;
  photo_url: string;
}

export class ProfileSubmissionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProfileSubmissionError";
  }
}

const E164 = /^\+[1-9][0-9]{7,14}$/;
const AVAILABILITY_SLOTS = new Set([
  "fri_eve",
  "sat_day",
  "sat_eve",
  "sun_day",
]);

function invalid(field: string, reason: string): never {
  // Error messages intentionally name the field and rule, never the submitted value. Edge
  // Function responses are visible to untrusted callers, so echoing arbitrary input would turn
  // validation into a reflected-data/log-injection surface.
  throw new ProfileSubmissionError(`invalid ${field}: ${reason}`);
}

function record(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    invalid("body", "expected a JSON object");
  }
  return value as Record<string, unknown>;
}

function text(
  body: Record<string, unknown>,
  field: string,
  options: { min?: number; max: number },
): string {
  const value = body[field];
  if (typeof value !== "string") invalid(field, "expected a string");

  const normalized = value.trim();
  const min = options.min ?? 1;
  if (normalized.length < min || normalized.length > options.max) {
    invalid(field, `expected ${min}-${options.max} characters`);
  }
  return normalized;
}

function stringList(
  body: Record<string, unknown>,
  field: string,
  options: { maxItems: number; maxItemLength: number },
): string[] {
  const value = body[field];
  if (!Array.isArray(value)) invalid(field, "expected an array");
  if (value.length === 0 || value.length > options.maxItems) {
    invalid(field, `expected 1-${options.maxItems} items`);
  }

  const normalized = value.map((item) => {
    if (typeof item !== "string") invalid(field, "expected string items");
    const candidate = item.trim();
    if (candidate.length === 0 || candidate.length > options.maxItemLength) {
      invalid(
        field,
        `expected items of 1-${options.maxItemLength} characters`,
      );
    }
    return candidate;
  });

  // Duplicate interests add weight accidentally when profileText joins the array, while
  // duplicate availability does not add real availability. Rejecting them keeps both the
  // stored OLTP profile and the generated embedding semantically stable.
  if (new Set(normalized).size !== normalized.length) {
    invalid(field, "duplicate items are not allowed");
  }
  return normalized;
}

export function parseProfileSubmission(input: unknown): ProfileSubmission {
  const body = record(input);
  const tags = stringList(body, "tags", {
    maxItems: 20,
    maxItemLength: 24,
  });
  const availability = stringList(body, "availability", {
    maxItems: AVAILABILITY_SLOTS.size,
    maxItemLength: 16,
  });

  for (const slot of availability) {
    // Matching uses exact availability tokens. Accepting a plausible-looking typo here would
    // create a valid profile that can never enter a matching pool, which is worse than a clear
    // request error at onboarding time.
    if (!AVAILABILITY_SLOTS.has(slot)) {
      invalid("availability", "contains an unsupported slot");
    }
  }

  const phone = text(body, "phone", { max: 16 });
  if (!E164.test(phone)) {
    invalid("phone", "expected E.164 format");
  }

  return {
    display_name: text(body, "display_name", { max: 40 }),
    // Emoji sequences may contain several UTF-16 code units. This cap is deliberately roomier
    // than the one visible glyph the current picker emits so valid joined emoji do not fail at
    // the API boundary, while still preventing this fallback field becoming arbitrary prose.
    avatar: text(body, "avatar", { max: 32 }),
    passion: text(body, "passion", { min: 11, max: 280 }),
    tags,
    city: text(body, "city", { max: 80 }),
    availability,
    phone,
    // The parser establishes that a path exists; ownership is checked separately once auth has
    // supplied the trusted user id. A client-provided id must never participate in that check.
    photo_url: text(body, "photo_url", { max: 200 }),
  };
}

export function assertOwnedProfilePhotoPath(
  photoPath: string,
  authenticatedUserId: string,
): void {
  // Storage policies also enforce ownership, but the profile row persists the path used later
  // to mint signed URLs. Exact equality prevents a modified client from pointing groupmates at
  // another object it happens to be allowed to read, or at a traversal/public URL shape that the
  // signing code cannot safely interpret.
  if (photoPath !== `${authenticatedUserId}/profile.jpg`) {
    invalid("photo_url", "expected the authenticated user profile path");
  }
}
