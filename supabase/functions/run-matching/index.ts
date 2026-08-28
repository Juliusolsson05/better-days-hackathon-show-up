// The weekly sweep. Triggered by pg_cron in production and by a button during the demo.
//
// This is the riskiest path in the project and the one that cannot be faked on stage --
// build and test it before any UI work.

import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import { arr, ch, emit } from "../_shared/clickhouse.ts";
import { planGroup } from "../_shared/claude.ts";
import { openChat } from "../_shared/chat.ts";
import { nextSlot } from "../_shared/schedule.ts";

// PRD says 4 to 6. We aim for MAX and accept anything at or above MIN rather than
// stranding five people because a sixth could not be found.
const MIN_GROUP = 4;
const MAX_GROUP = 6;

// The header comment says this can be triggered "by a button during the demo". That operator
// control may be served from a different origin, so every response needs CORS or the browser
// never sees it, not even the 403. The judge-facing analytics now lives in ClickHouse Cloud's
// native dashboard; keeping CORS here avoids coupling the privileged sweep trigger to that one
// presentation surface. The check below is the real gate; `*` only lets replies through.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    // Supabase's default verify_jwt is satisfied by the anon key, which ships inside the
    // app binary -- so without this check any user could trigger the sweep and burn tokens.
    const auth = req.headers.get("Authorization") ?? "";
    if (auth !== `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`) {
      return new Response("forbidden", { status: 403, headers: CORS });
    }

    const { city = "SF", slot = "fri_eve" } = await req.json().catch(
      () => ({}),
    );
    const eventAt = nextSlot(slot);
    // This key is stable for every retry targeting the same city, availability bucket, and
    // actual meetup. It scopes the database's "one user, one group" invariant to a cycle rather
    // than incorrectly preventing a person from ever joining a future Show Up event.
    const runKey = `${city.toLowerCase()}:${slot}:${eventAt}`;

    // Service role: this runs as the system, not as any user, and writes groups for
    // people who are not the caller.
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: alreadyMatched, error: matchedErr } = await db.from(
      "group_members",
    )
      .select("user_id, group_id")
      .eq("matching_run_key", runKey);
    if (matchedErr) throw matchedErr;
    const matchedIds = new Set(
      (alreadyMatched ?? []).map((row) => row.user_id),
    );
    const existingCycleGroups = new Set(
      (alreadyMatched ?? []).map((row) => row.group_id),
    );

    const { data: pool, error: poolErr } = await db.from("profiles")
      .select("id, display_name, passion, tags")
      .eq("city", city)
      .contains("availability", [slot])
      .not("embedded_at", "is", null);
    if (poolErr) throw poolErr;
    if (!pool?.length) {
      return Response.json({ groups: 0, reason: "empty pool" }, {
        headers: CORS,
      });
    }

    // A restarted sweep must not form a second arrangement from people committed before the
    // crash. The RPC is the final race-proof authority; this filter keeps ordinary retries from
    // wasting Claude calls only to discover the same-run membership constraint at write time.
    const unassigned = new Map(
      pool.filter((profile) => !matchedIds.has(profile.id)).map((
        profile,
      ) => [profile.id, profile]),
    );
    const skipped: string[] = [];
    const formed: string[] = [];
    let lastStats = { elapsed: 0, rows_read: 0, bytes_read: 0 };

    while (unassigned.size >= MIN_GROUP) {
      const seed = [...unassigned.keys()].find((id) => !skipped.includes(id));
      if (!seed) break;

      // The seed's own vector, fetched separately. Inlining it as a scalar subquery means
      // a missing row yields [] rather than an error, and cosineDistance then fails with
      // "arrays have different sizes" from inside the scan, which is much harder to read.
      const { rows: self } = await ch<{ embedding: number[] }>(
        `SELECT embedding FROM profile_vectors FINAL WHERE user_id = {self:UUID} LIMIT 1`,
        { self: seed },
      );
      if (!self.length) {
        // embedded_at was set but the ClickHouse write did not land. Skip, don't die.
        skipped.push(seed);
        continue;
      }
      const seedTags: string[] = unassigned.get(seed)!.tags ?? [];

      // Restricted to the real pool with has(), because profile_vectors also holds a
      // million synthetic rows that exist nowhere in Postgres -- without this every
      // candidate is discarded downstream and no group ever forms. The WHERE still reads
      // every row, so the full-scan timing we put on stage remains honest.
      //
      // The stance filter is what makes the README's claim true: the embedding finds the
      // topic neighbourhood, and this keeps someone with the opposite position out of it.
      const { rows, stats } = await ch<
        {
          user_id: string;
          d: number;
          energy: string;
          indoor: boolean;
          tags: string[];
        }
      >(
        `SELECT user_id,
                cosineDistance(embedding, {vec:Array(Float32)}) AS d,
                energy, indoor, tags
         FROM profile_vectors FINAL
         WHERE city = {city:String}
           AND hasAny(availability, {avail:Array(String)})
           AND user_id != {self:UUID}
           AND has({pool:Array(UUID)}, user_id)
           AND NOT hasAny(tags, {blocked:Array(String)})
         ORDER BY d ASC
         LIMIT 40`,
        {
          vec: arr(self[0].embedding),
          self: seed,
          city,
          avail: arr([slot]),
          pool: arr([...unassigned.keys()]),
          blocked: arr(opposingStances(seedTags)),
        },
      );
      lastStats = stats;

      // Over-fetch and then spread. Taking the literal nearest neighbours produces six
      // near-identical people, which is a dull evening; we want the same topic
      // neighbourhood with variety in temperament.
      const picked = [seed];
      const seenEnergy = new Set<string>();
      for (const pass of [1, 2]) {
        for (const cand of rows) {
          if (picked.length >= MAX_GROUP) break;
          if (!unassigned.has(cand.user_id) || picked.includes(cand.user_id)) {
            continue;
          }
          if (pass === 1 && seenEnergy.has(cand.energy)) continue;
          seenEnergy.add(cand.energy);
          picked.push(cand.user_id);
        }
      }
      if (picked.length < MIN_GROUP) {
        // One awkward seed must cost one person, not the whole sweep.
        skipped.push(seed);
        continue;
      }

      const members = picked.map((id) => unassigned.get(id)!);
      const plan = await planGroup(
        members.map((m) => ({
          user_id: m.id,
          display_name: m.display_name,
          passion: m.passion,
          tags: m.tags,
        })),
        city,
      );

      // The model returns user_ids as free strings. Writing them straight into a table
      // with an FK to profiles means a reformatted or invented id becomes a constraint
      // violation mid-sweep -- validate against the ids we actually sent.
      const byId = new Map(plan.questions.map((q) => [q.user_id, q]));
      const targets = new Set(
        plan.questions.map((question) => question.pair_with),
      );
      if (
        picked.some((id) =>
          !byId.has(id) || !picked.includes(byId.get(id)!.pair_with) ||
          byId.get(id)!.pair_with === id
        ) || byId.size !== picked.length ||
        targets.size !== picked.length
      ) {
        skipped.push(seed);
        continue;
      }

      // Mean distance from the seed to the rest of the group. Not the same thing as mean
      // pairwise distance -- a star metric, not a clique metric -- and named accordingly.
      const seedDistance = rows.filter((r) => picked.includes(r.user_id))
        .reduce((s, r) => s + r.d, 0) / (picked.length - 1);

      // Group, membership, private assignments, and RSVPs are one transaction. The former four
      // HTTP writes could fail after exposing a half-built group with no safe way to retry.
      const { data: groupId, error: gErr } = await db.rpc("form_group", {
        p_event_at: eventAt,
        // Legacy groups retain their historical JSON venue, but new groups wait for the owned
        // corpus. Persisting a model-invented name here would create a confident fallback that
        // can point six people at a place that does not exist.
        p_legacy_venue: null,
        p_activity: plan.activity,
        p_seed_distance: seedDistance,
        p_members: picked.map((id) => ({
          user_id: id,
          target_id: byId.get(id)!.pair_with,
          question: byId.get(id)!.question,
        })),
        p_run_key: runKey,
        p_event_timezone: "America/Los_Angeles",
      });
      if (gErr?.code === "23505") {
        // Another sweep can win a different formation containing some of the same people after
        // this worker chose its candidates. The database correctly rolls this transaction back;
        // refresh only the contested same-run users and continue so unrelated people later in
        // the pool are not stranded by ordinary cron overlap.
        const { data: wonRows, error: wonErr } = await db
          .from("group_members")
          .select("user_id, group_id")
          .eq("matching_run_key", runKey)
          .in("user_id", picked);
        if (wonErr) throw wonErr;
        if (!wonRows?.length) throw gErr;
        for (const row of wonRows) {
          unassigned.delete(row.user_id);
          skipped.push(row.user_id);
          existingCycleGroups.add(row.group_id);
        }
        continue;
      }
      if (gErr) throw gErr;
      if (typeof groupId !== "string") {
        throw new Error("form_group returned no group id");
      }

      // Group formation and the chat opening are the same event per the PRD, so this
      // belongs inside the sweep rather than in a follow-up pass -- there is no moment
      // where a group exists and its room does not.
      //
      // Failure here is caught rather than thrown: the group, its members and its RSVPs
      // are already committed at this point, and losing the whole sweep over an opening
      // message would strand everyone matched after this group. An unopened room is
      // recoverable by calling open-chat; a half-finished sweep is not.
      try {
        await openChat(
          db,
          groupId,
          members.map((m) => ({
            id: m.id,
            display_name: m.display_name,
            tags: m.tags ?? [],
          })),
        );
      } catch (chatErr) {
        console.error(
          `group ${groupId} formed but its chat did not open`,
          chatErr,
        );
      }

      for (const id of picked) unassigned.delete(id);
      await Promise.all(
        picked.map((id) =>
          emit("group_formed", id, groupId, {
            seed_distance: seedDistance,
            size: picked.length,
          })
        ),
      );
      formed.push(groupId);
    }

    // Group formation commits before chat and venue dependencies on purpose. A rerun for the
    // same weekly key must therefore repair groups whose follow-up work timed out, not merely
    // decline to rematch their members. This pass includes both groups created above and groups
    // discovered by the stable run key at startup.
    const cycleGroupIds = [...new Set([...existingCycleGroups, ...formed])];
    const groupsWithBallots = new Set<string>();
    if (cycleGroupIds.length) {
      const { data: optionRows, error: optionErr } = await db
        .from("venue_options")
        .select("group_id")
        .in("group_id", cycleGroupIds);
      if (optionErr) throw optionErr;
      for (const row of optionRows ?? []) groupsWithBallots.add(row.group_id);
    }

    const venueFailures: { group_id: string; error: string }[] = [];
    let venueReady = 0;
    for (const groupId of cycleGroupIds) {
      if (groupsWithBallots.has(groupId)) continue;
      try {
        // Always repair the opener before adding the vote anchor. open_group_chat is row-locked
        // and idempotent; reversing this order would let a venue card make the room non-empty and
        // permanently suppress the social framing line after a prior chat timeout.
        const { data: membershipRows, error: membershipErr } = await db
          .from("group_members")
          .select("user_id")
          .eq("group_id", groupId);
        if (membershipErr) throw membershipErr;
        const memberIds = (membershipRows ?? []).map((row) => row.user_id);
        const { data: profileRows, error: profileErr } = await db
          .from("profiles")
          .select("id, display_name, tags")
          .in("id", memberIds);
        if (profileErr) throw profileErr;
        await openChat(
          db,
          groupId,
          (profileRows ?? []).map((profile) => ({
            id: profile.id,
            display_name: profile.display_name,
            tags: profile.tags ?? [],
          })),
        );

        // This call uses the same service-role client as the matching sweep. pick-venues rejects
        // user tokens because a member must never be able to manufacture or replace candidates.
        const { error: venueErr } = await db.functions.invoke("pick-venues", {
          body: { group_id: groupId, limit: 3 },
        });
        if (venueErr) throw venueErr;
        venueReady += 1;
      } catch (venueErr) {
        console.error(`group ${groupId} is missing venue readiness`, venueErr);
        venueFailures.push({ group_id: groupId, error: String(venueErr) });
      }
    }

    // Returned so the demo can put the real scan numbers on screen.
    return Response.json({
      groups: formed.length,
      unmatched: unassigned.size,
      skipped: skipped.length,
      venue_existing: groupsWithBallots.size,
      venue_ready: venueReady,
      venue_failures: venueFailures,
      stats: lastStats,
    }, { headers: CORS });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, {
      status: 500,
      headers: CORS,
    });
  }
});

/**
 * Stance tags are written as `stance:<position>`. Two people holding opposite positions on
 * the same subject embed almost identically -- the embedding cannot separate them, so the
 * tag has to. Kept crude on purpose: an explicit opposition table beats an LLM call here.
 */
const OPPOSED: Record<string, string[]> = {
  vegan: ["hunting", "bbq", "steakhouse"],
  hunting: ["vegan", "vegetarian", "animal_rights"],
  sober: ["heavy_drinking", "bar_crawl"],
  religious: ["militant_atheist"],
};
function opposingStances(tags: string[]): string[] {
  const out = new Set<string>();
  for (const t of tags) {
    if (!t.startsWith("stance:")) continue;
    for (const o of OPPOSED[t.slice(7)] ?? []) out.add(`stance:${o}`);
  }
  return [...out];
}

/**
 * Next occurrence of the slot's weekday at the slot's hour, in Pacific time. The edge
 * runtime's local time is UTC, so setHours() there would put a 7pm event at noon PDT.
 */
