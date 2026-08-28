import { NextResponse } from 'next/server';

/**
 * Waitlist capture.
 *
 * Writes straight to PostgREST with `fetch` rather than pulling in `@supabase/supabase-js`.
 * The SDK exists to give you auth, realtime and a query builder; this route needs one INSERT
 * and none of that, and a landing page should not ship a database client to do it.
 *
 * The key used here is the ANON key, which is public by design -- the same key that ships
 * inside the Flutter binary. It is safe only because the `waitlist` table's RLS policy
 * grants insert and nothing else, so the worst an attacker can do with it is add rows they
 * cannot read back. The service role key must never reach this project's environment; if it
 * did, every RLS policy in the system would become decorative.
 */

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

// Same shape the app's auth screen accepts, so a mail address that works on the landing
// page also works at signup. Deliberately permissive: the authoritative check is whether
// the mail arrives, and a clever regex mostly succeeds at rejecting valid addresses.
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export async function POST(request: Request) {
  let email: unknown;
  try {
    ({ email } = await request.json());
  } catch {
    return NextResponse.json({ error: 'Expected a JSON body.' }, { status: 400 });
  }

  if (typeof email !== 'string' || !EMAIL.test(email.trim())) {
    return NextResponse.json(
      { error: "That doesn't look like an email address." },
      { status: 400 },
    );
  }

  // The table is provisioned by a migration that is deliberately not applied yet. Say so
  // plainly rather than returning a cheerful 200 -- a form that fakes success is worse than
  // one that admits it is not live, because the person believes they signed up.
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return NextResponse.json(
      { error: 'The waitlist is not connected yet. Try again shortly.' },
      { status: 503 },
    );
  }

  const res = await fetch(`${SUPABASE_URL}/rest/v1/waitlist`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
      // Nothing is read back, so ask PostgREST not to return the row. With an insert-only
      // policy a representation request fails on the SELECT it implies, which would surface
      // as an error on a write that actually succeeded.
      Prefer: 'return=minimal',
    },
    body: JSON.stringify({ email: email.trim().toLowerCase() }),
  });

  if (res.ok) return NextResponse.json({ ok: true });

  // 23505 is a unique violation: this address is already on the list. That is a success
  // from the visitor's point of view, and telling them otherwise invites a second attempt.
  const body = await res.text();
  if (res.status === 409 || body.includes('23505')) {
    return NextResponse.json({ ok: true, already: true });
  }

  console.error('waitlist insert failed', res.status, body);
  return NextResponse.json(
    { error: 'Something went wrong saving that. Try again.' },
    { status: 502 },
  );
}
