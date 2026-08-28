// Given a group, produce and persist 2-3 real venue options for its members to vote on.
//
// Separate from run-matching on purpose: matching owns group formation and is on another
// agent's critical path, and folding venue retrieval into it would couple two things that
// fail for unrelated reasons.
//
// The database installation function is idempotent and owns both the option rows and their
// chat card in one transaction. This function also checks for installed options before it
// calls Voyage or Claude: database idempotency prevents duplicate state, while this earlier
// check prevents a harmless HTTP retry from becoming an expensive external-API retry.

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';

import { diversify, memberVectors, pitchVenues, retrieve } from '../_shared/venues.ts';

interface StoredVenueOption {
  id: string;
  position: number;
  source_venue_id: string;
  name: string;
  taxonomy_primary: string;
  address: string;
  locality: string;
  lat: number;
  lng: number;
  score: number;
  per_member_scores: number[];
  pitch: string;
}

function storedResponse(row: StoredVenueOption) {
  return {
    id: row.id,
    position: row.position,
    venue_id: row.source_venue_id,
    name: row.name,
    taxonomy_primary: row.taxonomy_primary,
    kind: row.taxonomy_primary.replaceAll('_', ' '),
    address: row.address,
    locality: row.locality,
    lat: row.lat,
    lng: row.lng,
    score: row.score,
    per_member: row.per_member_scores,
    pitch: row.pitch,
  };
}

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (auth !== `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`) {
      return new Response('forbidden', { status: 403 });
    }

    const body = await req.json().catch(() => ({}));
    const { group_id, radius_m, limit = 3 } = body as {
      group_id?: string;
      radius_m?: number;
      limit?: number;
    };

    if (!Number.isInteger(limit) || limit < 2 || limit > 3) {
      return Response.json({ error: 'limit must be 2 or 3' }, { status: 400 });
    }

    const db = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // Return the durable ballot before doing any embedding work. Options are immutable for a
    // group's meetup: changing them after votes arrive would make existing option IDs point at
    // a different decision and destroy trust in the tally.
    if (group_id) {
      const { data: installed, error } = await db
        .from('venue_options')
        .select(
          'id, position, source_venue_id, name, taxonomy_primary, address, locality, ' +
            'lat, lng, score, per_member_scores, pitch',
        )
        .eq('group_id', group_id)
        .order('position');
      if (error) throw error;
      if (installed?.length) {
        if (installed.length < 2) {
          throw new Error(`group ${group_id} has an incomplete stored venue ballot`);
        }
        return Response.json({
          options: (installed as unknown as StoredVenueOption[]).map(storedResponse),
          cached: true,
          scanned: { rows_read: 0, elapsed_s: 0 },
        });
      }
    }

    // An ad-hoc member list is retained so the retrieval pipeline can be exercised before a
    // matching sweep has produced groups. It is deliberately not persisted because there is
    // no group transaction to own the resulting decision.
    let members: { display_name: string; passion: string; tags: string[] }[];

    if (group_id) {
      const { data, error } = await db
        .from('group_members')
        .select('profiles!group_members_user_id_fkey(display_name, passion, tags)')
        .eq('group_id', group_id);
      if (error) throw error;
      members = (data ?? []).map((r) => {
        const p = r.profiles as unknown as
          { display_name: string; passion: string; tags: string[] };
        return { display_name: p.display_name, passion: p.passion, tags: p.tags ?? [] };
      });
    } else {
      members = (body.members ?? []) as typeof members;
    }

    if (!members.length) {
      return Response.json({ error: 'no members -- pass group_id or members[]' }, { status: 400 });
    }

    const vectors = await memberVectors(members);
    const { rows, stats } = await retrieve(vectors, { radiusM: radius_m });
    if (!rows.length) {
      return Response.json({ error: 'no venues in range -- is venue_vectors loaded?' }, { status: 404 });
    }

    const picked = diversify(rows, limit);
    const pitches = await pitchVenues(picked, members);

    const generated = picked.map((v, i) => ({
      position: i + 1,
      venue_id: v.venue_id,
      name: v.name,
      taxonomy_primary: v.taxonomy_primary,
      kind: v.taxonomy_primary.replace(/_/g, ' '),
      address: v.address,
      locality: v.locality,
      lat: v.lat,
      lng: v.lng,
      score: Number(v.score.toFixed(4)),
      // Per-member similarity is persisted for explainability. It is not used as authority
      // for the tally or winner, so rounding it for display cannot change the decision.
      per_member: v.s.map((x) => Number(x.toFixed(3))),
      pitch: pitches.get(v.venue_id) ?? '',
    }));

    let options: unknown[] = generated;
    if (group_id) {
      const { data: installed, error } = await db.rpc('install_group_venue_options', {
        grp: group_id,
        options: generated,
      });
      if (error) throw error;
      options = (installed as unknown as StoredVenueOption[]).map(storedResponse);
    }

    return Response.json({
      options,
      cached: false,
      // Straight from ClickHouse. This is the number that goes on screen.
      scanned: { rows_read: stats.rows_read, elapsed_s: stats.elapsed },
    });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
