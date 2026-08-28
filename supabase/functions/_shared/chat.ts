// Opening and tending the group chat.
//
// The chat is the product surface: group formation and the chat opening are the same
// event, so a group that forms into an EMPTY room is a broken product, not an unfinished
// one. Somebody has to speak first, and asking five strangers to volunteer for that is
// asking for the hardest social act in the whole flow before anyone has any reason to
// trust the room. The system speaks first so that no user has to.
//
// Everything here runs service-role. RLS 'post as self' pins user_id to auth.uid() for
// clients, which is exactly what stops a user forging a system message -- see the note on
// the nullable user_id column in migrations/0003_chat.sql.

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.47.10';

export interface ChatMember {
  id: string;
  display_name: string;
  tags: string[];
}

const NUMBER = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight'];

/**
 * The line that opens every group chat.
 *
 * Deliberately NOT a Claude call, for three reasons. It runs inside the matching sweep,
 * which is already the slowest and riskiest path in the project and already makes one
 * model call per group. It would be a second thing that can fail, mid-sweep, after the
 * group rows are committed. And there is nothing here worth generating: the interesting
 * content is the tag overlap, which we can compute exactly, and a model would only
 * paraphrase it with some chance of inventing an interest nobody listed.
 *
 * Naming the actual overlap is also the point of the message. "You have been matched"
 * tells the group nothing; "you matched on climbing, music and making things" tells them
 * what they are for each other, which is the only thing they need to start talking.
 */
export function openingLine(members: ChatMember[]): string {
  const shared = sharedTags(members);
  const who = NUMBER[members.length] ?? String(members.length);

  // No overlap worth naming is a real case -- a group can be assembled from embedding
  // proximity without any two people sharing a literal tag. Falling back to the neutral
  // line beats printing "you matched on" followed by nothing.
  if (shared.length === 0) {
    return `${who} of you, all coming on your own. Say hi whenever you like.`;
  }
  return `${who} of you matched on ${list(shared)}.`;
}

/**
 * Tags held by at least two members, commonest first, capped at three.
 *
 * The threshold is what makes it a *shared* interest rather than a list of whatever the
 * first person happened to write. Capped at three because the line is read on a lock
 * screen as much as in the app, and a fourth clause is where it gets truncated.
 *
 * `stance:` tags are excluded on purpose. They exist to keep opposed people apart during
 * matching (see opposingStances in run-matching) and are not things anyone would say they
 * are into -- "you matched on stance:vegan" is both ugly and a disclosure nobody opted
 * into making to the group.
 */
function sharedTags(members: ChatMember[]): string[] {
  const counts = new Map<string, number>();
  for (const m of members) {
    // A tag listed twice by one person must not count twice.
    for (const t of new Set(m.tags ?? [])) {
      if (t.startsWith('stance:')) continue;
      counts.set(t, (counts.get(t) ?? 0) + 1);
    }
  }
  return [...counts.entries()]
    .filter(([, n]) => n >= 2)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 3)
    .map(([t]) => t.replace(/_/g, ' '));
}

/** "a", "a and b", "a, b and c" -- Oxford comma deliberately omitted, it reads colder. */
function list(xs: string[]): string {
  if (xs.length <= 1) return xs.join('');
  return `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}`;
}

/**
 * Opens the chat for a freshly formed group.
 *
 * Idempotent by check-then-insert rather than by constraint: there is no natural unique
 * key on "the opening message" that would not also forbid two legitimate system messages
 * later in the group's life. The race this loses to is two concurrent sweeps forming the
 * same group, which cannot happen -- run-matching removes members from the unassigned
 * pool as it goes, and pg_cron does not overlap runs.
 *
 * Returns false when the chat was already open, so a backfill can report honestly.
 */
export async function openChat(
  db: SupabaseClient,
  groupId: string,
  members: ChatMember[],
): Promise<boolean> {
  const { count, error: cErr } = await db
    .from('messages')
    .select('id', { count: 'exact', head: true })
    .eq('group_id', groupId);
  if (cErr) throw cErr;
  if ((count ?? 0) > 0) return false;

  const { error } = await db.from('messages').insert({
    group_id: groupId,
    user_id: null,
    kind: 'system',
    body: openingLine(members),
  });
  if (error) throw error;

  // The venue-vote anchor is NOT posted here, and that is a live dependency rather than
  // an oversight. VenueVoteCard renders as soon as a kind='venue_vote' row exists, and it
  // immediately calls myVenueVote()/venueTally(), which throw UnimplementedError until
  // venue_options lands (0002 draft + feat/venue-pipeline). Posting the anchor early
  // would turn a working chat into a crashing one. postVenueVoteAnchor() below is what
  // that branch calls once the tables exist.
  return true;
}

/**
 * Posts the vote anchor. Call this only once venue_options rows exist for the group.
 *
 * The row carries no payload: the card reads the options and the tally live. Freezing a
 * copy of the options into the message body would go stale the moment a venue is
 * re-picked, and the message is the anchor for the vote, not the record of it.
 */
export async function postVenueVoteAnchor(db: SupabaseClient, groupId: string) {
  const { error } = await db.from('messages').insert({
    group_id: groupId,
    user_id: null,
    kind: 'venue_vote',
    body: '',
  });
  if (error) throw error;
}
