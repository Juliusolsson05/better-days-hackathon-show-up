// Called once, from the last screen of onboarding. The only place a profile becomes
// matchable.
//
// Runs server-side rather than from the app because it holds three secrets the phone must
// never see, and because the ClickHouse write has no client-safe equivalent.

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';
import { ch, arr, populationMean, emit } from '../_shared/clickhouse.ts';
import { embed, center, profileText, DIMS } from '../_shared/voyage.ts';
import { extractTags } from '../_shared/claude.ts';

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get('Authorization');
    if (!auth) return new Response('unauthorized', { status: 401 });

    // Anon key + the caller's JWT, so RLS still applies and a user cannot write a profile
    // for somebody else by passing a different id.
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );

    const { data: user } = await supabase.auth.getUser();
    if (!user?.user) return new Response('unauthorized', { status: 401 });
    const uid = user.user.id;

    const body = await req.json() as {
      display_name: string; passion: string; tags: string[];
      city: string; availability: string[]; photo_url?: string;
    };

    const { error: upErr } = await supabase.from('profiles').upsert({
      id: uid,
      display_name: body.display_name,
      passion: body.passion,
      tags: body.tags,
      city: body.city,
      availability: body.availability,
      photo_url: body.photo_url ?? null,
    });
    if (upErr) throw upErr;

    // Embedding and tag extraction are independent -- no reason to pay for them serially.
    const [vectors, tags, mean] = await Promise.all([
      embed([profileText(body)]),
      extractTags(body.passion, body.tags),
      populationMean(),
    ]);

    const vec = center(vectors[0], mean);
    if (vec.length !== DIMS) throw new Error(`expected ${DIMS} dims, got ${vec.length}`);

    // ReplacingMergeTree keyed on user_id, so an edited profile overwrites rather than
    // accumulating duplicate rows for the same person.
    await ch(
      `INSERT INTO profile_vectors
         (user_id, embedding, tags, city, availability, energy, indoor, alcohol_ok)
       VALUES
         ({user_id:UUID}, {embedding:Array(Float32)}, {tags:Array(String)},
          {city:String}, {availability:Array(String)}, {energy:String},
          {indoor:Bool}, {alcohol_ok:Bool})`,
      {
        user_id: uid,
        embedding: arr(vec),
        tags: arr([...tags.topics, ...tags.stance_flags.map((s) => `stance:${s}`)]),
        city: body.city,
        availability: arr(body.availability),
        energy: tags.energy,
        indoor: tags.indoor,
        alcohol_ok: tags.alcohol_ok,
      },
    );

    const { error: stampErr } = await supabase.from('profiles')
      .update({ embedded_at: new Date().toISOString() }).eq('id', uid);
    if (stampErr) throw stampErr;
    await emit('signup', uid, null, { city: body.city, topics: tags.topics });

    return Response.json({ ok: true, tags });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
