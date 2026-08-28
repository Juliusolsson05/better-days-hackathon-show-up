# Close the production lifecycle gaps

Issue: #30

## Deadline scope

The hackathon deadline makes the demonstrable user lifecycle the priority: a profile must
survive the API boundary intact, matching must honor hard constraints, a formed group must
be able to RSVP, and a past meetup must lead into reflection and contact exchange without
demo-only controls. Broader operational hardening remains valuable, but it must not delay
these user-visible source-of-truth connections.

## Implementation sequence

1. Make profile readiness explicit through the existing durable fields: persist phone and
   avatar, validate the request, clear stale embedding readiness before external work, and
   only restore users whose required record and embedding are complete.
2. Move stance normalization/conflict logic behind a tested shared boundary, and match
   against the extracted ClickHouse tags rather than the unrelated user-selected topic list.
3. Add RSVP to the repository contract and group UI, keeping Postgres as the source of truth
   and emitting analytics only after the write succeeds.
4. Derive the post-meetup prompt from the real group event time so the reflection flow is
   reachable in production, while preserving the demo shortcut for fixture data.
5. Reuse the existing notification-ladder implementation where it applies cleanly, then run
   the complete API, database, Flutter, and release-contract checks.

## Non-negotiable invariants

- Analytics and notifications may observe a successful product action; neither may decide
  whether that action succeeds.
- A Postgres profile without its ClickHouse embedding is recoverable onboarding state, not
  a completed profile.
- Hard stance conflicts operate on derived stance vocabulary, never arbitrary visible topic
  tags.
- RSVP and post-meetup access must work with Supabase; mock-only reachability is not proof of
  a production connection.
