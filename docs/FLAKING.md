# Flaking (PRD step 10)

> Attendance comes from the group's votes. The app acknowledges the no-show to that user
> privately. No penalty, no effect on the group. They're placed in the next meetup as
> normal.

Most of this rule is the *absence* of behaviour. What's implemented:

## The private acknowledgement — the only thing built

- **`Repository.wasMarkedNoShow(groupId)`** — true once the group has voted and the
  majority marked you absent.
  - `SupabaseRepository`: reads the existing `attendance_result(grp)` RPC
    (`0002_after_meetup`), looks at its own row, requires `total >= 2` so a single early
    vote is not a verdict, and returns `showed_up * 2 < total`.
  - `MockRepository`: returns `demoNoShow`, flipped by the dev-jump menu.
- **`NoShowSheet`** (`features/group/no_show_sheet.dart`) — a modal sheet with no action
  beyond "Got it". Copy is deliberately flat: nothing happened, nobody was told, you're in
  the next group.
- **Trigger** — `GroupChatScreen` checks on entry (post-frame). The check *is* the
  post-meetup gate: `attendance_result` has no rows until people have voted, which is
  after the meetup. Shown once per group, tracked in `SharedPreferences`
  (`noshow_ack_<groupId>`) — re-showing an absence every launch would be its own small
  punishment.

## Not built, on purpose

- **No penalty** — nothing writes a flag, and `run-matching` does not score on past
  attendance.
- **"Placed in the next meetup as normal"** — `run-matching` re-queries `profiles` every
  sweep, so a no-show is already back in the pool. The broader "groups reshuffle each
  meetup" is separate matching work.

## Demo

Dev-jump menu → **"· flip no-show"** shows the sheet directly (and sets `demoNoShow` so
re-entering the chat re-triggers it until acknowledged).
