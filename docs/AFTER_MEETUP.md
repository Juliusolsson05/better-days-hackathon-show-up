# The after-meetup flow, wired

`after_flow.dart` (reflection → attendance → contacts) and `contacts_screen.dart` now run
against the real backend. Schema: `supabase/migrations/0002_after_meetup.sql`.

## Migration

`0002_after_meetup.sql` is the post-meetup slice of the old draft, promoted:

| Adds | For |
|---|---|
| `attendance_votes` + `attendance_result(grp)` | step 2 — the group's account of who showed up |
| `contact_selections` + `mutual_contacts(grp)` | step 3 — mutual, invisible contact exchange |
| `profiles.phone` | the number `mutual_contacts` hands back |
| `reflections.was_fallback` + an UPDATE policy | step 1 — the "they didn't show" fallback; the policy fixes an upsert that 0001 would have blocked |
| drops `number_shares` + `has_shared_number()` | replaced by the mutual model |

**The venue half of the draft is still a draft.** When it lands it must be `0003_*.sql`
— two files with version `0002` make `supabase db push` reject the set.

Not applied locally (no `supabase` CLI here). Run `supabase db reset` to confirm.

## Repository

`SupabaseRepository`:

- `submitReflection` — upsert into `reflections`. `about_user` is your assigned pair even
  in the fallback case (the UI doesn't collect an alternate subject); `was_fallback` marks
  the difference.
- `submitAttendance` — one upserted row per `(me, subject)` from the "who showed up" map.
- `selectContacts` — delete-then-insert your picks for the group, so a re-run reflects the
  latest choice.
- `mutualContacts` — calls the `mutual_contacts` RPC; the reciprocity and invisibility
  rules live entirely in that function, not the client.

### The `'me'` sentinel

`_members()` now gives the current user the id `'me'`, matching `MockRepository`. The
after-flow and group-info screens list "everyone else" with `where((m) => m.id != 'me')`;
without this the signed-in user appeared in their own attendance and contact lists.

## Still on the mock

Venue voting only — `castVenueVote` / `myVenueVote` / `venueTally`.
