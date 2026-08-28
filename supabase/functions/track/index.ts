// The client's only way to reach ClickHouse.
//
// The funnel in clickhouse/queries/funnel.sql -- the closing slide -- walks
// signup -> notif_sent -> rsvp -> attended -> number_shared. Before this function, only
// `signup` (submit-profile) and `group_formed` (run-matching) were ever emitted, because
// every other stage happens on the phone and the phone cannot talk to ClickHouse. The
// dashboard therefore reported level 0 for every user regardless of what they did.
//
// Flutter never gets a ClickHouse credential: that interface accepts arbitrary SQL and
// has no per-row permissions, so a key in the app binary hands whoever extracts it the
// whole population. This function is the seam -- it holds the credential, and the only
// thing the client can do through it is append a row about itself.

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';
import { emit } from '../_shared/clickhouse.ts';

/**
 * Events the client is allowed to append.
 *
 * A whitelist rather than free-form, because this endpoint is reachable by anyone holding
 * the anon key -- which ships inside the app binary and is therefore public by design.
 * Without it, the table backing every number we put on stage is writable with arbitrary
 * `name` values by anyone who reads the bundle. Adding a stage means adding it here, and
 * that is the intended amount of friction.
 *
 * Server-emitted names (signup, group_formed) are deliberately NOT here: they are facts
 * the server establishes, and letting a client assert them would let it claim a group
 * formed that never did.
 */
const ALLOWED = new Set([
  'notif_sent',      // a ladder rung was scheduled on device
  'notif_opened',    // a rung was tapped
  'rsvp',            // attend / don't -- the one decision the product asks for
  'chat_opened',     // the group chat was actually looked at
  'chat_first_message', // this user said something for the first time in this group
  'venue_voted',
  'attended',
  'answered',        // the assigned question was reflected on
  'number_shared',
]);

/** One request may carry a small batch: a phone coming back online flushes what it queued. */
const MAX_BATCH = 20;

interface InEvent {
  name: string;
  group_id?: string | null;
  props?: Record<string, unknown>;
}

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get('Authorization');
    if (!auth) return new Response('unauthorized', { status: 401 });

    // Anon key + caller JWT: the user id comes from the verified token and nowhere else.
    // Accepting a user_id from the body would let any caller write another person's
    // funnel, which is the whole reason this is a function and not a direct insert.
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: user } = await supabase.auth.getUser();
    if (!user?.user) return new Response('unauthorized', { status: 401 });
    const uid = user.user.id;

    const body = await req.json().catch(() => null) as
      | { events?: InEvent[]; name?: string; group_id?: string | null; props?: Record<string, unknown> }
      | null;
    if (!body) return Response.json({ error: 'bad json' }, { status: 400 });

    // Accept either one event or a batch, so the client does not need two code paths.
    const incoming: InEvent[] = body.events ??
      (body.name ? [{ name: body.name, group_id: body.group_id, props: body.props }] : []);
    if (!incoming.length) return Response.json({ error: 'no events' }, { status: 400 });
    if (incoming.length > MAX_BATCH) {
      return Response.json({ error: `at most ${MAX_BATCH} events` }, { status: 400 });
    }

    const rejected = incoming.filter((e) => !ALLOWED.has(e.name)).map((e) => e.name);
    const accepted = incoming.filter((e) => ALLOWED.has(e.name));

    // Group ids are checked against the caller's own memberships rather than trusted.
    // A forged group_id would not leak anything -- events are write-only from here -- but
    // it would silently corrupt every per-group number on the dashboard, which is worse
    // than an error because nobody would notice.
    const groupIds = [...new Set(accepted.map((e) => e.group_id).filter(Boolean))] as string[];
    let mine = new Set<string>();
    if (groupIds.length) {
      const { data: rows, error } = await supabase
        .from('group_members')
        .select('group_id')
        .eq('user_id', uid)
        .in('group_id', groupIds);
      if (error) throw error;
      mine = new Set((rows ?? []).map((r) => r.group_id as string));
    }

    // Sequential rather than Promise.all: emit() uses async_insert with
    // wait_for_async_insert=0, so each call is a fire-and-forget POST that returns almost
    // immediately, and a batch of 20 fanned out concurrently is 20 sockets for no gain.
    let written = 0;
    for (const e of accepted) {
      // Do not silently strip a forged group and still count the event at user level. That
      // would make the request look successful while corrupting every comparison grouped
      // by cohort. Events that genuinely have no group (for example a pre-match
      // notification) remain valid by omitting group_id entirely.
      if (e.group_id && !mine.has(e.group_id)) {
        rejected.push(`${e.name}:not_a_member`);
        continue;
      }
      await emit(e.name, uid, e.group_id ?? null, e.props ?? {});
      written++;
    }

    // 200 with a rejected list rather than 400: a client that has been upgraded past the
    // server should not have its whole batch dropped because one name is new.
    return Response.json({ written, rejected });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
