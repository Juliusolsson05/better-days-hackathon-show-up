// Called once, from the last screen of onboarding. The only place a profile becomes
// matchable.
//
// Runs server-side rather than from the app because it holds three secrets the phone must
// never see, and because the ClickHouse write has no client-safe equivalent.

import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import { arr, ch, emit, populationMean } from "../_shared/clickhouse.ts";
import { center, DIMS, embed, profileText } from "../_shared/voyage.ts";
import { extractTags } from "../_shared/claude.ts";
import { normalizeStanceTags } from "../_shared/matching.ts";
import {
  assertOwnedProfilePhotoPath,
  assertProfilePhotoUploaded,
  parseProfileSubmission,
  ProfileSubmissionError,
} from "../_shared/profile_submission.ts";

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get("Authorization");
    if (!auth) return new Response("unauthorized", { status: 401 });

    // This client has exactly one job: turn the bearer token into a verified user id. Profile
    // writes cannot use the same RLS role because any permission that lets this function stamp
    // embedded_at also lets a modified app call PostgREST directly and self-stamp readiness.
    const caller = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: auth } } },
    );

    const { data: user } = await caller.auth.getUser();
    if (!user?.user) return new Response("unauthorized", { status: 401 });
    const uid = user.user.id;

    // Only the already-verified uid crosses into the privileged client. There is deliberately no
    // user id in the request contract, so service-role authority cannot be redirected toward
    // another profile by changing JSON. Migration 0009 removes the equivalent direct client path.
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    let input: unknown;
    try {
      input = await req.json();
    } catch {
      // Malformed JSON is a caller error. Treating it as an internal failure made harmless app
      // bugs indistinguishable from broken infrastructure and invited retries that could never
      // succeed.
      return Response.json({ error: "invalid body: expected JSON" }, {
        status: 400,
      });
    }

    const body = parseProfileSubmission(input);
    assertOwnedProfilePhotoPath(body.photo_url, uid);

    // Checking the exact owner directory before mutating Postgres makes "photo required" a real
    // server invariant. The path check alone only proves what the file would be named if it existed.
    const { data: photoObjects, error: photoErr } = await db.storage.from(
      "photos",
    ).list(uid, {
      limit: 2,
      search: "profile.jpg",
    });
    if (photoErr) throw photoErr;
    assertProfilePhotoUploaded(photoObjects);

    const submissionId = crypto.randomUUID();
    // The database assigns a strictly increasing per-user version while clearing readiness. Slow
    // external work happens after that short transaction, and the token later makes the stamp a
    // compare-and-set instead of letting an older overlapping request certify newer profile data.
    const { data: submissionVersion, error: beginErr } = await db.rpc(
      "begin_profile_submission",
      {
        p_user_id: uid,
        p_submission_id: submissionId,
        p_display_name: body.display_name,
        p_avatar: body.avatar,
        p_passion: body.passion,
        p_tags: body.tags,
        p_city: body.city,
        p_availability: body.availability,
        p_phone: body.phone,
        p_photo_url: body.photo_url,
      },
    );
    if (beginErr) throw beginErr;
    if (typeof submissionVersion !== "string") {
      throw new Error("begin_profile_submission returned no version");
    }

    // Embedding and tag extraction are independent -- no reason to pay for them serially.
    const [vectors, tags, mean] = await Promise.all([
      embed([profileText(body)]),
      extractTags(body.passion, body.tags),
      populationMean(),
    ]);

    const vec = center(vectors[0], mean);
    if (vec.length !== DIMS) {
      throw new Error(`expected ${DIMS} dims, got ${vec.length}`);
    }

    // ReplacingMergeTree keyed on user_id, so an edited profile overwrites rather than
    // accumulating duplicate rows for the same person.
    await ch(
      `INSERT INTO profile_vectors
         (user_id, embedding, tags, city, availability, energy, indoor, alcohol_ok,
          submission_id, updated_at)
       VALUES
         ({user_id:UUID}, {embedding:Array(Float32)}, {tags:Array(String)},
          {city:String}, {availability:Array(String)}, {energy:String},
          {indoor:Bool}, {alcohol_ok:Bool}, {submission_id:UUID},
          parseDateTime64BestEffort({submission_version:String}, 6))`,
      {
        user_id: uid,
        embedding: arr(vec),
        tags: arr([
          ...tags.topics,
          // Claude's schema constrains the shape, not its vocabulary. Persisting canonical
          // stance tags makes ClickHouse's fast exclusion reliable for new profiles, while the
          // matcher keeps a normalized runtime guard for legacy rows.
          ...normalizeStanceTags(
            tags.stance_flags.map((stance) => `stance:${stance}`),
          ),
        ]),
        city: body.city,
        availability: arr(body.availability),
        energy: tags.energy,
        indoor: tags.indoor,
        alcohol_ok: tags.alcohol_ok,
        submission_id: submissionId,
        submission_version: submissionVersion,
      },
    );

    const { data: stamped, error: stampErr } = await db.rpc(
      "complete_profile_submission",
      {
        p_user_id: uid,
        p_submission_id: submissionId,
        p_submission_version: submissionVersion,
      },
    );
    if (stampErr) throw stampErr;
    if (stamped !== true) {
      return Response.json({ error: "profile submission was superseded" }, {
        status: 409,
      });
    }
    // At this point Postgres and ClickHouse agree that the profile is ready. Analytics is an
    // observer of that fact, not another participant in the commit: surfacing an event-stream
    // outage as a 500 made the app invite a retry that temporarily cleared embedded_at and paid
    // for the same embedding work again even though the first submission had succeeded.
    try {
      await emit("signup", uid, null, {
        city: body.city,
        topics: tags.topics,
      });
    } catch (analyticsErr) {
      console.error(
        "profile committed but signup analytics was dropped",
        analyticsErr,
      );
    }

    return Response.json({ ok: true, tags });
  } catch (err) {
    if (err instanceof ProfileSubmissionError) {
      return Response.json({ error: err.message }, { status: 400 });
    }
    // SDK and database errors sometimes include request bodies, SQL details, or upstream
    // response text. Those belong in server logs, not in an unauthenticated HTTP response.
    console.error(err);
    return Response.json({ error: "internal server error" }, { status: 500 });
  }
});
