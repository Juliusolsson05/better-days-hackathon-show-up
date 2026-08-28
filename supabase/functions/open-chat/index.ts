// Opens the group chat for a group that does not have one yet.
//
// run-matching calls openChat() inline as it forms each group, so in the normal path this
// function never runs. It exists for the two cases that path does not cover:
//
//   - Groups formed BEFORE the chat opening shipped, which sit in the database with an
//     empty room. Backfilling them by hand is a SQL session on a live database during a
//     hackathon, which is exactly when that goes wrong.
//   - The demo. Re-opening a chat is the fastest way to reset the surface between runs
//     without re-running a matching sweep that costs a Claude call per group.
//
// Service-role only, for the same reason run-matching is: it writes messages into groups
// the caller is not a member of.

import { createClient } from 'npm:@supabase/supabase-js@2.47.10';
import { openChat, type ChatMember } from '../_shared/chat.ts';

Deno.serve(async (req) => {
  try {
    // The anon key satisfies Supabase's default verify_jwt and ships in the app binary,
    // so without this check any user could post system messages into any group.
    const auth = req.headers.get('Authorization') ?? '';
    if (auth !== `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`) {
      return new Response('forbidden', { status: 403 });
    }

    const { group_id = null } = await req.json().catch(() => ({}));

    const db = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // No group_id means "every group that needs one" -- the backfill case.
    const { data: groups, error: gErr } = group_id
      ? await db.from('groups').select('id').eq('id', group_id)
      : await db.from('groups').select('id');
    if (gErr) throw gErr;
    if (!groups?.length) return Response.json({ opened: 0, reason: 'no such group' });

    const opened: string[] = [];
    const skipped: string[] = [];

    for (const g of groups) {
      const { data: rows, error } = await db
        .from('group_members')
        .select('user_id, profiles(display_name, tags)')
        .eq('group_id', g.id);
      if (error) throw error;

      const members: ChatMember[] = (rows ?? []).map((r) => {
        const p = (r.profiles ?? {}) as { display_name?: string; tags?: string[] };
        return {
          id: r.user_id as string,
          display_name: p.display_name ?? 'Someone',
          tags: p.tags ?? [],
        };
      });
      if (!members.length) { skipped.push(g.id as string); continue; }

      // openChat is a no-op when the room already has messages, so running the backfill
      // twice cannot double-post an opening line into a live conversation.
      const didOpen = await openChat(db, g.id as string, members);
      (didOpen ? opened : skipped).push(g.id as string);
    }

    return Response.json({ opened: opened.length, skipped: skipped.length, groups: opened });
  } catch (err) {
    console.error(err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
