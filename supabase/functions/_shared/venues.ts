// Venue retrieval: given a group's member vectors, produce 2-3 real venues to vote on.
//
// The corpus is Overture Maps (CDLA/Apache 2.0), loaded by scripts/ingest_venues.py. Yelp is
// deliberately absent -- its terms forbid storing content beyond 24 hours, building a
// natural-language retrieval system over it, and submitting any of it to a generative model,
// and the pitch call below is a generative model. See docs/VENUE_PIPELINE.md section 1.

// betaZodOutputFormat calls Zod 4's toJSONSchema at runtime. Zod 3 can look compatible to the
// TypeScript surface while turning every venue pitch request into a production-only 500.
import { z } from "npm:zod@4.1.13";
import Anthropic from "npm:@anthropic-ai/sdk@0.71.0";
// Structured output lives under `beta` in 0.71.0: betaZodOutputFormat + client.beta.messages
// .parse + `output_format` + `.parsed`. The non-beta `client.messages.parse` does not exist
// in this version and fails at runtime with "not a function", not at deploy.
import { betaZodOutputFormat } from "npm:@anthropic-ai/sdk@0.71.0/helpers/beta/zod";

import { arr2, ch, populationMean, VENUE_CENTROID } from "./clickhouse.ts";
import { center, DIMS, embed } from "./voyage.ts";

/** San Francisco. Members have no coordinates in the schema, so the anchor is the city, not
 *  a centroid of where people live. Section 3.3. */
export const CITY_CENTRE = { lat: 37.7749, lng: -122.4194 };
export const DEFAULT_RADIUS_M = 8000;

export interface VenueCandidate {
  venue_id: string;
  name: string;
  taxonomy_primary: string;
  address: string;
  locality: string;
  lat: number;
  lng: number;
  score: number;
  s: number[]; // per-member similarity, kept for explainability on stage
}

/**
 * Score every social venue in range against every member, in one pass.
 *
 * Deliberately NOT a centroid query. Averaging six members into one vector and finding its
 * nearest venue throws away who is in the group; scoring per member and combining the scores
 * keeps them. The 0.5*avg + 0.5*min blend encodes the product promise -- turn up alone, don't
 * have a bad night -- because the min term means a venue that delights four people and bores
 * two loses to one that suits all six.
 *
 * This is a blend of the Average and Least Misery strategies. It is NOT "average without
 * misery", which in the literature means averaging while excluding items below a misery
 * threshold.
 */
export async function retrieve(
  memberEmbeddings: number[][],
  opts: { lat?: number; lng?: number; radiusM?: number; limit?: number } = {},
): Promise<
  { rows: VenueCandidate[]; stats: { elapsed: number; rows_read: number } }
> {
  const { lat = CITY_CENTRE.lat, lng = CITY_CENTRE.lng } = opts;
  const radiusM = opts.radiusM ?? DEFAULT_RADIUS_M;
  const limit = opts.limit ?? 50;

  for (const m of memberEmbeddings) {
    if (m.length !== DIMS) {
      throw new Error(`member vector is ${m.length} dims, expected ${DIMS}`);
    }
  }

  const { rows, stats } = await ch<VenueCandidate>(
    `SELECT venue_id, name, taxonomy_primary, address, locality, lat, lng,
            arrayMap(m -> 1 - cosineDistance(embedding, m), {members:Array(Array(Float32))}) AS s,
            0.5 * arrayAvg(s) + 0.5 * arrayMin(s) AS score
     FROM venue_vectors
     WHERE is_social
       AND greatCircleDistance(lng, lat, {clng:Float64}, {clat:Float64}) < {radius:Float64}
     ORDER BY score DESC
     LIMIT {limit:UInt32}`,
    {
      members: arr2(memberEmbeddings),
      clng: lng,
      clat: lat,
      radius: radiusM,
      limit,
    },
  );
  return { rows, stats };
}

/**
 * Pick `n` options that are different KINDS of place, not just the top n.
 *
 * Three cocktail bars is not a decision, and a vote between them is theatre. Forcing distinct
 * taxonomies turns the vote into the question groups actually disagree on -- sit and talk, or
 * go and do something.
 */
export function diversify(rows: VenueCandidate[], n = 3): VenueCandidate[] {
  const picked: VenueCandidate[] = [];
  const seen = new Set<string>();
  for (const r of rows) {
    if (picked.length >= n) break;
    const kind = r.taxonomy_primary || "unknown";
    if (seen.has(kind)) continue;
    seen.add(kind);
    picked.push(r);
  }
  // Backfill if the candidate set was too homogeneous to yield n distinct kinds.
  for (const r of rows) {
    if (picked.length >= n) break;
    if (!picked.some((p) => p.venue_id === r.venue_id)) picked.push(r);
  }
  return picked;
}

/** Build the query vector for one member, in the venue space. */
export async function memberVectors(
  members: { passion: string; tags: string[] }[],
): Promise<number[][]> {
  const mean = await populationMean(VENUE_CENTROID);
  const raw = await embed(
    members.map((m) =>
      `Interests: ${m.tags.join(", ")}\n\nPassionate about: ${m.passion}`
    ),
  );
  return raw.map((v) => center(v, mean));
}

const VenuePitches = z.object({
  options: z.array(z.object({
    venue_id: z.string().describe(
      "Must be one of the ids provided; do not invent one",
    ),
    pitch: z.string().describe(
      "One line, max ~18 words, written for THIS group",
    ),
  })),
});

type VenuePitch = { venue_id: string; pitch: string };

/** Turn model output into the exact, complete ballot copy contract. */
export function validateVenuePitches(
  venueIds: readonly string[],
  options: readonly VenuePitch[],
): Map<string, string> {
  const expected = new Set(venueIds);
  const out = new Map<string, string>();

  for (const option of options) {
    // Structured output proves the field types, not the relationship to the candidates we sent.
    // Silently ignoring an invented id (the old behavior) also silently leaves a real option with
    // an empty pitch, which then becomes durable because replace_venue_options() correctly treats
    // the ballot as immutable after voting begins. Reject the whole proposal while the group is
    // still retryable instead of persisting a half-modelled product surface.
    if (!expected.has(option.venue_id)) {
      throw new Error("venue pitch returned an unknown venue id");
    }
    if (out.has(option.venue_id)) {
      throw new Error("venue pitch returned a duplicate venue id");
    }
    const pitch = option.pitch.trim();
    if (!pitch) throw new Error("venue pitch returned empty copy");
    out.set(option.venue_id, pitch);
  }

  if (out.size !== expected.size) {
    throw new Error("venue pitch omitted a candidate");
  }
  return out;
}

let client: Anthropic | undefined;

function anthropic(): Anthropic {
  // Venue unit tests exercise ranking without a live provider. Resolve the key only when copy is
  // generated so those tests remain hermetic while deployed failures name the missing secret.
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("missing secret ANTHROPIC_API_KEY");
  return client ??= new Anthropic({ apiKey });
}

/**
 * Write one line per venue, for this group.
 *
 * The model does not choose the venues and cannot: it is handed real retrieved rows and its
 * returned ids are validated against the ids sent. Asking a model to name a venue from memory
 * -- which is what planGroup used to do -- can invent a place that does not exist, and sending
 * six strangers to a nonexistent address is the worst bug this product has.
 */
export async function pitchVenues(
  venues: VenueCandidate[],
  members: { display_name: string; passion: string; tags: string[] }[],
): Promise<Map<string, string>> {
  const res = await anthropic().beta.messages.parse({
    model: "claude-opus-5",
    max_tokens: 4000,
    output_format: betaZodOutputFormat(VenuePitches),
    system:
      "You write one line about each venue, aimed at a specific group of strangers who are " +
      "about to meet there for the first time. Say why THIS place suits THIS group, using " +
      "what they are into. Concrete and warm, never salesy. Never invent facts about a venue " +
      "beyond its name and category -- you have not been there.",
    messages: [{
      role: "user",
      content: `The group:\n${
        members.map((m) =>
          `- ${m.display_name}: ${m.tags.join(", ")} | ${m.passion}`
        ).join("\n")
      }\n\n` +
        `The venues:\n${
          venues.map((v) =>
            `- ${v.venue_id} | ${v.name} | ${
              v.taxonomy_primary.replace(/_/g, " ")
            } | ${v.locality}`
          ).join("\n")
        }`,
    }],
  });
  if (!res.parsed_output) {
    throw new Error("venue pitch returned no parsed output");
  }

  return validateVenuePitches(
    venues.map((venue) => venue.venue_id),
    res.parsed_output.options,
  );
}
