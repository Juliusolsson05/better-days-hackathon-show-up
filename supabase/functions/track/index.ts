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

import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import { emit } from "../_shared/clickhouse.ts";
import {
  parseTrackingRequest,
  TrackingRequestError,
} from "../_shared/tracking.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "method not allowed" }, {
      status: 405,
      headers: { Allow: "POST" },
    });
  }
  try {
    const auth = req.headers.get("Authorization");
    if (!auth) return new Response("unauthorized", { status: 401 });

    // Anon key + caller JWT: the user id comes from the verified token and nowhere else.
    // Accepting a user_id from the body would let any caller write another person's
    // funnel, which is the whole reason this is a function and not a direct insert.
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: auth } } },
    );
    const { data: user } = await supabase.auth.getUser();
    if (!user?.user) return new Response("unauthorized", { status: 401 });
    const uid = user.user.id;

    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return Response.json({ error: "body must be valid JSON" }, {
        status: 400,
      });
    }
    const { accepted, rejected } = parseTrackingRequest(body);

    // Group ids are checked against the caller's own memberships rather than trusted.
    // A forged group_id would not leak anything -- events are write-only from here -- but
    // it would silently corrupt every per-group number on the dashboard, which is worse
    // than an error because nobody would notice.
    const groupIds = [
      ...new Set(accepted.map((e) => e.group_id).filter(Boolean)),
    ] as string[];
    let mine = new Set<string>();
    if (groupIds.length) {
      const { data: rows, error } = await supabase
        .from("group_members")
        .select("group_id")
        .eq("user_id", uid)
        .in("group_id", groupIds);
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
    if (err instanceof TrackingRequestError) {
      return Response.json({ error: err.message }, { status: 400 });
    }
    console.error(err);
    // Authenticated callers do not need ClickHouse SQL, host details, or provider response bodies
    // to recover. Keep the actionable detail in function logs and return a stable client contract.
    return Response.json({ error: "tracking unavailable" }, { status: 500 });
  }
});
