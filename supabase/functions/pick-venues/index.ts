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

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`) {
      return new Response("forbidden", { status: 403 });
    }

    const body = await req.json().catch(() => ({}));
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

    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

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
      members = (body.members ?? []) as typeof members;
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

    if (group_id) {
      // The database locks the group, refuses replacement after voting begins, writes every
      // option, and creates exactly one chat anchor. Keeping that transition in one RPC means a
      // function timeout can be retried without the edge worker guessing which writes landed.
      const { error } = await db.rpc("replace_venue_options", {
        grp: group_id,
        options,
      });
      if (error) throw error;
    }

    return Response.json({
      options,
      persisted: Boolean(group_id),
      // Straight from ClickHouse. This is the number that goes on screen.
      scanned: { rows_read: stats.rows_read, elapsed_s: stats.elapsed },
    });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
