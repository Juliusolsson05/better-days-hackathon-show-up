// The weekly sweep. Triggered by pg_cron in production and by a button during the demo.
//
// This is the riskiest path in the project and the one that cannot be faked on stage --
// build and test it before any UI work.

import { createClient } from 'npm:@supabase/supabase-js';
import { ch, arr, emit } from '../_shared/clickhouse.ts';
import { planGroup } from '../_shared/claude.ts';

const GROUP_SIZE = 6;

Deno.serve(async (req) => {
  try {
    const { city = 'SF', slot = 'fri_eve' } = await req.json().catch(() => ({}));

    // Service role: this runs as the system, not as any user, and writes groups for
    // people who are not the caller.
    const db = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: pool } = await db.from('profiles')
      .select('id, display_name, passion, tags')
      .eq('city', city)
      .contains('availability', [slot])
      .not('embedded_at', 'is', null);
    if (!pool?.length) return Response.json({ groups: 0, reason: 'empty pool' });

    const unassigned = new Map(pool.map((p) => [p.id, p]));
    const formed: string[] = [];
    let lastStats = { elapsed: 0, rows_read: 0 };

    while (unassigned.size >= GROUP_SIZE) {
      const seed = unassigned.keys().next().value as string;

      // Pull a wider band than we need. Taking the 5 literal nearest neighbours produces
      // six near-identical people, which is a dull evening; we want the same topic
      // neighbourhood with variety in temperament, so we over-fetch and then spread.
      const { rows, stats } = await ch<{ user_id: string; d: number; energy: string; indoor: boolean }>(
        `SELECT user_id, cosineDistance(embedding, (
             SELECT embedding FROM profile_vectors WHERE user_id = {self:UUID} LIMIT 1
           )) AS d, energy, indoor
         FROM profile_vectors
         WHERE city = {city:String}
           AND hasAny(availability, {avail:Array(String)})
           AND user_id != {self:UUID}
         ORDER BY d ASC
         LIMIT 40`,
        { self: seed, city, avail: arr([slot]) },
      );
      lastStats = stats;

      const picked = [seed];
      const seenEnergy = new Set<string>();
      for (const pass of [1, 2]) {
        for (const cand of rows) {
          if (picked.length >= GROUP_SIZE) break;
          if (!unassigned.has(cand.user_id) || picked.includes(cand.user_id)) continue;
          // First pass prefers an unseen temperament; second pass fills whatever is left.
          if (pass === 1 && seenEnergy.has(cand.energy)) continue;
          seenEnergy.add(cand.energy);
          picked.push(cand.user_id);
        }
      }
      if (picked.length < GROUP_SIZE) break;   // pool too thin to keep going

      const members = picked.map((id) => unassigned.get(id)!);
      const plan = await planGroup(
        members.map((m) => ({
          user_id: m.id, display_name: m.display_name, passion: m.passion, tags: m.tags,
        })),
        city,
      );

      const cohesion = rows.filter((r) => picked.includes(r.user_id))
        .reduce((s, r) => s + r.d, 0) / (picked.length - 1);

      const { data: group } = await db.from('groups').insert({
        event_at: nextSlot(slot),
        venue: plan.venue,
        activity: plan.activity,
        cohesion,
      }).select('id').single();

      await db.from('group_members').insert(plan.questions.map((q) => ({
        group_id: group!.id, user_id: q.user_id, pair_with: q.pair_with, question: q.question,
      })));
      await db.from('rsvps').insert(picked.map((id) => ({
        group_id: group!.id, user_id: id, status: 'pending',
      })));

      for (const id of picked) {
        unassigned.delete(id);
        await emit('group_formed', id, group!.id, { cohesion });
      }
      formed.push(group!.id);
    }

    // Returned so the demo can put the real scan numbers on screen.
    return Response.json({ groups: formed.length, unmatched: unassigned.size, stats: lastStats });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});

/** Next occurrence of the slot. Deliberately crude -- the demo drives the date anyway. */
function nextSlot(slot: string): string {
  const d = new Date();
  d.setDate(d.getDate() + ((5 - d.getDay() + 7) % 7 || 7));
  d.setHours(slot.endsWith('eve') ? 19 : 13, 0, 0, 0);
  return d.toISOString();
}
