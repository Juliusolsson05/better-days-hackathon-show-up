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

Deno.serve(async (req) => {
  try {
    // Supabase's default verify_jwt is satisfied by the anon key, which ships inside the
    // app binary -- so without this check any user could trigger the sweep and burn tokens.
    const auth = req.headers.get('Authorization') ?? '';
    if (auth !== `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`) {
      return new Response('forbidden', { status: 403 });
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
    if (!pool?.length) return Response.json({ groups: 0, reason: 'empty pool' });

    const unassigned = new Map(pool.map((p) => [p.id, p]));
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

      const { data: group, error: gErr } = await db.from('groups').insert({
        event_at: nextSlot(slot),
        venue: plan.venue,
        activity: plan.activity,
        seed_distance: seedDistance,
      }).select('id').single();
      if (gErr) throw gErr;

      const { error: gmErr } = await db.from('group_members').insert(
        picked.map((id) => ({
          group_id: group!.id,
          user_id: id,
          pair_with: byId.get(id)!.pair_with,
          question: byId.get(id)!.question,
        })),
      );
      if (gmErr) throw gmErr;

      const { error: rErr } = await db.from('rsvps').insert(
        picked.map((id) => ({ group_id: group!.id, user_id: id, status: 'pending' })),
      );
      if (rErr) throw rErr;

      for (const id of picked) unassigned.delete(id);
      await Promise.all(picked.map((id) =>
        emit('group_formed', id, group!.id, { seed_distance: seedDistance, size: picked.length })
      ));
      formed.push(group!.id);
    }

    // Returned so the demo can put the real scan numbers on screen.
    return Response.json({
      groups: formed.length,
      unmatched: unassigned.size,
      skipped: skipped.length,
      stats: lastStats,
    });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});

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
