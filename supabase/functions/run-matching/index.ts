// The weekly sweep. Triggered by pg_cron in production and by a button during the demo.
//
// This is the riskiest path in the project and the one that cannot be faked on stage --
// build and test it before any UI work.

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';
import { ch, arr, emit } from '../_shared/clickhouse.ts';
import { planGroup } from '../_shared/claude.ts';

// PRD says 4 to 6. We aim for MAX and accept anything at or above MIN rather than
// stranding five people because a sixth could not be found.
const MIN_GROUP = 4;
const MAX_GROUP = 6;

// The header comment says this is triggered "by a button during the demo" -- that button
// is the operator dashboard (dashboard/index.html), a page served from a different origin,
// so every response needs CORS or the browser never sees it, not even the 403. The auth
// check below is the real gate; `*` here only lets the reply through, it grants nothing.
// Mirrors supabase/functions/analytics/index.ts, which does the same for the same reason.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    // Supabase's default verify_jwt is satisfied by the anon key, which ships inside the
    // app binary -- so without this check any user could trigger the sweep and burn tokens.
    const auth = req.headers.get('Authorization') ?? '';
    if (auth !== `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`) {
      return new Response('forbidden', { status: 403, headers: CORS });
    }

    const { city = 'SF', slot = 'fri_eve' } = await req.json().catch(() => ({}));

    // Service role: this runs as the system, not as any user, and writes groups for
    // people who are not the caller.
    const db = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: pool, error: poolErr } = await db.from('profiles')
      .select('id, display_name, passion, tags')
      .eq('city', city)
      .contains('availability', [slot])
      .not('embedded_at', 'is', null);
    if (poolErr) throw poolErr;

    // currentGroup() expects one membership because the schema does not yet model meetup
    // history versus a current group. Filter already-assigned profiles before doing vector
    // work, then let create_matched_group() re-check under row locks for correctness if two
    // sweeps overlap. The client-side filter is a cost optimisation, not the safety boundary.
    const candidateIds = (pool ?? []).map((p) => p.id);
    const assigned = new Set<string>();
    if (candidateIds.length) {
      const { data: memberships, error: membershipErr } = await db
        .from('group_members')
        .select('user_id')
        .in('user_id', candidateIds);
      if (membershipErr) throw membershipErr;
      for (const row of memberships ?? []) assigned.add(row.user_id);
    }

    const eligible = (pool ?? []).filter((p) => !assigned.has(p.id));
    const unassigned = new Map(eligible.map((p) => [p.id, p]));
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
        { user_id: string; d: number; energy: string; indoor: boolean; tags: string[] }
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
          if (!unassigned.has(cand.user_id) || picked.includes(cand.user_id)) continue;
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
          user_id: m.id, display_name: m.display_name, passion: m.passion, tags: m.tags,
        })),
        city,
      );

      // The model returns user_ids as free strings. Writing them straight into a table
      // with an FK to profiles means a reformatted or invented id becomes a constraint
      // violation mid-sweep -- validate against the ids we actually sent.
      const byId = new Map(plan.questions.map((q) => [q.user_id, q]));
      if (picked.some((id) => !byId.has(id)) || byId.size !== picked.length) {
        skipped.push(seed);
        continue;
      }

      // Mean distance from the seed to the rest of the group. Not the same thing as mean
      // pairwise distance -- a star metric, not a clique metric -- and named accordingly.
      const seedDistance = rows.filter((r) => picked.includes(r.user_id))
        .reduce((s, r) => s + r.d, 0) / (picked.length - 1);

      // Group + memberships + RSVPs is one user-visible fact. The database RPC commits all
      // three tables or none and re-checks uniqueness while participant rows are locked; three
      // independent PostgREST writes left partial groups whenever a later request failed.
      const { data: groupId, error: groupErr } = await db.rpc('create_matched_group', {
        meetup_at: nextSlot(slot),
        // groups.venue is still NOT NULL for backwards compatibility, but the model no
        // longer invents its contents. A recognisable pending sentinel lets currentGroup()
        // keep the phone in the waiting state until the real ballot transaction lands.
        fallback_venue: { name: 'Venue vote pending', address: '' },
        group_activity: plan.activity,
        distance: seedDistance,
        member_rows: picked.map((id) => ({
          user_id: id,
          pair_with: byId.get(id)!.pair_with,
          question: byId.get(id)!.question,
        })),
      });
      if (groupErr) {
        if (groupErr.code === '23505') {
          // Another overlapping sweep won the profile locks. Remove those members from this
          // in-memory run and continue instead of failing every unrelated group in the batch.
          for (const id of picked) unassigned.delete(id);
          skipped.push(...picked);
          continue;
        }
        throw groupErr;
      }
      if (!groupId) throw new Error('create_matched_group returned no group id');

      for (const id of picked) unassigned.delete(id);
      await Promise.all(picked.map((id) =>
        emit('group_formed', id, groupId, { seed_distance: seedDistance, size: picked.length })
      ));
      formed.push(groupId as string);
    }

    // Venue retrieval is deliberately after the group transaction: ClickHouse/Voyage/Claude
    // failures should leave a valid group with its legacy fallback, never half a membership.
    // Include recent pre-existing groups with no ballot so rerunning the operator action is a
    // recovery mechanism. pick-venues itself returns cached rows before external work, making
    // this safe to repeat for groups whose options already landed between the two reads.
    const { data: recentGroups, error: groupsErr } = await db
      .from('groups')
      .select('id')
      .order('created_at', { ascending: false })
      .limit(100);
    if (groupsErr) throw groupsErr;

    const recentIds = (recentGroups ?? []).map((g) => g.id as string);
    const ready = new Set<string>();
    if (recentIds.length) {
      const { data: optionGroups, error: optionsErr } = await db
        .from('venue_options')
        .select('group_id')
        .in('group_id', recentIds);
      if (optionsErr) throw optionsErr;
      for (const row of optionGroups ?? []) ready.add(row.group_id);
    }

    const venueFailures: { group_id: string; error: string }[] = [];
    let venueReady = 0;
    for (const groupId of recentIds.filter((id) => !ready.has(id))) {
      try {
        await ensureVenueBallot(groupId);
        venueReady += 1;
      } catch (err) {
        // Matching success is not rolled back by a recommendation dependency. Return the
        // exact group IDs so the dashboard makes partial readiness visible and a rerun can
        // target the same durable groups instead of rematching their people.
        venueFailures.push({ group_id: groupId, error: String(err) });
      }
    }

    // Returned so the demo can put the real scan numbers on screen.
    return Response.json({
      groups: formed.length,
      unmatched: unassigned.size,
      skipped: skipped.length,
      venue_existing: ready.size,
      venue_ready: venueReady,
      venue_failures: venueFailures,
      stats: lastStats,
    }, { headers: CORS });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500, headers: CORS });
  }
});

async function ensureVenueBallot(groupId: string): Promise<void> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('missing Supabase service configuration');

  const res = await fetch(`${url}/functions/v1/pick-venues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      apikey: key,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ group_id: groupId, limit: 3 }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 500);
    throw new Error(`pick-venues failed (${res.status}): ${detail}`);
  }
}

/**
 * Stance tags are written as `stance:<position>`. Two people holding opposite positions on
 * the same subject embed almost identically -- the embedding cannot separate them, so the
 * tag has to. Kept crude on purpose: an explicit opposition table beats an LLM call here.
 */
const OPPOSED: Record<string, string[]> = {
  vegan: ['hunting', 'bbq', 'steakhouse'],
  hunting: ['vegan', 'vegetarian', 'animal_rights'],
  sober: ['heavy_drinking', 'bar_crawl'],
  religious: ['militant_atheist'],
};
function opposingStances(tags: string[]): string[] {
  const out = new Set<string>();
  for (const t of tags) {
    if (!t.startsWith('stance:')) continue;
    for (const o of OPPOSED[t.slice(7)] ?? []) out.add(`stance:${o}`);
  }
  return [...out];
}

/**
 * Next occurrence of the slot's weekday at the slot's hour, in Pacific time. The edge
 * runtime's local time is UTC, so setHours() there would put a 7pm event at noon PDT.
 */
const WEEKDAY: Record<string, number> = { fri: 5, sat: 6, sun: 0 };
function nextSlot(slot: string): string {
  const [day, part] = slot.split('_');
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + ((WEEKDAY[day] - d.getUTCDay() + 7) % 7 || 7));
  d.setUTCHours((part === 'eve' ? 19 : 13) + 7, 0, 0, 0);   // PDT = UTC-7
  return d.toISOString();
}
