# Live group chat, against the real backend

`SupabaseRepository` now implements the group-chat slice on the **0001** schema — no
`0002`, no venue pipeline:

| Method | Backend |
|---|---|
| `currentGroup()` | `group_members` → `groups` → members via `profiles` embed. Builds one `VenueOption` from `groups.venue` (the single venue Claude picked; no ballot yet). |
| `watchMessages(groupId)` | `messages` realtime stream (already in the `supabase_realtime` publication), oldest-first, names/photos denormalised from a one-time member fetch. |
| `sendMessage(groupId, body)` | plain `insert`; RLS `post as self` forces `user_id`. The stream echoes it back. |
| `assignment(groupId)` | the caller's `group_members` row (`pair_with`, `question`) + the paired `profiles.display_name`. |

`waiting_screen.dart` polls `currentGroup()` every 5s, so once matching runs the app
advances to the chat on its own — a stand-in for the "your group formed" push.

`Avatar` (in `core/theme.dart`) now renders `Image.network` when handed an http(s) URL
(`profiles.photo_url`) and falls back to a glyph otherwise, so the mock's emoji avatars
still work unchanged.

## Testing it needs a group to exist

A group only appears after `run-matching`. Locally:

```bash
supabase start
supabase db reset            # applies 0001
# sign up 4-6 users through the production app, then trigger matching:
curl -X POST "$SUPABASE_URL/functions/v1/run-matching" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'content-type: application/json' -d '{"city":"SF","slot":"fri_eve"}'
```

Then in the app: the waiting screen picks up the new group within 5s (or use the
dev-jump menu → "3 · Group chat"). Send messages from two signed-in sessions to see the
realtime stream.

## Still on MockRepository

`castVenueVote` / `myVenueVote` / `venueTally` — venue voting (`0002` + `feat/venue-pipeline`).
`submitReflection` / `submitAttendance` / `selectContacts` / `mutualContacts` — the
after-meetup flow (`0002`).
