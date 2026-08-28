# Push notifications — design and implementation plan

Notifications are not a feature of this product, they *are* the product between signup and
the event. Everything from "you've been matched" to "walk in the door" happens in the
notification tray. If the ladder is wrong, nobody shows up and nothing else matters.

---

## 1. What the ladder is for

The user makes exactly one decision — attend or don't — and then has to actually do it
three days later. The gap between deciding and doing is where this product fails.

Each rung has a different job. Writing them as four variations of "don't forget!" wastes
three of them.

| Rung | When | Job | Emotional state it addresses |
|---|---|---|---|
| **Reveal** | T-3 days | Deliver the group, ask for the one decision | Curiosity. This is the only rung that asks for anything. |
| **Confirm** | T-1 day | Make it real, surface the group chat | Vague awareness that something is happening |
| **Morning-of** | 09:00 day-of | Move it from "this week" to "today" | Practical planning — do I need to be somewhere after work |
| **Doorway** | ~10 min out | Remove the friction of walking in | **Anxiety.** This is the hardest moment in the product. |

### The doorway notification matters most

Walking alone into a room to meet five strangers is the point where people turn around and
go home. The notification that fires here should not say "your event is starting". It
should say exactly what to look for:

> **You're close.** Six of you, upstairs at Kinship. Look for the long table by the window —
> Maya's already there.

Naming a specific person, a specific table, and a specific direction converts "I have to
find a group of strangers" into "I have to find a table". That is a much smaller task.

### Copy principles

- **Never guilt.** No "you haven't responded", no "your group is waiting for you", no
  streaks. This is a loneliness product; obligation-shaped copy is actively harmful and will
  be noticed by a judge from a mental-health organisation.
- **Name people.** "Maya, Tom, and four others" beats "your group".
- **Always answer 'where and when'** in the body, so the notification is useful without
  opening the app.
- **One rung, one job.** If a notification is doing two things, split it or cut it.

### Draft copy

```
T-3d     You're in for Friday.
         Six people, 7pm, Kinship in the Mission. In or out?
         [ I'm in ]  [ Can't make it ]

T-1d     Tomorrow, 7pm.
         Maya, Tom, Priya, Sam and Alex. The chat's open if you want to say hi.

09:00    Tonight at 7.
         Kinship, 2801 Mission. Five people are coming.

T-10m    You're close.
         Upstairs at Kinship — long table by the window. Maya's already there.

T+2h     How was it?
         One question about what Tom said. Takes a minute.
```

---

## 2. How it works today

**Constraint:** the build machine has Xcode but no Android SDK, so the demo runs on a
physical iPhone. Real server-driven push on iOS needs an APNs key, which needs a paid Apple
Developer account. That is not a thing we can acquire this afternoon.

**Decision: the whole ladder is scheduled on-device with `flutter_local_notifications`.**

This is not purely a fallback. It has real advantages today:

- No paid account, no FCM project, no APNs certificate.
- **No network dependency at fire time.** In a room with 400 people on one wifi network,
  a notification that needs a server round-trip is a notification that might not arrive
  during the demo.
- Fires precisely on schedule, which makes rehearsal predictable.

From the audience it is indistinguishable from server push.

### Packages

```yaml
flutter_local_notifications: ^18.0.0
timezone: ^0.9.0          # zonedSchedule needs a real TZDateTime, not a local DateTime
permission_handler: ^11.0.0
```

### Scheduling model

When a group assignment arrives, the client schedules all four rungs at once and stores
their ids. Rungs whose time has already passed are skipped rather than fired immediately.

```dart
// One deterministic id per (group, rung) so a reschedule can cancel precisely
// rather than clearing every pending notification the app owns.
int notificationId(String groupId, Rung rung) =>
    Object.hash(groupId, rung.index) & 0x7FFFFFFF;

Future<void> scheduleLadder(Group group) async {
  await cancelLadder(group.id);   // idempotent — safe to call on every group refresh

  final rungs = {
    Rung.reveal:  group.eventAt.subtract(const Duration(days: 3)),
    Rung.confirm: group.eventAt.subtract(const Duration(days: 1)),
    Rung.morning: DateTime(group.eventAt.year, group.eventAt.month, group.eventAt.day, 9),
    Rung.doorway: group.eventAt.subtract(const Duration(minutes: 10)),
  };

  for (final entry in rungs.entries) {
    if (entry.value.isBefore(DateTime.now())) continue;   // never fire a past rung
    await _plugin.zonedSchedule(
      notificationId(group.id, entry.key),
      titleFor(entry.key, group),
      bodyFor(entry.key, group),
      tz.TZDateTime.from(entry.value, tz.local),
      _details(entry.key),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: jsonEncode({'group_id': group.id, 'rung': entry.key.name}),
    );
  }
}
```

### Permission timing — the thing most apps get wrong

**Do not ask on launch.** A permission prompt before the user knows what the app does gets
denied, and on iOS a denial is close to permanent — the user has to go into Settings to
undo it, and they won't.

Ask **immediately after the group reveal**, when the value is concrete and the ask explains
itself:

> You're matched. We'll remind you three days before, the night before, and when you're
> nearly there — nothing else, ever.
> **[ Turn on reminders ]**

That sentence is also a promise about volume, and we keep it: five notifications per event,
none between events.

**If permission is denied**, the app must still work. Fall back to an in-app banner on the
group screen showing the countdown. Never re-prompt more than once, and never block the flow.

### Deep linking

Every notification carries a `{group_id, rung}` payload. Tapping it routes to the right
place rather than to the home screen:

| Rung | Destination |
|---|---|
| Reveal | Group screen, RSVP sheet already open |
| Confirm | Group chat |
| Morning-of | Group screen with the map |
| Doorway | Map, in walking-directions state |
| Post-event | Reflection screen |

The launch payload has to be handled in two places — `getNotificationAppLaunchDetails()`
for a cold start, and the `onDidReceiveNotificationResponse` callback for a warm one.
Handling only the warm path is a bug that shows up exactly once, at the worst time.

### Notification actions

iOS supports buttons on a notification. The reveal rung carries **I'm in** / **Can't make
it**, so the single decision this product asks for can be made without opening the app.
That is worth doing: every screen between the user and the decision loses some of them.

Actions write to `rsvps` and emit an event. Because they can fire while the app is
backgrounded, the handler has to be a top-level function annotated
`@pragma('vm:entry-point')` — otherwise it is tree-shaken from the release build and the
buttons silently do nothing in exactly the build you demo.

---

## 3. What we would build with more than a day

The client-scheduled ladder has real limits. It is the right call today and the wrong call
in production:

- It cannot notify a user whose app has never been opened since assignment.
- It cannot be changed after scheduling — a venue change three days out cannot reach a
  phone that is offline.
- It cannot reach a user who reinstalls.
- Delivery is unobservable: we cannot know whether it arrived.

**Production design:**

```
pg_cron (every 15 min)
   └─► edge function `dispatch-notifications`
          ├─ SELECT rungs due in this window, not yet sent
          ├─ FCM / APNs via a device_tokens table
          └─ emit notif_sent → ClickHouse events
```

- A `notification_log` table in Postgres with a unique constraint on
  `(group_id, user_id, rung)` gives idempotency, so a cron overlap cannot double-send.
- A `device_tokens` table maps users to FCM tokens, refreshed on every launch.
- Venue changes invalidate unsent rungs rather than mutating them.
- iOS `interruption-level: time-sensitive` on the doorway rung so it pierces Focus modes —
  that one is genuinely time-critical and the others are not.

**The geofence.** "10 minutes away" is properly a geofence, not a timer. iOS supports region
monitoring, but it is battery-hostile, requires `always` location permission (a much harder
ask than `whenInUse`), and behaves unpredictably in dense urban areas. Today it is a timer
relative to event start. In production it would be a geofence with the timer as fallback,
and the `always` permission would be requested separately, later, with its own explanation.

---

## 4. Measurement

Every rung emits to the ClickHouse event stream, which is what makes the funnel query in
`clickhouse/queries/funnel.sql` work at all:

| Event | Emitted when |
|---|---|
| `notif_sent` | Scheduled (today) / dispatched (production) |
| `notif_opened` | Notification tapped, with `rung` in props |
| `rsvp` | RSVP set, with source = `notification_action` or `in_app` |
| `attended` | Doorway rung tapped, or manual check-in |

This is the honest measurement question the product exists to answer: **which rung actually
moves people from deciding to doing?** If T-1d does all the work and morning-of does none,
we should cut morning-of. Without the event stream that is unknowable, and with it, it is a
single `windowFunnel` query.

---

## 5. Build order

1. Permission request placed after the group reveal — the copy matters more than the code
2. `scheduleLadder` / `cancelLadder` with deterministic ids
3. Deep-link routing, cold start **and** warm start
4. The four bodies of copy, with real names interpolated
5. Notification actions on the reveal rung
6. `notif_sent` / `notif_opened` emission to ClickHouse
7. Post-event reflection rung

Rungs 1–4 are the demo. Everything after is upside.

**Rehearsal note:** the ladder is scheduled in real time, which is useless for a 5pm demo of
a Friday event. Add a debug control that schedules all four rungs 10, 20, 30 and 40 seconds
out, so the whole ladder can be shown on stage in under a minute. Build this early — it is
also how you test the copy.
