// Given a group, produce 2-3 real venue options for its members to vote on.
//
// Separate from run-matching on purpose: matching owns group formation and is on another
// agent's critical path, and folding venue retrieval into it would couple two things that
// fail for unrelated reasons.
//
// A real group is persisted through replace_venue_options(), which owns validation and the
// single chat anchor. Ad-hoc members remain read-only so the retrieval demo can be exercised
// without manufacturing product rows.

import { createClient } from "npm:@supabase/supabase-js@2.47.10";

import {
  diversify,
  memberVectors,
  pitchVenues,
  retrieve,
} from "../_shared/venues.ts";

type StoredVenueOption = {
  position: number;
  provider_id: string;
  name: string;
  kind: string;
  address: string;
  locality: string;
  lat: number;
  lng: number;
  score: number | null;
  member_scores: number[];
  pitch: string;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function storedOption(option: StoredVenueOption) {
  return {
    position: option.position,
    venue_id: option.provider_id,
    name: option.name,
    kind: option.kind,
    address: option.address,
    locality: option.locality,
    lat: option.lat,
    lng: option.lng,
    score: option.score,
    per_member: option.member_scores,
    pitch: option.pitch,
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "method not allowed" }, {
      status: 405,
      headers: { Allow: "POST" },
    });
  }
  try {
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const auth = req.headers.get("Authorization") ?? "";
    if (!serviceRoleKey || auth !== `Bearer ${serviceRoleKey}`) {
      return new Response("forbidden", { status: 403 });
    }

    let input: unknown;
    try {
      input = await req.json();
    } catch {
      return Response.json({ error: "body must be valid JSON" }, {
        status: 400,
      });
    }
    if (input === null || typeof input !== "object" || Array.isArray(input)) {
      return Response.json({ error: "body must be a JSON object" }, {
        status: 400,
      });
    }
    const body = input as Record<string, unknown>;
    const { group_id, radius_m, limit = 3 } = body as {
      group_id?: string;
      radius_m?: number;
      limit?: number;
    };
    if (!Number.isInteger(limit) || limit < 2 || limit > 3) {
      return Response.json({ error: "limit must be an integer from 2 to 3" }, {
        status: 400,
      });
    }
    if (
      group_id !== undefined &&
      (typeof group_id !== "string" || !UUID.test(group_id))
    ) {
      return Response.json({ error: "group_id must be a UUID" }, {
        status: 400,
      });
    }
    if (
      radius_m !== undefined &&
      (typeof radius_m !== "number" || !Number.isFinite(radius_m) ||
        radius_m <= 0 ||
        radius_m > 100_000)
    ) {
      return Response.json({ error: "radius_m must be between 1 and 100000" }, {
        status: 400,
      });
    }

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    if (group_id) {
      const { data: existing, error: existingErr } = await db
        .from("venue_options")
        .select(
          "position,provider_id,name,kind,address,locality,lat,lng,score,member_scores,pitch",
        )
        .eq("group_id", group_id)
        .order("position");
      if (existingErr) throw existingErr;
      if (existing?.length) {
        // A retry after the first worker committed must reuse the exact ballot people may already
        // be looking at. Returning before Voyage/Claude also turns an ambiguous edge timeout into
        // a cheap read instead of paying to invent a second candidate set that Postgres rejects.
        if (existing.length < 2 || existing.length > 3) {
          throw new Error(`group ${group_id} has a partial venue ballot`);
        }
        return Response.json({
          options: existing.map((option) => storedOption(option)),
          persisted: true,
          cached: true,
          scanned: { rows_read: 0, elapsed_s: 0 },
        });
      }
    }

    // Either a real group, or an ad-hoc member list so the pipeline can be exercised before
    // run-matching has produced any groups. The demo depends on being able to run this
    // against two deliberately different member sets and see different venues.
    let members: { display_name: string; passion: string; tags: string[] }[];

    if (group_id) {
      const { data, error } = await db
        .from("group_members")
        .select(
          "profiles!group_members_user_id_fkey(display_name, passion, tags)",
        )
        .eq("group_id", group_id);
      if (error) throw error;
      members = (data ?? []).map((r) => {
        const p = r.profiles as unknown as {
          display_name: string;
          passion: string;
          tags: string[];
        };
        return {
          display_name: p.display_name,
          passion: p.passion,
          tags: p.tags ?? [],
        };
      });
    } else {
      const rawMembers = body.members ?? [];
      if (!Array.isArray(rawMembers) || rawMembers.length > 6) {
        return Response.json({
          error: "members must be an array with at most 6 entries",
        }, {
          status: 400,
        });
      }
      const valid = rawMembers.every((member) => {
        if (
          member === null || typeof member !== "object" || Array.isArray(member)
        ) return false;
        const row = member as Record<string, unknown>;
        return typeof row.display_name === "string" &&
          row.display_name.trim().length > 0 &&
          typeof row.passion === "string" && row.passion.trim().length > 0 &&
          Array.isArray(row.tags) && row.tags.every((tag) =>
            typeof tag === "string"
          );
      });
      if (!valid) {
        return Response.json({ error: "members contain an invalid profile" }, {
          status: 400,
        });
      }
      members = rawMembers as typeof members;
    }

    if (!members.length) {
      return Response.json({
        error: "no members -- pass group_id or members[]",
      }, { status: 400 });
    }

    const vectors = await memberVectors(members);
    const { rows, stats } = await retrieve(vectors, { radiusM: radius_m });
    if (!rows.length) {
      return Response.json({
        error: "no venues in range -- is venue_vectors loaded?",
      }, { status: 404 });
    }

    const picked = diversify(rows, limit);
    if (picked.length < 2) {
      return Response.json(
        {
          error:
            "fewer than two eligible venues -- expand the corpus or radius",
        },
        { status: 422 },
      );
    }
    const pitches = await pitchVenues(picked, members);

    const options = picked.map((v, i) => ({
      position: i + 1,
      venue_id: v.venue_id,
      name: v.name,
      kind: v.taxonomy_primary.replace(/_/g, " "),
      address: v.address,
      locality: v.locality,
      lat: v.lat,
      lng: v.lng,
      score: Number(v.score.toFixed(4)),
      // Per-member similarity, so the reason a venue was chosen can be shown rather than
      // asserted -- including which member it suits least.
      per_member: v.s.map((x) => Number(x.toFixed(3))),
      pitch: pitches.get(v.venue_id) ?? "",
    }));

    let responseOptions = options;
    if (group_id) {
      // The database locks the group, refuses replacement after voting begins, writes every
      // option, and creates exactly one chat anchor. Keeping that transition in one RPC means a
      // function timeout can be retried without the edge worker guessing which writes landed.
      const { data: installed, error } = await db.rpc("replace_venue_options", {
        grp: group_id,
        options,
      });
      if (error) throw error;
      // A racing worker may have installed a different, equally valid ballot while this worker
      // was embedding. Return the rows Postgres actually retained, never the discarded proposal.
      responseOptions = (installed ?? []).map((option: unknown) =>
        storedOption(option as StoredVenueOption)
      );
    }

    return Response.json({
      options: responseOptions,
      persisted: Boolean(group_id),
      // Straight from ClickHouse. This is the number that goes on screen.
      scanned: { rows_read: stats.rows_read, elapsed_s: stats.elapsed },
    });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
