import { assertEquals, assertThrows } from "jsr:@std/assert@1";

import {
  assertOwnedProfilePhotoPath,
  parseProfileSubmission,
  ProfileSubmissionError,
} from "./profile_submission.ts";

const USER_ID = "00000000-0000-4000-8000-000000000001";

function validSubmission(): Record<string, unknown> {
  return {
    display_name: "  Jules  ",
    avatar: " 🧗 ",
    passion: "  I could talk about climbing routes all night.  ",
    tags: ["climbing", "music"],
    city: " SF ",
    availability: ["fri_eve", "sat_day"],
    phone: "+14155550123",
    photo_url: `${USER_ID}/profile.jpg`,
  };
}

Deno.test("profile submission preserves the complete client contract", () => {
  // avatar and phone are regression fields: the Flutter client sent both while the old Edge
  // Function silently discarded them, leaving every real contact exchange without a number.
  assertEquals(parseProfileSubmission(validSubmission()), {
    display_name: "Jules",
    avatar: "🧗",
    passion: "I could talk about climbing routes all night.",
    tags: ["climbing", "music"],
    city: "SF",
    availability: ["fri_eve", "sat_day"],
    phone: "+14155550123",
    photo_url: `${USER_ID}/profile.jpg`,
  });
});

Deno.test("every persisted profile field is required at the API boundary", () => {
  for (
    const field of [
      "display_name",
      "avatar",
      "passion",
      "tags",
      "city",
      "availability",
      "phone",
      "photo_url",
    ]
  ) {
    const body = validSubmission();
    delete body[field];
    assertThrows(
      () => parseProfileSubmission(body),
      ProfileSubmissionError,
      `invalid ${field}`,
    );
  }
});

Deno.test("phone must use the database E.164 contract", () => {
  for (
    const phone of [
      "4155550123",
      "+0123456789",
      "+1415 555 0123",
      "+1234567",
      "+1234567890123456",
    ]
  ) {
    const body = validSubmission();
    body.phone = phone;
    assertThrows(
      () => parseProfileSubmission(body),
      ProfileSubmissionError,
      "invalid phone",
    );
  }
});

Deno.test("matching arrays reject empty, duplicate, and unsupported values", () => {
  for (
    const patch of [
      { tags: [] },
      { tags: ["music", "music"] },
      { tags: ["music", 42] },
      { availability: [] },
      { availability: ["monday_morning"] },
      { availability: ["fri_eve", "fri_eve"] },
    ]
  ) {
    assertThrows(
      () => parseProfileSubmission({ ...validSubmission(), ...patch }),
      ProfileSubmissionError,
    );
  }
});

Deno.test("profile photo path must belong to the authenticated user", () => {
  assertOwnedProfilePhotoPath(`${USER_ID}/profile.jpg`, USER_ID);

  for (
    const path of [
      "00000000-0000-4000-8000-000000000002/profile.jpg",
      `${USER_ID}/../other.jpg`,
      `https://example.test/${USER_ID}/profile.jpg`,
      `${USER_ID}/alternate.jpg`,
    ]
  ) {
    assertThrows(
      () => assertOwnedProfilePhotoPath(path, USER_ID),
      ProfileSubmissionError,
      "invalid photo_url",
    );
  }
});

Deno.test("body must be a JSON object", () => {
  for (const input of [null, [], "profile", 42]) {
    assertThrows(
      () => parseProfileSubmission(input),
      ProfileSubmissionError,
      "invalid body",
    );
  }
});
